'use strict';
const { chromium } = require('playwright');
const { execSync }  = require('child_process');
const path          = require('path');
const fs            = require('fs');

const APP_URL    = 'https://192.168.0.1/cgi-bin/luci/admin/status/trafficctl';
const IMG_GIF    = path.join(__dirname, 'img');
const TMP_FRAMES = '/tmp/tc_frames';

function mkdirs() {
  [IMG_GIF, TMP_FRAMES].forEach(d => fs.mkdirSync(d, { recursive: true }));
}

function clearFrames() {
  fs.readdirSync(TMP_FRAMES).forEach(f => fs.unlinkSync(path.join(TMP_FRAMES, f)));
}

function makeGif(pattern, output, fps = 2) {
  const palette = '/tmp/palette.png';
  try {
    execSync(`ffmpeg -y -framerate ${fps} -i "${path.join(TMP_FRAMES, pattern)}" -vf "scale=1200:-1:flags=lanczos,palettegen" "${palette}" 2>/dev/null`);
    execSync(`ffmpeg -y -framerate ${fps} -i "${path.join(TMP_FRAMES, pattern)}" -i "${palette}" -filter_complex "scale=1200:-1:flags=lanczos[x];[x][1:v]paletteuse" -loop 0 "${output}" 2>/dev/null`);
    console.log('  ✓ GIF:', path.relative('/tmp/luci-app-trafficctl', output));
  } catch (e) {
    console.error('  ✗ GIF failed:', e.message);
  }
}

async function setDark(page, on) {
  await page.evaluate(d => document.documentElement.setAttribute('data-darkmode', String(d)), on);
  await page.waitForTimeout(300);
}

// Wait until a specific button label is visible — reliable completion signal
async function waitForButton(page, label, timeout = 30000) {
  await page.waitForFunction(t => {
    for (const b of document.querySelectorAll('button')) {
      if (b.textContent.includes(t) && b.offsetParent !== null) return true;
    }
    return false;
  }, label, { timeout }).catch(() => {});
  await page.waitForTimeout(500);
}

async function waitDone(page, timeout = 20000) {
  await page.waitForFunction(() => {
    for (const el of document.querySelectorAll('div')) {
      if (el.textContent.trim().startsWith('✓') && el.offsetParent !== null
          && el.style.display !== 'none') return true;
    }
    return false;
  }, { timeout }).catch(() => {});
  await page.waitForTimeout(600);
}

async function selectDevice(page, ip) {
  await page.evaluate(ip => {
    for (const row of document.querySelectorAll('tr.tm-row')) {
      const cells = row.querySelectorAll('td');
      if (cells[1] && cells[1].textContent.trim() === ip) { row.click(); return; }
    }
  }, ip);
  await page.waitForTimeout(1500);
}

async function pickOption(page, triggerText, optionText) {
  await page.evaluate(t => {
    for (const el of document.querySelectorAll('span[style*="dashed"]')) {
      if (el.textContent.trim() === t) { el.click(); return; }
    }
    const el = document.querySelector('span[style*="dashed"]');
    if (el) el.click();
  }, triggerText);
  await page.waitForTimeout(300);
  await page.evaluate(t => {
    for (const el of document.querySelectorAll('div[style*="cursor:pointer"][style*="font-size:12px"]')) {
      if (el.textContent.trim() === t) { el.dispatchEvent(new MouseEvent('mousedown', { bubbles: true })); return; }
    }
  }, optionText);
  await page.waitForTimeout(300);
}

// Ensure phone has no rate limits and no blocks before recording
async function cleanPhone(page, ip) {
  console.log('  Cleaning phone state…');
  await selectDevice(page, ip);

  // Remove any rate limit
  const rate = await page.evaluate(() => {
    const el = document.querySelector('span[style*="dashed"]');
    return el ? el.textContent.trim() : 'Off';
  });
  if (rate !== 'Off') {
    console.log(`    Rate was ${rate}, removing…`);
    await pickOption(page, rate, 'Off');
    await page.locator('button:has-text("Apply")').click();
    await waitDone(page);
  }

  // Unblock WiFi if blocked — wait for "Block WiFi" to confirm completion
  const unblockWifi = page.locator('button:has-text("Unblock WiFi")');
  if (await unblockWifi.isVisible().catch(() => false)) {
    console.log('    Unblocking WiFi…');
    await unblockWifi.click();
    await waitForButton(page, 'Block WiFi', 30000);
    console.log('    WiFi unblocked ✓');
  }

  // Unblock internet if blocked
  const unblockInet = page.locator('button:has-text("Unblock Internet")');
  if (await unblockInet.isVisible().catch(() => false)) {
    console.log('    Unblocking Internet…');
    await unblockInet.click();
    await waitForButton(page, 'Block Internet', 20000);
    console.log('    Internet unblocked ✓');
  }

  // Extra pause to let the router finish any background work
  await page.waitForTimeout(1500);
  console.log('  Phone clean ✓');
}

async function recordRateLimitGif(page, dark, ip) {
  const label = dark ? 'dark' : 'light';
  console.log(`\n── rate-limit ${label} ──`);
  await setDark(page, dark);
  await selectDevice(page, ip);

  let fi = 0;
  clearFrames();
  const frame = async () => {
    await page.screenshot({ path: path.join(TMP_FRAMES, `rl_${String(fi++).padStart(3,'0')}.png`) });
  };

  // frame 0: clean state
  await frame();

  // Apply 10 Mbit/s Limiter
  await pickOption(page, 'Off', '10 Mbit/s');
  await pickOption(page, 'Shaper (queue)', 'Limiter (drop)');
  await frame(); // shows rate+mode selected, not yet applied
  await page.locator('button:has-text("Apply")').click();
  await waitDone(page);
  await frame(); // limiter active
  await frame();

  // Switch to Shaper
  await pickOption(page, 'Limiter (drop)', 'Shaper (queue)');
  await page.locator('button:has-text("Apply")').click();
  await waitDone(page);
  await frame(); // shaper active

  // Remove throttle
  await pickOption(page, '10 Mbit/s', 'Off');
  await page.locator('button:has-text("Apply")').click();
  await waitDone(page);
  await frame(); // clean again
  await frame();

  makeGif('rl_%03d.png', path.join(IMG_GIF, `rate-limit-${label}.gif`), 2);
}

(async () => {
  mkdirs();

  const browser = await chromium.connectOverCDP('http://localhost:9222');
  const ctx  = browser.contexts()[0];
  const page = ctx.pages()[0];

  await page.setViewportSize({ width: 1300, height: 820 });
  await page.goto(APP_URL, { waitUntil: 'domcontentloaded' });
  await page.waitForTimeout(2000);

  const phoneIp = '192.168.0.109';

  // dark
  await cleanPhone(page, phoneIp);
  await recordRateLimitGif(page, true, phoneIp);

  // light
  await cleanPhone(page, phoneIp);
  await recordRateLimitGif(page, false, phoneIp);

  // leave clean
  await cleanPhone(page, phoneIp);
  await setDark(page, false);

  await browser.close();
  console.log('\n✓ Done.');
})().catch(e => { console.error('Fatal:', e); process.exit(1); });
