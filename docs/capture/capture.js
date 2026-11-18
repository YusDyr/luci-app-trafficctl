'use strict';
// Screenshots and GIFs of the trafficctl LuCI app for the README.
//
//   ./mksid.sh && node capture.js [shots|gifs|all] [dark|light|both] [only=name,name]
//
// Needs a LuCI session id in .sid (mksid.sh makes one over ssh, so no
// password and no login window). Runs headless Chromium.
//
// local.json (not committed) names the router, the test devices and the
// text replacements, see local.example.json. The GIFs put real restrictions
// on the test devices and lift them afterwards; without test devices they
// are skipped.
//
// Sensitive data is masked in the page right before every frame: MACs keep
// their first two octets, the replacements from local.json are applied, and
// public addresses, destination hostnames, public ports and the Telegram chat
// id are blurred.
const { chromium } = require('playwright');
const { execFileSync } = require('child_process');
const path = require('path');
const fs = require('fs');

const LOCAL = (() => {
	try { return JSON.parse(fs.readFileSync(path.join(__dirname, 'local.json'), 'utf8')); }
	catch (e) { return {}; }
})();
const HOST = process.env.ROUTER || LOCAL.router || '192.168.0.1';
const BASE = `https://${HOST}/cgi-bin/luci/admin/status/trafficctl/`;
const OUT = process.env.OUT || path.join(__dirname, '..', 'img');
const FRAMES = path.join(__dirname, 'frames');
const SID = fs.readFileSync(path.join(__dirname, '.sid'), 'utf8').trim();

// Text replacements, applied to text nodes and to title/value/placeholder:
// local.json "replace" is a list of [regex source, replacement].
const REPLACE = (LOCAL.replace || []).map(([re, to]) => [new RegExp(re, 'g'), to]);

const args = process.argv.slice(2);
const WHAT = args.find(a => /^(shots|gifs|all)$/.test(a)) || 'all';
const THEME = args.find(a => /^(dark|light|both)$/.test(a)) || 'both';
const ONLY = (args.find(a => a.startsWith('only=')) || '').slice(5).split(',').filter(Boolean);
const want = n => !ONLY.length || ONLY.includes(n);

const sleep = ms => new Promise(r => setTimeout(r, ms));

// ── masking ────────────────────────────────────────────────────────────────

async function mask(page) {
	await page.evaluate(repl => {
		const R = repl.map(([s, f, t]) => [new RegExp(s, f), t]);
		const MAC = /\b([0-9a-f]{2}):([0-9a-f]{2})(:[0-9a-f]{2}){4}\b/gi;
		const IP4 = /\b(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})\b/g;
		const priv = ip => /^(10\.|127\.|192\.168\.|169\.254\.|0\.|255\.)/.test(ip) ||
			/^172\.(1[6-9]|2\d|3[01])\./.test(ip);
		const fix = s => {
			let v = s.replace(MAC, (m, a, b) => `${a}:${b}:XX:XX:XX:XX`);
			for (const [re, to] of R) v = v.replace(re, to);
			return v;
		};
		const blur = el => { if (el && el.style) { el.style.filter = 'blur(4px)'; el.dataset.tcBlur = '1'; } };

		const w = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
		const nodes = [];
		while (w.nextNode()) nodes.push(w.currentNode);
		for (const n of nodes) {
			const v = n.nodeValue;
			if (!v || !v.trim()) continue;
			const nv = fix(v);
			if (nv !== v) n.nodeValue = nv;
			// A public address anywhere in the text: blur its element.
			const ips = nv.match(IP4) || [];
			if (ips.some(ip => !priv(ip)) && n.parentElement && n.parentElement.tagName !== 'SCRIPT')
				blur(n.parentElement);
		}
		for (const el of document.querySelectorAll('[title],[value],[placeholder]')) {
			for (const a of ['title', 'value', 'placeholder']) {
				const v = el.getAttribute(a);
				if (v) { const nv = fix(v); if (nv !== v) el.setAttribute(a, nv); }
			}
		}
		for (const el of document.querySelectorAll('input')) {
			if (el.value) { const nv = fix(el.value); if (nv !== el.value) el.value = nv; }
		}
		document.title = fix(document.title);

		// Whole columns: destination hostnames in the connection table, and the
		// router's public ports on the Port Forwards tab.
		for (const tbl of document.querySelectorAll('.table, table')) {
			const head = [...tbl.querySelectorAll('.th, th')].map(h => h.textContent.trim());
			for (const hi of head.map((h, i) => /^(Hostname|Ext\. port)/.test(h) ? i : -1).filter(i => i >= 0)) {
				for (const row of tbl.querySelectorAll('.tr, tr')) {
					const c = row.querySelectorAll('.td, td')[hi];
					if (c && c.textContent.trim() && c.textContent.trim() !== '—') blur(c);
				}
			}
		}
		// Top destinations / host labels outside a table.
		for (const el of document.querySelectorAll('[class*="dst"], [class*="host"]'))
			if (/[a-z0-9-]+\.[a-z]{2,}/i.test(el.textContent) && el.children.length === 0) blur(el);
		// Telegram chat id and bot token, wherever they are shown.
		for (const el of document.querySelectorAll('input')) {
			const lab = (el.closest('div') || {}).textContent || '';
			if (/Chat ID|Token|token/.test(lab) && (el.value || /^\d{5,}$/.test(el.placeholder || ''))) blur(el);
			if (/^\d{6,}$/.test(el.placeholder || '') || /^\d{6,}$/.test(el.value || '')) blur(el);
		}
	}, REPLACE.map(([re, to]) => [re.source, re.flags, to]));
}

// ── page helpers ───────────────────────────────────────────────────────────

async function open(ctx, tab) {
	const p = ctx.pages()[0] || await ctx.newPage();
	for (let i = 0; ; i++) {
		await p.goto(BASE + tab, { waitUntil: 'domcontentloaded', timeout: 60000 });
		if (tab !== 'status') break;
		// The first device poll can take a while; reload once if it stalls.
		try { await p.waitForSelector('div.tr[title]', { timeout: 60000 }); break; }
		catch (e) { if (i) throw e; }
	}
	await p.waitForLoadState('networkidle').catch(() => {});
	await sleep(2500);
	await dismissBanners(p);
	return p;
}

// The offload warning and the "moved to Settings" hint both have a close
// button; the README shows the app, not those notices.
async function dismissBanners(p) {
	await p.evaluate(() => {
		for (const b of document.querySelectorAll('button, span, a, div')) {
			const t = b.textContent.trim();
			if ((t !== '×' && t !== '✕') || b.children.length || !b.offsetParent) continue;
			// The device picker has a × too, and it clears the selection.
			const box = b.parentElement && b.parentElement.parentElement;
			if (box && box.querySelector('input')) continue;
			b.click();
		}
	});
	await sleep(400);
}

async function clickText(p, text, sel = 'button, span, div, a, label', prefix = false) {
	const ok = await p.evaluate(([text, sel, prefix]) => {
		const hit = e => prefix ? e.textContent.trim().startsWith(text) && e.textContent.trim().length < text.length + 4 : e.textContent.trim() === text;
		const els = [...document.querySelectorAll(sel)].filter(e => e.offsetParent && hit(e));
		const leaf = els.find(e => ![...e.children].some(hit)) || els[0];
		if (!leaf) return false;
		leaf.scrollIntoView({ block: 'center' });
		leaf.dispatchEvent(new MouseEvent('mousedown', { bubbles: true }));
		leaf.click();
		return true;
	}, [text, sel, prefix]);
	if (!ok) console.log(`    ! no "${text}"`);
	await sleep(500);
	return ok;
}

// Opens a device and proves it is open: the picker shows its IP and the
// per-device Block Internet button is there. Without that the Speed Limit
// panel is the network-wide one, and a rate chip would limit every device,
// so a scene that cannot select its device stops here.
async function selectDevice(p, ip) {
	for (let i = 0; i < 3; i++) {
		const clicked = await p.evaluate(ip => {
			for (const r of document.querySelectorAll('div.tr[title]'))
				if ([...r.children].some(c => c.textContent.trim() === ip)) { r.scrollIntoView({ block: 'center' }); r.click(); return true; }
			return false;
		}, ip);
		// A device that went quiet drops out of the table; ?ip= opens it anyway.
		if (!clicked) await p.goto(BASE + 'status?ip=' + encodeURIComponent(ip), { waitUntil: 'domcontentloaded' });
		for (let k = 0; k < 10 && !(await isSelected(p, ip)); k++) await sleep(1000);
		if (await isSelected(p, ip)) { await sleep(1500); await dismissBanners(p); return; }
	}
	throw new Error(`could not select ${ip}`);
}

async function isSelected(p, ip) {
	return p.evaluate(ip => {
		const inp = [...document.querySelectorAll('input')].find(e => e.offsetParent && (e.value || '').includes(ip));
		const btn = [...document.querySelectorAll('button')].some(b => b.offsetParent && /^(Block|Unblock) Internet$/.test(b.textContent.trim()));
		return !!inp && btn;
	}, ip);
}

async function mustBeSelected(p, ip) {
	if (!(await isSelected(p, ip))) throw new Error(`${ip} is not selected, not touching the rate chips`);
}

async function allDevices(p) {
	await clickText(p, '📊 All devices');
	await sleep(1500);
}

async function waitText(p, text, ms = 30000) {
	await p.waitForFunction(t => document.body.innerText.includes(t), text, { timeout: ms }).catch(() => console.log(`    ! timeout waiting for "${text}"`));
	await sleep(700);
}

async function top(p) { await p.evaluate(() => window.scrollTo(0, 0)); await sleep(300); }

async function scrollTo(p, text) {
	await p.evaluate(t => {
		const el = [...document.querySelectorAll('h2,h3,h4,div,span,b,strong')].find(e => e.offsetParent && e.textContent.trim() === t);
		if (el) { el.scrollIntoView({ block: 'start' }); window.scrollBy(0, -70); }
	}, text);
	await sleep(400);
}

async function shot(p, name, theme, opts = {}) {
	await mask(p);
	const file = path.join(OUT, theme, name + '.png');
	await p.screenshot({ path: file, fullPage: !!opts.full });
	console.log('  ✓', path.relative(OUT, file));
}

// ── GIFs ───────────────────────────────────────────────────────────────────

function gifRecorder(name, theme) {
	const dir = path.join(FRAMES, `${name}-${theme}`);
	fs.rmSync(dir, { recursive: true, force: true });
	fs.mkdirSync(dir, { recursive: true });
	let i = 0;
	return {
		async frame(p, hold = 1) {
			await mask(p);
			const buf = await p.screenshot();
			for (let k = 0; k < hold; k++) fs.writeFileSync(path.join(dir, String(i++).padStart(4, '0') + '.png'), buf);
		},
		done(fps = 2) {
			const out = path.join(OUT, `${name}-${theme}.gif`);
			const pal = path.join(dir, 'palette.png');
			const inp = path.join(dir, '%04d.png');
			execFileSync('ffmpeg', ['-y', '-loglevel', 'error', '-framerate', String(fps), '-i', inp,
				'-vf', 'scale=960:-1:flags=lanczos,palettegen=stats_mode=diff', pal]);
			execFileSync('ffmpeg', ['-y', '-loglevel', 'error', '-framerate', String(fps), '-i', inp, '-i', pal,
				'-lavfi', 'scale=960:-1:flags=lanczos[x];[x][1:v]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle',
				'-loop', '0', out]);
			console.log('  ✓', path.relative(OUT, out), `(${i} frames)`);
		},
	};
}

module.exports = { LOCAL, mask, open, dismissBanners, clickText, selectDevice, mustBeSelected, allDevices, waitText, top, scrollTo, shot, gifRecorder, sleep, BASE, OUT, WHAT, THEME, want, SID, HOST };

// ── main ───────────────────────────────────────────────────────────────────

if (require.main === module) (async () => {
	const scenes = require('./scenes');
	const themes = THEME === 'both' ? ['dark', 'light'] : [THEME];
	const browser = await chromium.launch();
	try {
		for (const theme of themes) {
			fs.mkdirSync(path.join(OUT, theme), { recursive: true });
			const ctx = await browser.newContext({
				ignoreHTTPSErrors: true, viewport: { width: 1280, height: 800 }, deviceScaleFactor: 1,
				colorScheme: theme, locale: 'en-US',
			});
			await ctx.addCookies([{ name: 'sysauth_https', value: SID, domain: HOST, path: '/cgi-bin/luci', secure: true, httpOnly: true, sameSite: 'Strict' }]);
			// Every page load starts on the full device list, with the
			// "moved to Settings" hint already seen.
			await ctx.addInitScript(() => {
				try {
					const o = JSON.parse(localStorage.getItem('trafficctl_opts') || '{}');
					delete o.lastIp;
					localStorage.setItem('trafficctl_opts', JSON.stringify(o));
					localStorage.setItem('tc-settings-hint-seen', '1');
				} catch (e) {}
			});
			const page = await ctx.newPage();
			// The Rules tab asks before removing; say yes.
			page.on('dialog', d => d.accept());
			console.log(`== ${theme}`);
			for (const [name, fn, kind] of scenes.list) {
				if (!want(name) || (WHAT !== 'all' && WHAT !== kind)) continue;
				console.log(`- ${name}`);
				try { await fn(ctx, theme); } catch (e) { console.log(`  ✗ ${name}: ${e.message.split('\n')[0]}`); }
				// Whatever a GIF scene left behind is lifted before the next one.
				if (kind === 'gifs') await scenes.cleanup().catch(e => console.log('cleanup:', e.message));
			}
			await ctx.close();
		}
	} finally {
		await browser.close();
		await scenes.cleanup().catch(e => console.log('cleanup:', e.message));
	}
})();
