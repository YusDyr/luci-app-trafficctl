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

// Reload page in all-devices mode (clears lastIp from localStorage)
async function gotoAllDevices(page) {
  await page.evaluate(() => {
    try {
      const o = JSON.parse(localStorage.getItem('trafficctl_opts') || '{}');
      delete o.lastIp;
      localStorage.setItem('trafficctl_opts', JSON.stringify(o));
    } catch(e) {}
  });
  await page.reload({ waitUntil: 'domcontentloaded' });
  await page.waitForTimeout(3000);
}

// Wait until a button with given text label is visible (signals operation completed)
async function waitForButton(page, label, timeout = 20000) {
  await page.waitForFunction(t => {
    for (const b of document.querySelectorAll('button')) {
      if (b.textContent.includes(t) && b.offsetParent !== null) return true;
    }
    return false;
  }, label, { timeout }).catch(() => {});
  await page.waitForTimeout(400);
}

// Wait for "✓ Done" banner (not any stray checkmark in table)
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
    await page.waitForTimeout(400);
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

// Get the current rate display text
async function getCurrentRate(page) {
  return page.evaluate(() => {
    const el = document.querySelector('span[style*="dashed"]');
    return el ? el.textContent.trim() : 'Off';
  });
}

// Ensure phone is in clean state: no throttle, no blocks
async function cleanPhone(page, ip) {
  console.log('  Cleaning phone state…');
  await selectDevice(page, ip);

  // Remove any rate limit
  const rate = await getCurrentRate(page);
  if (rate !== 'Off') {
    console.log(`    Removing rate limit (was: ${rate})`);
    await pickOption(page, rate, 'Off');
    await page.locator('button:has-text("Apply")').click();
    await waitDone(page);
  }

  // Unblock internet if blocked
  const unblockInet = page.locator('button:has-text("Unblock Internet")');
  if (await unblockInet.isVisible().catch(() => false)) {
    console.log('    Unblocking internet…');
    await unblockInet.click();
    await waitForButton(page, 'Block Internet');
  }

  // Unblock WiFi if blocked
  const unblockWifi = page.locator('button:has-text("Unblock WiFi")');
  if (await unblockWifi.isVisible().catch(() => false)) {
    console.log('    Unblocking WiFi…');
    await unblockWifi.click();
    await waitForButton(page, 'Block WiFi', 25000);
  }

  console.log('    Phone state clean ✓');
}

async function retakeTheme(page, dark, phoneIp) {
  const DIR = dark ? IMG_DARK : IMG_LIGHT;
  const label = dark ? 'dark' : 'light';
  console.log(`\n══ Retaking ${label} theme ══`);

  await setDark(page, dark);

  // ── 02: device detail (clean state) ──────────────────────────────────────
  if (!dark) {
    console.log('  [02] Device detail…');
    await selectDevice(page, phoneIp);
    await closeSettings(page);
    await page.waitForTimeout(1000);
    await shot(page, path.join(DIR, '02-device-detail.png'));
  }

  // ── 06: wifi-unblocked ───────────────────────────────────────────────────
  console.log('  [06] WiFi block/unblock…');
  await selectDevice(page, phoneIp);
  await closeSettings(page);

  const wifiBlock = page.locator('button:has-text("Block WiFi")');
  if (await wifiBlock.isVisible().catch(() => false)) {
    await wifiBlock.click();
    await waitForButton(page, 'Unblock WiFi', 20000);
    await page.waitForTimeout(500);
    // Now unblock and wait until fully done (button returns to "Block WiFi")
    await page.locator('button:has-text("Unblock WiFi")').click();
    await waitForButton(page, 'Block WiFi', 25000);
    await page.waitForTimeout(800);
    await shot(page, path.join(DIR, '06-wifi-unblocked.png'));
  } else {
    console.log('    (Block WiFi not visible)');
  }

  // ── 09: throttle-removed (light only) ────────────────────────────────────
  if (!dark) {
    console.log('  [09] Throttle removed…');
    await selectDevice(page, phoneIp);
    await closeSettings(page);
    // Apply 10 Mbit/s Limiter, then remove
    await pickOption(page, 'Off', '10 Mbit/s');
    await pickOption(page, 'Shaper (queue)', 'Limiter (drop)');
    await page.locator('button:has-text("Apply")').click();
    await waitDone(page);
    await page.waitForTimeout(500);
    // Now remove
    await pickOption(page, '10 Mbit/s', 'Off');
    await page.locator('button:has-text("Apply")').click();
    await waitDone(page);
    await page.waitForTimeout(500);
    await shot(page, path.join(DIR, '09-throttle-removed.png'));
  }

  // ── 10: settings panel (all-devices) ─────────────────────────────────────
  if (!dark) {
    console.log('  [10] Settings panel (all devices)…');
    await gotoAllDevices(page);
    await setDark(page, dark);
    await page.waitForTimeout(2000);
    await openSettings(page);
    await shot(page, path.join(DIR, '10-settings.png'));
    await closeSettings(page);
  }

  // ── 12: extended stats all-devices ───────────────────────────────────────
  console.log('  [12] Extended stats (all devices)…');
  await gotoAllDevices(page);
  await setDark(page, dark);
  await page.waitForTimeout(2000);
  // Enable Extended toggle
  const extCb = page.locator('#tm-extended');
  if (!(await extCb.isChecked().catch(() => false))) {
    await extCb.click();
    await page.waitForTimeout(600);
  }
  await shot(page, path.join(DIR, '12-extended-stats-all.png'));

  // ── 13: extended stats per-device ────────────────────────────────────────
  console.log('  [13] Extended stats (per device)…');
  await selectDevice(page, phoneIp);
  await closeSettings(page);
  await page.waitForTimeout(800);
  // Ensure Extended is still on
  const extCb2 = page.locator('#tm-extended');
  if (!(await extCb2.isChecked().catch(() => false))) {
    await extCb2.click();
    await page.waitForTimeout(600);
  }
  await shot(page, path.join(DIR, '13-extended-stats-device.png'));

  // Disable Extended
  if (await extCb2.isChecked().catch(() => false)) {
    await extCb2.click();
    await page.waitForTimeout(300);
  }
}

(async () => {
  const browser = await chromium.connectOverCDP('http://localhost:9222');
  const ctx  = browser.contexts()[0];
  const page = ctx.pages()[0];

  await page.setViewportSize({ width: 1300, height: 820 });
  await page.goto(APP_URL, { waitUntil: 'domcontentloaded' });
  await page.waitForTimeout(2000);

  const phoneIp = '192.168.0.109';

  // ── clean phone state first ───────────────────────────────────────────────
  await setDark(page, true);
  await cleanPhone(page, phoneIp);

  // ── dark retakes ──────────────────────────────────────────────────────────
  await retakeTheme(page, true, phoneIp);

  // ── clean again before light theme ───────────────────────────────────────
  await cleanPhone(page, phoneIp);

  // ── light retakes ─────────────────────────────────────────────────────────
  await retakeTheme(page, false, phoneIp);

  // leave in clean state
  await setDark(page, false);
  await gotoAllDevices(page);

  await browser.close();
  console.log('\n✓ Retakes done.');
})().catch(e => { console.error('Fatal:', e); process.exit(1); });
