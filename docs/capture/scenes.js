'use strict';
// What capture.js records. Restrictions are only ever put on the two test
// devices below, and cleanup() lifts them over ssh whatever happened.
const c = require('./capture');
const { execFileSync } = require('child_process');

// local.json "devices": "limit" gets the limiter GIF, "shape" the shaper
// and block GIFs, "graph" (default: "shape") the graphs.
const DEV = c.LOCAL.devices || {};
const LIMIT_DEV = DEV.limit;
const SHAPE_DEV = DEV.shape;
const GRAPH_DEV = DEV.graph || DEV.shape;

function ssh(cmd) {
	return execFileSync('ssh', ['root@' + c.HOST, 'sh', '-c', `'${cmd}'`], { encoding: 'utf8' });
}

async function cleanup() {
	if (!LIMIT_DEV && !SHAPE_DEV) return;
	// A rate chip on the network-wide panel lands here; never leave one.
	for (const t of ['0.0.0.0/0', 'all', '192.168.0.0/24'])
		try { ssh(`trafficctl ratelimit ${t} 0 >/dev/null 2>&1; true`); } catch (e) {}
	for (const ip of [LIMIT_DEV, SHAPE_DEV].filter(Boolean)) {
		try { ssh(`trafficctl unblock ${ip} >/dev/null 2>&1; trafficctl ratelimit ${ip} 0 >/dev/null 2>&1; trafficctl shape remove ${ip} >/dev/null 2>&1; true`); }
		catch (e) { console.log('cleanup', ip, e.message); }
	}
}

// ── screenshots ────────────────────────────────────────────────────────────

async function devices(ctx, t) {
	const p = await c.open(ctx, 'status');
	await c.top(p);
	await c.shot(p, 'devices', t);
}

async function device(ctx, t) {
	if (!GRAPH_DEV) return console.log('  skipped: no test device in local.json');
	const p = await c.open(ctx, 'status');
	await c.selectDevice(p, GRAPH_DEV);
	await c.sleep(8000); // let the live graph fill
	await c.top(p);
	await c.shot(p, 'device', t, { full: true });
}

async function popup(ctx, t) {
	if (!GRAPH_DEV) return console.log('  skipped: no test device in local.json');
	const p = await c.open(ctx, 'status');
	const cell = p.locator(`[data-spark-ip="${GRAPH_DEV}"]`).first();
	// The popup opens below the row: put the row in the upper third.
	await cell.evaluate(e => { e.scrollIntoView({ block: 'start' }); window.scrollBy(0, -200); });
	await c.sleep(6000);
	// A device poll can redraw the row under the mouse and close the popup,
	// so mask and shoot as soon as it is open.
	for (let i = 0; i < 8; i++) {
		await p.mouse.move(5, 5);
		await cell.hover();
		await c.sleep(1500);
		await c.mask(p);
		if (await p.locator('.tc-graph-popup:not(.tc-hidden)').count()) {
			await p.screenshot({ path: require('path').join(c.OUT, t, 'graph-popup.png') });
			return console.log('  ✓', t + '/graph-popup.png');
		}
	}
	throw new Error('the graph popup did not open');
}

async function rules(ctx, t) {
	const p = await c.open(ctx, 'rules');
	await c.waitText(p, 'Shaped');
	await c.shot(p, 'rules', t);
}

async function history(ctx, t) {
	const p = await c.open(ctx, 'history');
	await c.sleep(2000);
	await c.shot(p, 'history', t);
}

async function portfw(ctx, t) {
	const p = await c.open(ctx, 'portfw');
	await c.shot(p, 'portfw', t);
}

async function notify(ctx, t) {
	const p = await c.open(ctx, 'notify');
	await c.shot(p, 'notifications', t);
}

const SETTINGS = ['Telegram Bot', 'Logging & Persistence', 'New Device Defaults', 'Flow Offload'];

async function settings(ctx, t) {
	const p = await c.open(ctx, 'settings');
	for (const s of SETTINGS) await c.clickText(p, s, undefined, true);
	await c.sleep(1000);
	await c.top(p);
	await c.shot(p, 'settings', t, { full: true });
}

// ── GIFs ───────────────────────────────────────────────────────────────────

// Limiter on the limit device: pick it, choose Limiter + 5 Mbit/s, see it in Rules,
// remove it there.
async function gifLimit(ctx, t) {
	if (!LIMIT_DEV) return console.log('  skipped: no test device in local.json');
	const g = c.gifRecorder('limit', t);
	const p = await c.open(ctx, 'status');
	await c.top(p); await g.frame(p, 3);
	await c.selectDevice(p, LIMIT_DEV);
	await c.top(p); await g.frame(p, 3);
	await c.mustBeSelected(p, LIMIT_DEV);
	if (!(await c.clickText(p, 'Limiter'))) throw new Error('no Limiter toggle');
	await g.frame(p, 2);
	await c.mustBeSelected(p, LIMIT_DEV);
	await c.clickText(p, '5 Mbit/s');
	await c.sleep(3000); await g.frame(p, 4);
	await p.goto(c.BASE + 'rules'); await c.waitText(p, 'Speed limit');
	await c.sleep(2500); await c.dismissBanners(p); await g.frame(p, 5);
	await removeRule(p, LIMIT_DEV);
	await c.sleep(3000); await g.frame(p, 4);
	g.done();
}

async function removeRule(p, ip) {
	await p.evaluate(ip => {
		for (const r of document.querySelectorAll('.tr, tr'))
			if (r.textContent.includes(ip + ' ') || r.textContent.includes(ip + ' ') || r.textContent.includes(ip + ' ·'))
				for (const b of r.querySelectorAll('button')) if (b.textContent.trim() === 'Remove') { b.click(); return; }
	}, ip);
	await c.sleep(800);
	// Confirm, if the page asks.
	await p.evaluate(() => {
		const m = document.querySelector('.modal');
		if (m) for (const b of m.querySelectorAll('button')) if (/Remove|OK|Yes|Confirm/.test(b.textContent)) { b.click(); return; }
	});
}

// Shaper on the shape device: 10 Mbit/s, then removed on the Rules tab.
async function gifShape(ctx, t) {
	if (!SHAPE_DEV) return console.log('  skipped: no test device in local.json');
	const g = c.gifRecorder('shape', t);
	const p = await c.open(ctx, 'status');
	await c.selectDevice(p, SHAPE_DEV);
	await c.top(p); await g.frame(p, 3);
	await c.mustBeSelected(p, SHAPE_DEV);
	if (!(await c.clickText(p, 'Shaper'))) throw new Error('no Shaper toggle');
	await g.frame(p, 1);
	await c.mustBeSelected(p, SHAPE_DEV);
	await c.clickText(p, '10 Mbit/s');
	await c.sleep(3500); await g.frame(p, 4);
	await p.goto(c.BASE + 'rules'); await c.waitText(p, SHAPE_DEV);
	await c.sleep(2500); await g.frame(p, 5);
	await removeRule(p, SHAPE_DEV);
	await c.sleep(3000); await g.frame(p, 4);
	g.done();
}

// Block internet on the shape device, then unblock.
async function gifBlock(ctx, t) {
	if (!SHAPE_DEV) return console.log('  skipped: no test device in local.json');
	const g = c.gifRecorder('block', t);
	const p = await c.open(ctx, 'status');
	await c.selectDevice(p, SHAPE_DEV);
	await c.top(p); await g.frame(p, 3);
	await c.mustBeSelected(p, SHAPE_DEV);
	await c.clickText(p, 'Block Internet', 'button');
	await c.sleep(3000); await g.frame(p, 4);
	await c.allDevices(p);
	await c.sleep(4000); await c.top(p); await g.frame(p, 4);
	await c.open(ctx, 'status');
	await c.selectDevice(p, SHAPE_DEV);
	await c.top(p); await g.frame(p, 2);
	if (!(await c.clickText(p, 'Unblock Internet', 'button'))) throw new Error('no Unblock button');
	await c.sleep(3000); await g.frame(p, 3);
	g.done();
}

// Live graph: open a busy device and let the chart run.
async function gifGraph(ctx, t) {
	if (!GRAPH_DEV) return console.log('  skipped: no test device in local.json');
	const g = c.gifRecorder('graph', t);
	const p = await c.open(ctx, 'status');
	await c.selectDevice(p, GRAPH_DEV);
	await c.scrollTo(p, 'Speed Limit');
	for (let i = 0; i < 16; i++) { await g.frame(p); await c.sleep(1000); }
	g.done(2);
}

// Every tab once, then the Settings sections opened.
async function gifTour(ctx, t) {
	const g = c.gifRecorder('tour', t);
	for (const tab of ['status', 'rules', 'history', 'portfw', 'notify']) {
		const p = await c.open(ctx, tab);
		await c.top(p); await g.frame(p, 3);
	}
	const p = await c.open(ctx, 'settings');
	await g.frame(p, 2);
	for (const s of SETTINGS) { await c.clickText(p, s, undefined, true); await g.frame(p, 2); }
	g.done();
}

exports.cleanup = cleanup;
exports.list = [
	['devices', devices, 'shots'],
	['device', device, 'shots'],
	['popup', popup, 'shots'],
	['rules', rules, 'shots'],
	['history', history, 'shots'],
	['portfw', portfw, 'shots'],
	['notify', notify, 'shots'],
	['settings', settings, 'shots'],
	['limit', gifLimit, 'gifs'],
	['shape', gifShape, 'gifs'],
	['block', gifBlock, 'gifs'],
	['graph', gifGraph, 'gifs'],
	['tour', gifTour, 'gifs'],
];
