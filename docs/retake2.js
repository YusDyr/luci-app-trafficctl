'use strict';
const { chromium } = require('playwright');
const path = require('path');
const fs = require('fs');

const APP_URL   = 'https://192.168.0.1/cgi-bin/luci/admin/status/trafficctl';
const IMG_DARK  = path.join(__dirname, 'img', 'dark');
const IMG_LIGHT = path.join(__dirname, 'img', 'light');

function shot(page, file) {
  return page.screenshot({ path: file, fullPage: false }).then(() =>
    console.log('  ✓', path.relative('/tmp/luci-app-trafficctl', file)));
}

async function setDark(page, on) {
  await page.evaluate(d => document.documentElement.setAttribute('data-darkmode', String(d)), on);
  await page.waitForTimeout(300);
}

// Navigate to all-devices by clearing localStorage and doing a full goto
async function gotoAllDevices(page) {
  await page.evaluate(() => {
    try {
      const o = JSON.parse(localStorage.getItem('trafficctl_opts') || '{}');
      delete o.lastIp;
      localStorage.setItem('trafficctl_opts', JSON.stringify(o));
    } catch(e) {}
  });
  await page.goto(APP_URL, { waitUntil: 'domcontentloaded' });
  await page.waitForTimeout(3000);
}

async function waitForButton(page, label, timeout = 25000) {
  await page.waitForFunction(t => {
    for (const b of document.querySelectorAll('button')) {
      if (b.textContent.includes(t) && b.offsetParent !== null) return true;
    }
    return false;
  }, label, { timeout }).catch(() => {});
  await page.waitForTimeout(400);
}

async function waitDone(page, timeout = 20000) {
  await page.waitForFunction(() => {
    for (const el of document.querySelectorAll('div')) {
      if (el.textContent.trim().startsWith('✓') && el.offsetParent !== null
          && el.style.display !== 'none') return true;
    }
    return false;
  }, { timeout }).catch(() => {});
  await page.waitForTimeout(500);
}

async function selectDevice(page, ip) {
  await page.evaluate(ip => {
    for (const row of document.querySelectorAll('tr.tm-row')) {
      const cells = row.querySelectorAll('td');
      if (cells[1] && cells[1].textContent.trim() === ip) { row.click(); return; }
    }
  }, ip);
  await page.waitForTimeout(1200);
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

async function openSettings(page) {
  const arrow = page.locator('.tm-settings-arrow');
  const txt = await arrow.textContent().catch(() => '▾');
  if (txt.includes('▸')) {
    await page.locator('div:has(.tm-settings-arrow)').first().click();
    await page.waitForTimeout(500);
  }
}

async function closeSettings(page) {
  const arrow = page.locator('.tm-settings-arrow');
  const txt = await arrow.textContent().catch(() => '▸');
  if (txt.includes('▾')) {
    await page.locator('div:has(.tm-settings-arrow)').first().click();
    await page.waitForTimeout(400);
  }
}

// ── main ──────────────────────────────────────────────────────────────────────

(async () => {
  const browser = await chromium.connectOverCDP('http://localhost:9222');
  const ctx  = browser.contexts()[0];
  const page = ctx.pages()[0];

  await page.setViewportSize({ width: 1300, height: 820 });

  const phoneIp = '192.168.0.109';

  for (const dark of [true, false]) {
    const DIR   = dark ? IMG_DARK : IMG_LIGHT;
    const label = dark ? 'dark' : 'light';
    console.log(`\n══ ${label} ══`);

    // ── 10: settings panel in all-devices mode ────────────────────────────
    if (!dark) {
      console.log('  [10] Settings panel (all devices)…');
      await gotoAllDevices(page);
      await setDark(page, dark);
      await page.waitForTimeout(1000);
      await openSettings(page);
      await page.waitForTimeout(300);
      await shot(page, path.join(DIR, '10-settings.png'));
      await closeSettings(page);
    }

    // ── 12/13: extended stats ─────────────────────────────────────────────
    //
    // Shot 12: all-devices + Extended toggle ON
    // Shot 13: per-device  + Extended toggle ON + active limiter (shows stats)
    //
    // Step 1: navigate to all-devices, enable Extended, take shot 12
    console.log('  [12] Extended stats (all devices)…');
    await gotoAllDevices(page);
    await setDark(page, dark);
    await page.waitForTimeout(1000);

    // Open settings to make Extended toggle clickable without misfire
    await openSettings(page);
    await page.waitForTimeout(300);

    const extCb = page.locator('#tm-extended');
    if (!(await extCb.isChecked().catch(() => false))) {
      await extCb.click();
      await page.waitForTimeout(600);
    }
    // Close settings so the table is visible
    await closeSettings(page);
    await page.waitForTimeout(400);
    await shot(page, path.join(DIR, '12-extended-stats-all.png'));

    // Step 2: select device, apply 10 Mbit/s Limiter to get live stats, take shot 13
    console.log('  [13] Extended stats (per device, with limiter)…');
    await selectDevice(page, phoneIp);
    await closeSettings(page);

    // Apply 10 Mbit/s Limiter so extended stats show real data
    await pickOption(page, 'Off', '10 Mbit/s');
    await pickOption(page, 'Shaper (queue)', 'Limiter (drop)');
    await page.locator('button:has-text("Apply")').click();
    await waitDone(page);
    await page.waitForTimeout(1000);

    // Ensure Extended is still on
    const extCb2 = page.locator('#tm-extended');
    if (!(await extCb2.isChecked().catch(() => false))) {
      await extCb2.click();
      await page.waitForTimeout(600);
    }
    await shot(page, path.join(DIR, '13-extended-stats-device.png'));

    // Clean up: remove limiter, disable Extended
    await pickOption(page, '10 Mbit/s', 'Off');
    await page.locator('button:has-text("Apply")').click();
    await waitDone(page);
    if (await extCb2.isChecked().catch(() => false)) {
      await extCb2.click();
      await page.waitForTimeout(300);
    }
  }

  // leave clean
  await setDark(page, false);
  await gotoAllDevices(page);

  await browser.close();
  console.log('\n✓ Done.');
})().catch(e => { console.error('Fatal:', e); process.exit(1); });
