'use strict';
'require view';
'require rpc';
'require fs';
'require ui';

(function() {
	if (!document.querySelector('link[href*="trafficctl/status.css"]')) {
		var lnk = document.createElement('link');
		lnk.rel = 'stylesheet';
		lnk.type = 'text/css';
		lnk.href = '/luci-static/resources/view/trafficctl/status.css';
		document.head.appendChild(lnk);
	}
})();

var TRAFFICCTL_BUILD = '20260918a';
console.log('[trafficctl] build:' + TRAFFICCTL_BUILD);

// Per-device DPI app breakdown from netifyd, keyed by IP. Stays empty when the
// agent isn't running, which is what makes the App column degrade quietly.
var netifyMap = {};

var STORAGE_KEY = 'trafficctl_opts';
var RECENT_KEY = 'trafficctl_recent';
var MAX_RECENT = 6;
var FULL_HISTORY_MAX = 1800;
// Per-interface history for the overview graph. Deliberately far smaller than
// FULL_HISTORY_MAX: this is kept for EVERY interface at once (a router with a
// few tunnels easily has a dozen), where _fullHistory only ever holds the one
// device the user opened. 600 samples is 20 min at the default 2 s poll.
var IFACE_HISTORY_MAX = 600;
// How many devices the "Top talkers" list shows. The point of the list is to
// answer "who is using the line right now" at a glance; a longer list is what
// the per-device table below already is.
var TOP_TALKERS = 5;
var _fgGraphIdSeq = 0;

function getRecentDevices() {
	try {
		var stored = JSON.parse(window.localStorage.getItem(RECENT_KEY) || '[]');
		return stored.map(function(r) { return typeof r === 'string' ? {ip: r, name: r} : r; });
	} catch(e) { return []; }
}
function saveRecentDevices(arr) {
	try { window.localStorage.setItem(RECENT_KEY, JSON.stringify(arr)); } catch(e) {}
}
function addRecentDevice(ip, name) {
	var recent = getRecentDevices();
	var existing = recent.filter(function(r) { return (r.ip || r) === ip; })[0];
	recent = recent.filter(function(r) { return (r.ip || r) !== ip; });
	recent.unshift({ip: ip, name: name || (existing && existing.name) || ip});
	if (recent.length > MAX_RECENT) recent.length = MAX_RECENT;
	saveRecentDevices(recent);
}

var SERVICE_PORTS = {
	20:'ftp-data', 21:'ftp', 22:'ssh', 23:'telnet', 25:'smtp',
	53:'dns', 80:'http', 110:'pop3', 143:'imap', 179:'bgp',
	443:'https', 465:'smtps', 587:'smtp', 853:'dns-tls',
	993:'imaps', 995:'pop3s', 1194:'openvpn', 3478:'stun',
	5222:'xmpp', 5228:'gcm', 8080:'http-alt', 8443:'https-alt',
	19302:'stun', 51820:'wireguard'
};

var callTrafficctl = rpc.declare({
	object: 'luci.trafficctl',
	method: 'summary',
	expect: { result: [] }
});

var callDevice = rpc.declare({
	object: 'luci.trafficctl',
	method: 'device',
	params: ['ip', 'proto']
});

var callBytes = rpc.declare({
	object: 'luci.trafficctl',
	method: 'bytes',
	expect: { result: [] }
});

var callIfaces = rpc.declare({
	object: 'luci.trafficctl',
	method: 'ifaces',
	expect: { result: [] }
});

var callBlock = rpc.declare({
	object: 'luci.trafficctl',
	method: 'block',
	params: ['ip', 'label']
});

var callUnblock = rpc.declare({
	object: 'luci.trafficctl',
	method: 'unblock',
	params: ['ip', 'label']
});

var callMacfilterAdd = rpc.declare({
	object: 'luci.trafficctl',
	method: 'macfilter_add',
	params: ['ip']
});

var callMacfilterRemove = rpc.declare({
	object: 'luci.trafficctl',
	method: 'macfilter_remove',
	params: ['ip']
});

var callRatelimit = rpc.declare({
	object: 'luci.trafficctl',
	method: 'ratelimit',
	params: ['ip', 'rate_kbit', 'label', 'mode']
});

var callRatelimitStats = rpc.declare({
	object: 'luci.trafficctl',
	method: 'ratelimit_stats',
	expect: { result: [] }
});

var callShapeAdd = rpc.declare({
	object: 'luci.trafficctl',
	method: 'shape_add',
	params: ['ip', 'rate_kbit', 'label']
});

var callShapeRemove = rpc.declare({
	object: 'luci.trafficctl',
	method: 'shape_remove',
	params: ['ip', 'label']
});

var callShapeStats = rpc.declare({
	object: 'luci.trafficctl',
	method: 'shape_stats',
	expect: { result: [] }
});


var callNetifyList = rpc.declare({
	object: 'luci.trafficctl',
	method: 'netify_list',
	expect: { result: [] }
});

var callNameSet = rpc.declare({
	object: 'luci.trafficctl',
	method: 'name_set',
	params: ['ip', 'name']
});

var callTelegramGet = rpc.declare({
	object: 'luci.trafficctl',
	method: 'telegram_config_get'
});

var callTelegramSet = rpc.declare({
	object: 'luci.trafficctl',
	method: 'telegram_config_set',
	params: ['enabled', 'bot_token', 'chat_id', 'poll_interval',
		'notify_new_device', 'notify_known_device', 'control_enabled', 'notify_template',
		'btn_block_inet', 'btn_block_wifi', 'btn_limiter', 'btn_shaper']
});

var callTelegramTest = rpc.declare({
	object: 'luci.trafficctl',
	method: 'telegram_test',
	params: ['bot_token', 'chat_id', 'message']
});

var callLoggingGet = rpc.declare({
	object: 'luci.trafficctl',
	method: 'logging_config_get'
});

var callLoggingSet = rpc.declare({
	object: 'luci.trafficctl',
	method: 'logging_config_set',
	params: ['enabled', 'log_file', 'max_lines', 'syslog',
		'log_blocks', 'log_ratelimits', 'log_shapes', 'log_telegram', 'log_config', 'persist_rules']
});

var callNewDeviceGet = rpc.declare({
	object: 'luci.trafficctl',
	method: 'newdevice_config_get'
});

var callNewDeviceSet = rpc.declare({
	object: 'luci.trafficctl',
	method: 'newdevice_config_set',
	params: ['enabled', 'limit_kbit', 'limit_mode']
});

var callActivityLog = rpc.declare({
	object: 'luci.trafficctl',
	method: 'activity_log',
	params: ['lines']
});
var callVersion = rpc.declare({
	object: 'luci.trafficctl',
	method: 'version'
});

var callConfigSet = rpc.declare({
	object: 'luci.trafficctl',
	method: 'config_set',
	params: ['enabled', 'default_mode', 'sw', 'hw']
});

var callNetworkRrdnsLookup = rpc.declare({
	object: 'network.rrdns',
	method: 'lookup',
	params: ['addrs', 'timeout', 'limit'],
	expect: { '': {} }
});

var callConfigGet = rpc.declare({
	object: 'luci.trafficctl',
	method: 'config_get'
});

var RATE_PRESETS = [
	{v:'0',      l: _('Off')},
	{v:'1000',   l:'1 Mbit/s'},
	{v:'2000',   l:'2 Mbit/s'},
	{v:'5000',   l:'5 Mbit/s'},
	{v:'10000',  l:'10 Mbit/s'},
	{v:'25000',  l:'25 Mbit/s'},
	{v:'50000',  l:'50 Mbit/s'},
	{v:'100000', l:'100 Mbit/s'},
	{v:'custom', l: _('Custom…')}
];

var GROUP_OPTS = [
	{v:'none',    l: _('None (per-flow)')},
	{v:'host',    l: _('Hostname / Dst IP')},
	{v:'service', l: _('Service')},
	{v:'port',    l: _('Port')},
	{v:'proto',   l: _('Protocol')}
];

function loadOpts() {
	try { return JSON.parse(window.localStorage.getItem(STORAGE_KEY) || '{}'); }
	catch(e) { return {}; }
}
function saveOpts(o) {
	try { window.localStorage.setItem(STORAGE_KEY, JSON.stringify(o)); } catch(e) {}
}
function fmtBytes(b) {
	if (b == null || isNaN(b)) return '—';
	if (b < 1024) return b + ' B';
	if (b < 1048576) return (b/1024).toFixed(1) + ' KB';
	if (b < 1073741824) return (b/1048576).toFixed(2) + ' MB';
	return (b/1073741824).toFixed(2) + ' GB';
}
// The Bytes / TCP / UDP columns show a LIFETIME total accumulated on the
// router by trafficctl-totals.sh, not the live conntrack sums they used to
// show. conntrack only accounts for flows that still exist, so the old numbers
// collapsed to absurdities like "2 bytes" the moment a device went briefly
// idle — that is issue #26.
//
// A negative total means the router cannot answer, which is not the same as
// zero: under flow offload the byte source becomes nftables counter maps keyed
// by address alone, which cannot split TCP from UDP. Printing 0 there would be
// a confident wrong answer, i.e. the very failure this change removes.
function renderTotalCell(cell, total, liveVal, since, pending, degraded) {
	while (cell.firstChild) {
		cell.removeChild(cell.firstChild);
	}
	if (pending) {
		cell.appendChild(E('span', { 'class': 'tc-c-faint' }, '…'));
		cell.title = _('Waiting for the first byte sample.');
		return;
	}
	// The router told us these counters are frozen for offloaded flows, so the
	// total is a lower bound that stalls while traffic continues. Refused
	// rather than shown: a plausible number that quietly stops growing reads as
	// stale statistics, not as a broken counter, and is far harder to notice
	// than the implausibly small live values that prompted issue #26.
	if (degraded) {
		cell.appendChild(E('span', { 'class': 'tc-c-err tc-fw-bold' }, '⚠'));
		cell.title = _('Not counted: flow offload is active and this router cannot provide the nftables counters trafficctl uses in that mode, so the kernel byte counters stop updating for offloaded connections. Any total here would be far too low. See Settings → Flow Offload.');
		return;
	}
	if (total == null || total < 0) {
		cell.appendChild(E('span', { 'class': 'tc-c-faint' }, '—'));
		cell.title = _('Not measurable while flow offload is active: in that mode the router counts bytes per address only, so traffic cannot be split by protocol. See Settings → Flow Offload.');
		return;
	}
	cell.appendChild(document.createTextNode(fmtBytes(total)));
	var tip = since
		? (_('Accumulated since') + ' ' + new Date(since * 1000).toLocaleString())
		: _('Accumulated on the router');
	tip += '\n' + _('Resets when the router reboots.');
	if (liveVal != null && liveVal >= 0) {
		tip += '\n' + _('Currently tracked connections hold') + ' ' + fmtBytes(liveVal);
	}
	cell.title = tip;
}

function fmtSpeed(bps) {
	if (!bps || bps < 1) return '—';
	var bits = bps * 8;
	if (bits < 1000) return bits.toFixed(0) + ' bit/s';
	if (bits < 1000000) { var k = bits/1000; return (k % 1 === 0 ? k.toFixed(0) : k.toFixed(1)) + ' Kbit/s'; }
	if (bits < 1000000000) { var m = bits/1000000; return (m % 1 === 0 ? m.toFixed(0) : m.toFixed(1)) + ' Mbit/s'; }
	var g = bits/1000000000; return (g % 1 === 0 ? g.toFixed(0) : g.toFixed(2)) + ' Gbit/s';
}
function fmtRate(kbit) {
	if (!kbit || kbit <= 0) return '—';
	var mbit = kbit / 1000;
	if (mbit >= 1) return (mbit % 1 === 0 ? mbit.toFixed(0) : mbit.toFixed(1)) + ' Mbit/s';
	return kbit + ' kbit/s';
}

// Render a "↓ down / ↑ up" speed cell. Both halves come from the same
// bytes_in/bytes_out sample, so they are always consistent with each other.
function renderSpeedCell(cell, sd) {
	while (cell.firstChild) cell.removeChild(cell.firstChild);
	if (!sd) {
		cell.className = 'td tc-right tc-mono tc-speed-idle';
		cell.appendChild(document.createTextNode('—'));
		return;
	}
	// Download only — upload has its own sortable "UL Speed" column, so showing
	// it here too would duplicate it and make neither column sortable on its own.
	cell.className = 'td tc-right tc-mono ' + (sd.current > 1024 ? 'tc-speed-active' : 'tc-speed-idle');
	cell.appendChild(document.createTextNode(fmtSpeed(sd.current)));
}

function escHtml(s) {
	return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');
}

// Manual device naming. Routed devices (behind a downstream router) have no
// DHCP lease on this router, so an alias — or a PTR record the backend
// resolves — is the only way they get a name instead of "*".
function promptRename(ip, current, onDone) {
	var input = E('input', {
		'type': 'text',
		'class': 'cbi-input-text',
		'value': current === '*' ? '' : current,
		'placeholder': _('Device name'),
		'style': 'width:100%'
	});

	var doSave = function() {
		var v = (input.value || '').replace(/[^a-zA-Z0-9 _.()-]/g, '').substring(0, 32);
		callNameSet(ip, v).then(function(res) {
			ui.hideModal();
			if (res && res.ok === false) {
				ui.addNotification(null, E('p', res.msg || _('Rename failed')), 'error');
				return;
			}
			if (onDone) onDone(v);
		}).catch(function(e) {
			ui.hideModal();
			ui.addNotification(null, E('p', e.message), 'error');
		});
	};

	input.addEventListener('keydown', function(ev) {
		if (ev.key === 'Enter') { ev.preventDefault(); doSave(); }
	});

	var cancelBtn = E('button', { 'class': 'btn' }, _('Cancel'));
	cancelBtn.addEventListener('click', function() { ui.hideModal(); });
	var saveBtn = E('button', { 'class': 'btn cbi-button-positive' }, _('Save'));
	saveBtn.addEventListener('click', doSave);

	ui.showModal(_('Rename device') + ' — ' + ip, [
		E('p', { 'class': 'tc-c-muted', 'style': 'font-size:12px' },
			_('Overrides the DHCP lease or DNS name. Leave empty to clear the custom name.')),
		E('div', { 'style': 'margin:10px 0' }, input),
		E('div', { 'class': 'right' }, [cancelBtn, ' ', saveBtn])
	]);
	setTimeout(function() { input.focus(); input.select(); }, 50);
}

function mkEthIcon(size) {
	var s = size || 14;
	var svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
	svg.setAttribute('width', s);
	svg.setAttribute('height', s);
	svg.setAttribute('viewBox', '0 0 24 24');
	svg.setAttribute('fill', 'none');
	svg.setAttribute('stroke', 'currentColor');
	svg.setAttribute('stroke-width', '2');
	svg.setAttribute('stroke-linecap', 'round');
	svg.setAttribute('stroke-linejoin', 'round');
	svg.setAttribute('class', 'tc-eth-icon');
	var path = document.createElementNS('http://www.w3.org/2000/svg', 'path');
	path.setAttribute('d', 'M4 7h16a1 1 0 0 1 1 1v8a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1V8a1 1 0 0 1 1-1zM7 11v2M10 11v2M13 11v2M16 11v2');
	svg.appendChild(path);
	return svg;
}

function renderSparkline(history, globalMax, width, height, limitKbit) {
	if (!history || history.length < 2) return null;
	var maxVal = globalMax || 1;
	var w = width || 60;
	var h = height || 20;
	var step = w / (history.length - 1);
	var points = [];
	for (var i = 0; i < history.length; i++) {
		var x = (i * step).toFixed(1);
		var y = (h - (history[i].speed / maxVal) * (h - 2) - 1).toFixed(1);
		points.push(x + ',' + y);
	}
	var svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
	svg.setAttribute('width', w);
	svg.setAttribute('height', h);
	svg.setAttribute('viewBox', '0 0 ' + w + ' ' + h);
	svg.style.cssText = 'display:block;margin:0 auto'; /* sparkline — kept inline (runtime/canvas) */
	var area = document.createElementNS('http://www.w3.org/2000/svg', 'polyline');
	area.setAttribute('points', '0,' + h + ' ' + points.join(' ') + ' ' + (w - 0) + ',' + h);
	area.setAttribute('fill', 'var(--tc-speed)');
	area.setAttribute('opacity', '0.1');
	area.setAttribute('stroke', 'none');
	svg.appendChild(area);
	// Rate limit line (dashed, red/orange)
	if (limitKbit && limitKbit > 0) {
		var limitBps = limitKbit * 1000 / 8;
		if (limitBps < maxVal) {
			var ly = (h - (limitBps / maxVal) * (h - 2) - 1).toFixed(1);
			var line = document.createElementNS('http://www.w3.org/2000/svg', 'line');
			line.setAttribute('x1', '0'); line.setAttribute('x2', String(w));
			line.setAttribute('y1', ly); line.setAttribute('y2', ly);
			line.setAttribute('stroke', 'var(--tc-warn)');
			line.setAttribute('stroke-width', '1');
			line.setAttribute('stroke-dasharray', '3,2');
			line.setAttribute('opacity', '0.7');
			svg.appendChild(line);
		}
	}
	var polyline = document.createElementNS('http://www.w3.org/2000/svg', 'polyline');
	polyline.setAttribute('points', points.join(' '));
	polyline.setAttribute('fill', 'none');
	polyline.setAttribute('stroke', 'var(--tc-speed)');
	polyline.setAttribute('stroke-width', '1.5');
	polyline.setAttribute('stroke-linejoin', 'round');
	svg.appendChild(polyline);
	return svg;
}

function renderFullGraph(history, limitKbit, width, height) {
	if (!history || history.length < 2) return null;
	var w = width || 440, h = height || 200;
	var pad = {top:22, right:14, bottom:32, left:56};
	var gw = w - pad.left - pad.right, gh = h - pad.top - pad.bottom;
	var gradIdSuffix = '-' + (++_fgGraphIdSeq);
	var ns = 'http://www.w3.org/2000/svg';

	var maxSpeed = 0, maxUp = 0;
	var hasUpload = history.some(function(p) { return p.up > 0; });
	// Use 98th percentile to ignore spikes
	var speeds = history.map(function(p) { return p.speed; }).sort(function(a,b){return a-b;});
	var p98idx = Math.min(speeds.length - 1, Math.floor(speeds.length * 0.98));
	maxSpeed = speeds[p98idx] || 0;
	// But ensure absolute max is at most 3x the p98 (clip extreme outliers visually)
	var absMax = speeds[speeds.length - 1];
	if (absMax > maxSpeed * 3) maxSpeed = maxSpeed * 1.5;
	else maxSpeed = absMax;
	history.forEach(function(p) { if (p.up > maxUp) maxUp = p.up; });
	var limitBps = limitKbit ? (limitKbit * 1000 / 8) : 0;
	if (limitBps > maxSpeed) maxSpeed = limitBps * 1.1;
	if (maxUp > maxSpeed) maxSpeed = maxUp;
	if (maxSpeed < 1) maxSpeed = 1;
	// Round maxSpeed up to a nice tick boundary (multiples of 100 or 500 kbit/s in bytes/s)
	var niceSteps = [100/8*1000, 200/8*1000, 500/8*1000, 1000/8*1000, 2000/8*1000, 5000/8*1000,
		10000/8*1000, 20000/8*1000, 50000/8*1000, 100000/8*1000, 200000/8*1000, 500000/8*1000, 1000000/8*1000];
	var tickStep = niceSteps[0];
	for (var ns_i = 0; ns_i < niceSteps.length; ns_i++) {
		if (maxSpeed / niceSteps[ns_i] <= 8) { tickStep = niceSteps[ns_i]; break; }
	}
	var gridCount = Math.max(5, Math.ceil(maxSpeed / tickStep));
	maxSpeed = gridCount * tickStep;

	var startTime = history[0].time;
	var endTime = history[history.length - 1].time;
	var duration = endTime - startTime || 1;

	function xScale(t) { return pad.left + ((t - startTime) / duration) * gw; }
	function yScale(v) { return pad.top + gh - (v / maxSpeed) * gh; }

	// Compute min/max bands (rolling window of 5 points)
	var bandData = [];
	var bandWin = Math.max(2, Math.min(5, Math.floor(history.length / 8)));
	for (var bi = 0; bi < history.length; bi++) {
		var lo = Infinity, hi = 0;
		for (var bj = Math.max(0, bi - bandWin); bj <= Math.min(history.length - 1, bi + bandWin); bj++) {
			if (history[bj].speed < lo) lo = history[bj].speed;
			if (history[bj].speed > hi) hi = history[bj].speed;
		}
		bandData.push({time: history[bi].time, lo: lo, hi: hi});
	}

	var svg = document.createElementNS(ns, 'svg');
	svg.setAttribute('width', w); svg.setAttribute('height', h);
	svg.setAttribute('viewBox', '0 0 ' + w + ' ' + h);
	svg.style.cssText = 'display:block;border-radius:8px;overflow:visible';

	// Gradient definition for download area
	var defs = document.createElementNS(ns, 'defs');
	var grad = document.createElementNS(ns, 'linearGradient');
	grad.setAttribute('id', 'fg-dl-grad'+gradIdSuffix); grad.setAttribute('x1', '0'); grad.setAttribute('y1', '0');
	grad.setAttribute('x2', '0'); grad.setAttribute('y2', '1');
	var stop1 = document.createElementNS(ns, 'stop');
	stop1.setAttribute('offset', '0%'); stop1.setAttribute('stop-color', 'var(--tc-speed)'); stop1.setAttribute('stop-opacity', '0.35');
	var stop2 = document.createElementNS(ns, 'stop');
	stop2.setAttribute('offset', '100%'); stop2.setAttribute('stop-color', 'var(--tc-speed)'); stop2.setAttribute('stop-opacity', '0.03');
	grad.appendChild(stop1); grad.appendChild(stop2); defs.appendChild(grad);

	// Gradient for upload area
	var gradUp = document.createElementNS(ns, 'linearGradient');
	gradUp.setAttribute('id', 'fg-ul-grad'+gradIdSuffix); gradUp.setAttribute('x1', '0'); gradUp.setAttribute('y1', '0');
	gradUp.setAttribute('x2', '0'); gradUp.setAttribute('y2', '1');
	var stopU1 = document.createElementNS(ns, 'stop');
	stopU1.setAttribute('offset', '0%'); stopU1.setAttribute('stop-color', 'var(--tc-ok)'); stopU1.setAttribute('stop-opacity', '0.25');
	var stopU2 = document.createElementNS(ns, 'stop');
	stopU2.setAttribute('offset', '100%'); stopU2.setAttribute('stop-color', 'var(--tc-ok)'); stopU2.setAttribute('stop-opacity', '0.02');
	gradUp.appendChild(stopU1); gradUp.appendChild(stopU2); defs.appendChild(gradUp);
	svg.appendChild(defs);

	// Background
	var bg = document.createElementNS(ns, 'rect');
	bg.setAttribute('width', w); bg.setAttribute('height', h);
	bg.setAttribute('fill', 'var(--tc-bg)'); bg.setAttribute('rx', '8');
	svg.appendChild(bg);

	// Grid lines — nice tick values, at least 5 lines, label every 2nd if crowded
	var labelEvery = gridCount > 7 ? 2 : 1;
	for (var gi = 0; gi <= gridCount; gi++) {
		var val = gi * tickStep;
		var gy = yScale(val);
		var gl = document.createElementNS(ns, 'line');
		gl.setAttribute('x1', pad.left); gl.setAttribute('x2', w - pad.right);
		gl.setAttribute('y1', gy.toFixed(1)); gl.setAttribute('y2', gy.toFixed(1));
		gl.setAttribute('stroke', 'var(--tc-border)'); gl.setAttribute('stroke-width', '0.5');
		gl.setAttribute('stroke-dasharray', '2,2');
		svg.appendChild(gl);
		if (gi > 0 && gi % labelEvery === 0) {
			var lbl = document.createElementNS(ns, 'text');
			lbl.setAttribute('x', pad.left - 4); lbl.setAttribute('y', (gy + 3).toFixed(1));
			lbl.setAttribute('text-anchor', 'end');
			lbl.setAttribute('font-size', '9'); lbl.setAttribute('fill', 'var(--tc-muted)');
			lbl.textContent = fmtSpeed(val);
			svg.appendChild(lbl);
		}
	}

	// Time axis
	var ticks = 6;
	for (var ti = 0; ti <= ticks; ti++) {
		var tx = xScale(startTime + (ti / ticks) * duration);
		var secs = Math.round(((ti / ticks) * duration) / 1000);
		var tl = document.createElementNS(ns, 'text');
		tl.setAttribute('x', tx.toFixed(1)); tl.setAttribute('y', (h - 8).toFixed(1));
		tl.setAttribute('text-anchor', 'middle');
		tl.setAttribute('font-size', '9'); tl.setAttribute('fill', 'var(--tc-muted)');
		if (secs < 60) tl.textContent = secs + 's';
		else tl.textContent = Math.floor(secs/60) + 'm' + (secs%60 ? (secs%60)+'s' : '');
		svg.appendChild(tl);
		// Vertical grid tick
		var vtick = document.createElementNS(ns, 'line');
		vtick.setAttribute('x1', tx.toFixed(1)); vtick.setAttribute('x2', tx.toFixed(1));
		vtick.setAttribute('y1', pad.top); vtick.setAttribute('y2', pad.top + gh);
		vtick.setAttribute('stroke', 'var(--tc-border)'); vtick.setAttribute('stroke-width', '0.3');
		vtick.setAttribute('stroke-dasharray', '2,4');
		svg.appendChild(vtick);
	}

	// Min/max band (translucent fill between low and high)
	if (bandData.length > 2) {
		var bandPath = 'M' + xScale(bandData[0].time).toFixed(1) + ',' + yScale(bandData[0].hi).toFixed(1);
		for (var bk = 1; bk < bandData.length; bk++) {
			bandPath += ' L' + xScale(bandData[bk].time).toFixed(1) + ',' + yScale(bandData[bk].hi).toFixed(1);
		}
		for (var bl = bandData.length - 1; bl >= 0; bl--) {
			bandPath += ' L' + xScale(bandData[bl].time).toFixed(1) + ',' + yScale(bandData[bl].lo).toFixed(1);
		}
		bandPath += ' Z';
		var bandEl = document.createElementNS(ns, 'path');
		bandEl.setAttribute('d', bandPath);
		bandEl.setAttribute('fill', 'var(--tc-speed)'); bandEl.setAttribute('opacity', '0.08');
		svg.appendChild(bandEl);
	}

	// Download area (gradient fill)
	var dlPoints = [];
	history.forEach(function(p) { dlPoints.push(xScale(p.time).toFixed(1) + ',' + yScale(p.speed).toFixed(1)); });
	var dlArea = document.createElementNS(ns, 'polyline');
	dlArea.setAttribute('points', xScale(startTime).toFixed(1)+','+(pad.top+gh)+' '+dlPoints.join(' ')+' '+xScale(endTime).toFixed(1)+','+(pad.top+gh));
	dlArea.setAttribute('fill', 'url(#fg-dl-grad'+gradIdSuffix+')'); dlArea.setAttribute('stroke', 'none');
	svg.appendChild(dlArea);

	// Download line
	var dlLine = document.createElementNS(ns, 'polyline');
	dlLine.setAttribute('points', dlPoints.join(' '));
	dlLine.setAttribute('fill', 'none'); dlLine.setAttribute('stroke', 'var(--tc-speed)');
	dlLine.setAttribute('stroke-width', '2'); dlLine.setAttribute('stroke-linejoin', 'round'); dlLine.setAttribute('stroke-linecap', 'round');
	svg.appendChild(dlLine);

	// Upload line + area (if data available)
	if (hasUpload) {
		var ulPoints = [];
		history.forEach(function(p) { ulPoints.push(xScale(p.time).toFixed(1) + ',' + yScale(p.up || 0).toFixed(1)); });
		var ulArea = document.createElementNS(ns, 'polyline');
		ulArea.setAttribute('points', xScale(startTime).toFixed(1)+','+(pad.top+gh)+' '+ulPoints.join(' ')+' '+xScale(endTime).toFixed(1)+','+(pad.top+gh));
		ulArea.setAttribute('fill', 'url(#fg-ul-grad'+gradIdSuffix+')'); ulArea.setAttribute('stroke', 'none');
		svg.appendChild(ulArea);
		var ulLine = document.createElementNS(ns, 'polyline');
		ulLine.setAttribute('points', ulPoints.join(' '));
		ulLine.setAttribute('fill', 'none'); ulLine.setAttribute('stroke', 'var(--tc-ok)');
		ulLine.setAttribute('stroke-width', '1.5'); ulLine.setAttribute('stroke-linejoin', 'round');
		ulLine.setAttribute('stroke-dasharray', '4,2'); ulLine.setAttribute('opacity', '0.8');
		svg.appendChild(ulLine);
	}

	// Limit line with label
	if (limitBps > 0) {
		var ly = yScale(limitBps);
		var ll = document.createElementNS(ns, 'line');
		ll.setAttribute('x1', pad.left); ll.setAttribute('x2', w - pad.right);
		ll.setAttribute('y1', ly.toFixed(1)); ll.setAttribute('y2', ly.toFixed(1));
		ll.setAttribute('stroke', 'var(--tc-warn)'); ll.setAttribute('stroke-width', '1.5');
		ll.setAttribute('stroke-dasharray', '6,3'); ll.setAttribute('opacity', '0.85');
		svg.appendChild(ll);
		// Label background
		var limTxt = fmtRate(limitKbit);
		var limLbl = document.createElementNS(ns, 'text');
		limLbl.setAttribute('x', (w - pad.right - 3).toFixed(1)); limLbl.setAttribute('y', (ly - 5).toFixed(1));
		limLbl.setAttribute('text-anchor', 'end');
		limLbl.setAttribute('font-size', '9'); limLbl.setAttribute('fill', 'var(--tc-warn)'); limLbl.setAttribute('font-weight', '600');
		limLbl.textContent = '⚡ ' + limTxt;
		svg.appendChild(limLbl);
	}

	// Legend (top-right corner)
	var legendX = w - pad.right - 4;
	var legendY = pad.top + 4;
	var dlLeg = document.createElementNS(ns, 'text');
	dlLeg.setAttribute('x', legendX); dlLeg.setAttribute('y', legendY);
	dlLeg.setAttribute('text-anchor', 'end'); dlLeg.setAttribute('font-size', '9');
	dlLeg.setAttribute('fill', 'var(--tc-speed)'); dlLeg.setAttribute('font-weight', '600');
	dlLeg.textContent = '↓ DL';
	svg.appendChild(dlLeg);
	if (hasUpload) {
		var ulLeg = document.createElementNS(ns, 'text');
		ulLeg.setAttribute('x', legendX); ulLeg.setAttribute('y', legendY + 12);
		ulLeg.setAttribute('text-anchor', 'end'); ulLeg.setAttribute('font-size', '9');
		ulLeg.setAttribute('fill', 'var(--tc-ok)'); ulLeg.setAttribute('font-weight', '600');
		ulLeg.textContent = '↑ UL';
		svg.appendChild(ulLeg);
	}

	// Current value annotation (last point)
	var lastP = history[history.length - 1];
	var lastX = xScale(lastP.time);
	var lastY = yScale(lastP.speed);
	var dot = document.createElementNS(ns, 'circle');
	dot.setAttribute('cx', lastX.toFixed(1)); dot.setAttribute('cy', lastY.toFixed(1));
	dot.setAttribute('r', '3.5'); dot.setAttribute('fill', 'var(--tc-speed)'); dot.setAttribute('stroke', 'var(--tc-bg)'); dot.setAttribute('stroke-width', '1.5');
	svg.appendChild(dot);
	var curLbl = document.createElementNS(ns, 'text');
	curLbl.setAttribute('x', (lastX - 6).toFixed(1)); curLbl.setAttribute('y', (lastY - 8).toFixed(1));
	curLbl.setAttribute('text-anchor', 'end'); curLbl.setAttribute('font-size', '10');
	curLbl.setAttribute('fill', 'var(--tc-speed)'); curLbl.setAttribute('font-weight', '700');
	curLbl.textContent = fmtSpeed(lastP.speed);
	svg.appendChild(curLbl);

	// Interactive crosshair overlay (mouse tracking)
	var overlay = document.createElementNS(ns, 'rect');
	overlay.setAttribute('x', pad.left); overlay.setAttribute('y', pad.top);
	overlay.setAttribute('width', gw); overlay.setAttribute('height', gh);
	overlay.setAttribute('fill', 'transparent'); overlay.setAttribute('style', 'cursor:crosshair');
	var crossV = document.createElementNS(ns, 'line');
	crossV.setAttribute('y1', pad.top); crossV.setAttribute('y2', pad.top + gh);
	crossV.setAttribute('stroke', 'var(--tc-muted)'); crossV.setAttribute('stroke-width', '0.8');
	crossV.setAttribute('stroke-dasharray', '3,2'); crossV.setAttribute('display', 'none');
	var crossH = document.createElementNS(ns, 'line');
	crossH.setAttribute('x1', pad.left); crossH.setAttribute('x2', w - pad.right);
	crossH.setAttribute('stroke', 'var(--tc-muted)'); crossH.setAttribute('stroke-width', '0.8');
	crossH.setAttribute('stroke-dasharray', '3,2'); crossH.setAttribute('display', 'none');
	var crossDot = document.createElementNS(ns, 'circle');
	crossDot.setAttribute('r', '4'); crossDot.setAttribute('fill', 'var(--tc-speed)');
	crossDot.setAttribute('stroke', '#fff'); crossDot.setAttribute('stroke-width', '2'); crossDot.setAttribute('display', 'none');
	var crossLabel = document.createElementNS(ns, 'text');
	crossLabel.setAttribute('font-size', '10'); crossLabel.setAttribute('fill', 'currentColor');
	crossLabel.setAttribute('font-weight', '600'); crossLabel.setAttribute('display', 'none');
	var crossTime = document.createElementNS(ns, 'text');
	crossTime.setAttribute('font-size', '9'); crossTime.setAttribute('fill', 'var(--tc-muted)');
	crossTime.setAttribute('display', 'none');
	// Upload crosshair dot
	var crossDotUp = document.createElementNS(ns, 'circle');
	crossDotUp.setAttribute('r', '3'); crossDotUp.setAttribute('fill', 'var(--tc-ok)');
	crossDotUp.setAttribute('stroke', '#fff'); crossDotUp.setAttribute('stroke-width', '1.5'); crossDotUp.setAttribute('display', 'none');
	var crossLabelUp = document.createElementNS(ns, 'text');
	crossLabelUp.setAttribute('font-size', '9'); crossLabelUp.setAttribute('fill', 'var(--tc-ok)');
	crossLabelUp.setAttribute('font-weight', '500'); crossLabelUp.setAttribute('display', 'none');

	svg.appendChild(crossV); svg.appendChild(crossH);
	svg.appendChild(crossDot); svg.appendChild(crossDotUp);
	svg.appendChild(crossLabel); svg.appendChild(crossLabelUp); svg.appendChild(crossTime);
	svg.appendChild(overlay);

	overlay.addEventListener('mousemove', function(ev) {
		var rect = svg.getBoundingClientRect();
		var mx = ev.clientX - rect.left;
		var ratio = (mx - pad.left) / gw;
		if (ratio < 0) ratio = 0; if (ratio > 1) ratio = 1;
		var targetTime = startTime + ratio * duration;
		// Find closest point
		var closest = 0, minDist = Infinity;
		for (var ci = 0; ci < history.length; ci++) {
			var dist = Math.abs(history[ci].time - targetTime);
			if (dist < minDist) { minDist = dist; closest = ci; }
		}
		var pt = history[closest];
		var cx = xScale(pt.time), cy = yScale(pt.speed);
		crossV.setAttribute('x1', cx.toFixed(1)); crossV.setAttribute('x2', cx.toFixed(1)); crossV.setAttribute('display', '');
		crossH.setAttribute('y1', cy.toFixed(1)); crossH.setAttribute('y2', cy.toFixed(1)); crossH.setAttribute('display', '');
		crossDot.setAttribute('cx', cx.toFixed(1)); crossDot.setAttribute('cy', cy.toFixed(1)); crossDot.setAttribute('display', '');
		crossLabel.textContent = '↓ ' + fmtSpeed(pt.speed);
		var lblX = cx + 8, lblAnchor = 'start';
		if (lblX + 80 > w - pad.right) { lblX = cx - 8; lblAnchor = 'end'; }
		crossLabel.setAttribute('x', lblX.toFixed(1)); crossLabel.setAttribute('y', (cy - 10).toFixed(1));
		crossLabel.setAttribute('text-anchor', lblAnchor); crossLabel.setAttribute('display', '');
		// Time label at bottom
		var tSec = Math.round((pt.time - startTime) / 1000);
		crossTime.textContent = tSec + 's';
		crossTime.setAttribute('x', cx.toFixed(1)); crossTime.setAttribute('y', (pad.top + gh + 14).toFixed(1));
		crossTime.setAttribute('text-anchor', 'middle'); crossTime.setAttribute('display', '');
		// Upload dot
		if (hasUpload && pt.up > 0) {
			var cyUp = yScale(pt.up);
			crossDotUp.setAttribute('cx', cx.toFixed(1)); crossDotUp.setAttribute('cy', cyUp.toFixed(1)); crossDotUp.setAttribute('display', '');
			crossLabelUp.textContent = '↑ ' + fmtSpeed(pt.up);
			crossLabelUp.setAttribute('x', lblX.toFixed(1)); crossLabelUp.setAttribute('y', (cyUp + 14).toFixed(1));
			crossLabelUp.setAttribute('text-anchor', lblAnchor); crossLabelUp.setAttribute('display', '');
		} else {
			crossDotUp.setAttribute('display', 'none'); crossLabelUp.setAttribute('display', 'none');
		}
	});
	overlay.addEventListener('mouseleave', function() {
		crossV.setAttribute('display', 'none'); crossH.setAttribute('display', 'none');
		crossDot.setAttribute('display', 'none'); crossLabel.setAttribute('display', 'none');
		crossTime.setAttribute('display', 'none');
		crossDotUp.setAttribute('display', 'none'); crossLabelUp.setAttribute('display', 'none');
	});

	return svg;
}

/* styles come from status.css — no runtime injection needed */


// ── Global overview (issue #26 item 7) ──────────────────────────────────────
// A bmon-style read of the whole router rather than one row per client: what
// the uplink is doing right now, how that splits across the physical WAN, the
// LAN bridges and the VPN tunnels, and who is responsible for it.
//
// Every number here comes from a source that already existed — per-interface
// kernel counters (trafficctl-ifaces.sh) and the per-device speed map the
// summary table is already computing — so nothing new is collected or stored
// on the router.

var ROLE_ORDER = { wan: 0, vpn: 1, lan: 2, other: 3 };
var ROLE_LABEL = { wan: 'WAN', vpn: 'VPN', lan: 'LAN', other: '—' };

function ifaceRate(hist) {
	if (!hist || !hist.length) return { down: 0, up: 0 };
	var last = hist[hist.length - 1];
	return { down: last.speed || 0, up: last.up || 0 };
}

// One interface line: badge, name, sparkline, RX/TX rate, lifetime counters.
//
// RX/TX are INTERFACE-relative, exactly as bmon reports them, and are not
// flipped to be client-relative. On the WAN that makes RX the download; on
// br-lan RX is what the LAN sent upstream. Flipping the LAN rows to match the
// user's mental model would make the two halves of the same panel mean
// different things, so the header says which way round it is instead.
function mkIfaceRow(itf, hist, globalMax) {
	var rate = ifaceRate(hist);
	var cls = 'tc-ov-row' + (itf.up ? '' : ' tc-ov-row--down');
	var badge = E('span', {
		'class': 'tc-ov-badge tc-ov-badge--' + (ROLE_ORDER[itf.role] !== undefined ? itf.role : 'other')
	}, ROLE_LABEL[itf.role] || ROLE_LABEL.other);

	var nameCell = E('span', { 'class': 'tc-ov-ifname' }, [
		E('span', { 'class': 'tc-fw-bold' }, itf.label || itf.dev)
	]);
	// The kernel device name only earns its space when it differs from the
	// friendly uci name — on "lan"/"br-lan" it does, on an unnamed device it
	// would just repeat itself.
	if (itf.label && itf.label !== itf.dev) {
		nameCell.appendChild(E('span', { 'class': 'tc-c-faint tc-ov-ifdev' }, itf.dev));
	}
	if (itf.defroute) {
		nameCell.appendChild(E('span', {
			'class': 'tc-ov-defroute',
			'data-tip': _('Carries the default route')
		}, '↗'));
	}
	// Say it on the row as well as on the expander: once expanded, a port sitting
	// next to its bridge should be identifiable without counting bytes.
	if (itf.enslaved) {
		nameCell.appendChild(E('span', {
			'class': 'tc-c-faint tc-ov-ifdev',
			'data-tip': _('Bridge port — these bytes are also counted in its bridge')
		}, _('port')));
	}
	if (!itf.up) {
		nameCell.appendChild(E('span', { 'class': 'tc-c-err tc-ov-ifdev' }, _('down')));
	}

	var sparkCell = E('span', { 'class': 'tc-ov-spark' });
	var spark = renderSparkline(hist, globalMax, 74, 18, 0);
	if (spark) {
		sparkCell.appendChild(spark);
	}

	return E('div', { 'class': cls }, [
		badge,
		nameCell,
		sparkCell,
		E('span', { 'class': 'tc-ov-rate tc-mono tc-c-speed', 'data-tip': _('Received by this interface') },
			'↓ ' + fmtSpeed(rate.down)),
		E('span', { 'class': 'tc-ov-rate tc-mono tc-c-ok', 'data-tip': _('Sent by this interface') },
			'↑ ' + fmtSpeed(rate.up)),
		E('span', { 'class': 'tc-ov-total tc-mono tc-c-muted', 'data-tip': _('Total since boot (RX / TX)') },
			fmtBytes(itf.rx_bytes) + ' / ' + fmtBytes(itf.tx_bytes))
	]);
}

// "Who is using the line right now", aggregated instead of one row per device.
// Reads self._speedMap, which pollBytes() already maintains for the summary
// table — the overview adds no second source of truth for device speed.
function mkTopTalkers(speedMap, nameByIp) {
	var list = [];
	Object.keys(speedMap || {}).forEach(function(ip) {
		var sd = speedMap[ip] || {};
		var total = (sd.current || 0) + (sd.current_up || 0);
		if (total > 0) {
			list.push({ ip: ip, down: sd.current || 0, up: sd.current_up || 0, total: total });
		}
	});
	list.sort(function(a, b) { return b.total - a.total; });
	list = list.slice(0, TOP_TALKERS);

	var body = E('div', { 'class': 'tc-ov-talkers' });
	if (!list.length) {
		body.appendChild(E('div', { 'class': 'tc-c-faint tc-ov-empty' }, _('No active devices')));
		return body;
	}
	var peak = list[0].total || 1;
	list.forEach(function(t) {
		var label = nameByIp[t.ip] && nameByIp[t.ip] !== '*' ? nameByIp[t.ip] : t.ip;
		var pct = Math.max(2, Math.round((t.total / peak) * 100));
		body.appendChild(E('div', { 'class': 'tc-ov-talker' }, [
			E('div', { 'class': 'tc-ov-talker-head' }, [
				E('span', { 'class': 'tc-ov-talker-name', 'title': t.ip }, label),
				E('span', { 'class': 'tc-mono tc-ov-talker-rate' }, [
					E('span', { 'class': 'tc-c-speed' }, '↓ ' + fmtSpeed(t.down)),
					E('span', { 'class': 'tc-c-ok tc-ov-talker-up' }, '↑ ' + fmtSpeed(t.up))
				])
			]),
			E('div', { 'class': 'tc-ov-bar' }, [
				E('div', { 'class': 'tc-ov-bar-fill', 'style': 'width:' + pct + '%' })
			])
		]));
	});
	return body;
}

function mkOvTile(caption, value, sub, colourClass) {
	return E('div', { 'class': 'tc-ov-tile' }, [
		E('div', { 'class': 'tc-ov-tile-cap' }, caption),
		E('div', { 'class': 'tc-ov-tile-val tc-mono ' + (colourClass || '') }, value),
		E('div', { 'class': 'tc-ov-tile-sub tc-c-faint' }, sub || '')
	]);
}

// Builds the whole panel. Pure function of the state handed to it — it owns no
// timer and no listener outside the nodes it returns, so dropping the element
// is a complete teardown.
function buildOverviewPanel(ifaces, ifHistory, speedMap, nameByIp, showOther, onToggleOther, pollOff) {
	var wrap = E('div', { 'class': 'tc-overview' });
	if (!ifaces || !ifaces.length) {
		wrap.appendChild(E('div', { 'class': 'tc-c-faint tc-ov-empty' },
			_('Collecting interface counters…')));
		return wrap;
	}

	var primary = null;
	ifaces.forEach(function(i) { if (i.primary) { primary = i; } });
	if (!primary) { primary = ifaces[0]; }
	var primaryHist = ifHistory[primary.dev] || [];
	var primaryRate = ifaceRate(primaryHist);

	var activeDevices = 0;
	Object.keys(speedMap || {}).forEach(function(ip) {
		var sd = speedMap[ip] || {};
		if ((sd.current || 0) + (sd.current_up || 0) > 0) { activeDevices++; }
	});

	// ── headline tiles ──────────────────────────────────────────────────
	var head = E('div', { 'class': 'tc-ov-tiles' }, [
		mkOvTile(_('Download') + ' · ' + (primary.label || primary.dev),
			fmtSpeed(primaryRate.down), fmtBytes(primary.rx_bytes) + ' ' + _('total'), 'tc-c-speed'),
		mkOvTile(_('Upload') + ' · ' + (primary.label || primary.dev),
			fmtSpeed(primaryRate.up), fmtBytes(primary.tx_bytes) + ' ' + _('total'), 'tc-c-ok'),
		mkOvTile(_('Active devices'), String(activeDevices),
			_('sending or receiving now'), '')
	]);
	wrap.appendChild(head);

	// ── uplink graph ────────────────────────────────────────────────────
	// One WAN, not a sum of all of them: on a failover pair the same bytes
	// would be counted twice, and on two independent uplinks the sum is a
	// number that describes neither link. Multi-WAN aggregation is issue #28.
	var graphBox = E('div', { 'class': 'tc-ov-graph' });
	var w = 560;
	var svg = renderFullGraph(primaryHist, 0, w, 150);
	if (svg) {
		graphBox.appendChild(svg);
	} else if (pollOff) {
		// With Poll set to Off there is no second sample coming, ever — the
		// rates are a diff of two polls. Promising one that will never arrive
		// would send the user looking for a fault instead of at the Poll chip.
		graphBox.appendChild(E('div', { 'class': 'tc-c-faint tc-ov-empty' },
			_('Polling is off — set the Poll interval to see throughput.')));
	} else {
		graphBox.appendChild(E('div', { 'class': 'tc-c-faint tc-ov-empty' },
			_('Waiting for a second sample…')));
	}
	wrap.appendChild(graphBox);

	// ── per-interface breakdown + top talkers ───────────────────────────
	var sorted = ifaces.slice().sort(function(a, b) {
		var ra = ROLE_ORDER[a.role] !== undefined ? ROLE_ORDER[a.role] : 3;
		var rb = ROLE_ORDER[b.role] !== undefined ? ROLE_ORDER[b.role] : 3;
		if (ra !== rb) return ra - rb;
		var sa = ifaceRate(ifHistory[a.dev]), sb = ifaceRate(ifHistory[b.dev]);
		return (sb.down + sb.up) - (sa.down + sa.up);
	});

	// One scale for every sparkline, so the rows are comparable with each
	// other at a glance — a per-row scale would make an idle tunnel look as
	// busy as the WAN.
	var globalMax = 1;
	sorted.forEach(function(i) {
		(ifHistory[i.dev] || []).forEach(function(p) {
			if (p.speed > globalMax) { globalMax = p.speed; }
		});
	});

	var ifList = E('div', { 'class': 'tc-ov-iflist' });
	var others = [];
	sorted.forEach(function(i) {
		if (i.role === 'other') { others.push(i); return; }
		ifList.appendChild(mkIfaceRow(i, ifHistory[i.dev], globalMax));
	});
	// "other" is where bridge ports (lan2, phy0-ap0 …), the DSA conduit beneath
	// the uplink, ifb mirrors including the shaper's own tctl-ifb0, and dummy
	// devices land. Their counters are real but they re-count bytes the bridge
	// or the uplink above already reports, so they are collapsed by default and
	// the expander says why — dropping them silently would hide real devices,
	// listing them flat would make the panel look like it is double-counting.
	if (others.length) {
		if (showOther) {
			others.forEach(function(i) {
				ifList.appendChild(mkIfaceRow(i, ifHistory[i.dev], globalMax));
			});
		}
		var toggle = E('div', {
			'class': 'tc-ov-more',
			'data-tip': _('Bridge ports, switch conduits and ifb mirrors. Their bytes are already counted in the bridge or uplink above.')
		}, (showOther ? '▾ ' : '▸ ') + _('Other interfaces') + ' (' + others.length + ')');
		toggle.addEventListener('click', function() { onToggleOther(!showOther); });
		ifList.appendChild(toggle);
	}

	wrap.appendChild(E('div', { 'class': 'tc-ov-cols' }, [
		E('div', { 'class': 'tc-ov-col' }, [
			E('div', { 'class': 'tc-ov-subtitle' }, _('Interfaces')),
			ifList,
			E('div', { 'class': 'tc-c-faint tc-ov-note' },
				_('↓ / ↑ are relative to the interface: on the WAN ↓ is your download, on a LAN bridge ↓ is what the LAN sent upstream.'))
		]),
		E('div', { 'class': 'tc-ov-col' }, [
			E('div', { 'class': 'tc-ov-subtitle' }, _('Top talkers')),
			mkTopTalkers(speedMap, nameByIp)
		])
	]));

	return wrap;
}

var PRIVATE_RE = /^(192\.168\.|10\.|172\.(1[6-9]|2[0-9]|3[01])\.)/;

function groupConnections(conns, groupBy) {
	if (groupBy === 'none') return null;
	var keyFn;
	switch(groupBy) {
		case 'host':    keyFn = function(c){ return c.host || c.dst || '?'; }; break;
		case 'service': keyFn = function(c){ return c.service || SERVICE_PORTS[c.port] || ('port '+c.port); }; break;
		case 'port':    keyFn = function(c){ return String(c.port); }; break;
		case 'proto':   keyFn = function(c){ return c.proto || '?'; }; break;
		default:        return null;
	}
	var groups = {};
	conns.forEach(function(c) {
		var k = keyFn(c);
		if (!groups[k]) groups[k] = {key: k, count: 0, bytes: 0, tcp: 0, udp: 0, sample: c};
		groups[k].count++;
		groups[k].bytes += (c.bytes || 0);
		if (c.proto === 'tcp') groups[k].tcp++;
		else if (c.proto === 'udp') groups[k].udp++;
	});
	return Object.keys(groups).map(function(k){ return groups[k]; });
}

function buildGroupedTable(groups, sortCol, sortDir) {
	var cols = [
		{ key:'key',   label: _('Group'), num:false },
		{ key:'count', label: _('Conns'), num:true  },
		{ key:'tcp',   label:'TCP',       num:true  },
		{ key:'udp',   label:'UDP',       num:true  },
		{ key:'bytes', label: _('Bytes'), num:true  }
	];

	var sorted = groups.slice().sort(function(a, b) {
		var av = a[sortCol], bv = b[sortCol];
		if (typeof av === 'number') return sortDir === 'asc' ? av - bv : bv - av;
		av = String(av||''); bv = String(bv||'');
		return sortDir === 'asc' ? av.localeCompare(bv) : bv.localeCompare(av);
	});

	var titleRow = E('div', { 'class': 'tr cbi-section-table-titles' }, cols.map(function(c) {
		var arrow = c.key === sortCol ? (sortDir === 'asc' ? ' ▲' : ' ▼') : '';
		return E('div', { 'class': 'th', 'data-col': c.key, 'data-num': c.num ? '1' : '0' }, c.label + arrow);
	}));

	var rows = sorted.map(function(r) {
		return E('div', { 'class': 'tr' }, [
			E('div', { 'class': 'td tc-c-speed tc-fw-bold' }, escHtml(r.key)),
			E('div', { 'class': 'td tc-right tc-fw-bold' }, String(r.count)),
			E('div', { 'class': 'td tc-right tc-c-speed' }, String(r.tcp)),
			E('div', { 'class': 'td tc-right tc-c-warn' }, String(r.udp)),
			E('div', { 'class': 'td tc-right tc-mono' }, fmtBytes(r.bytes))
		]);
	});

	return E('div', { 'class': 'table tc-table' }, [titleRow].concat(rows));
}

function buildTable(conns, sortCol, sortDir, rdnsMode, hiddenCols) {
	var allCols = [
		{ key:'proto',   label: _('Proto'),    num:false },
		{ key:'dst',     label: _('Dst IP'),   num:false },
		{ key:'host',    label: _('Hostname'), num:false },
		{ key:'port',    label: _('Port'),     num:true  },
		{ key:'service', label: _('Service'),  num:false },
		{ key:'bytes',   label: _('Bytes'),    num:true  },
		{ key:'state',   label: _('State'),    num:false },
		{ key:'oif',     label: _('Iface'),    num:false }
	];
	var hid = hiddenCols || {};
	var cols = allCols.filter(function(c) { return !hid[c.key]; });

	var sorted = conns.slice().sort(function(a, b) {
		var av = a[sortCol], bv = b[sortCol];
		if (typeof av === 'number') return sortDir === 'asc' ? av - bv : bv - av;
		av = String(av||''); bv = String(bv||'');
		return sortDir === 'asc' ? av.localeCompare(bv) : bv.localeCompare(av);
	});

	var titleRow = E('div', { 'class': 'tr cbi-section-table-titles' }, cols.map(function(c) {
		var arrow = c.key === sortCol ? (sortDir === 'asc' ? ' ▲' : ' ▼') : '';
		return E('div', { 'class': 'th', 'data-col': c.key, 'data-num': c.num ? '1' : '0' }, c.label + arrow);
	}));

	var rows = sorted.map(function(r) {
		var state = escHtml(r.state || '');
		var scCls = state === 'ESTABLISHED' ? ' tc-c-ok' : state === 'TIME_WAIT' ? ' tc-c-err' : state === 'CLOSE_WAIT' ? ' tc-c-warn' : '';

		var dst = r.dst || '';
		var dstEl = dst
			? E('a', { 'href': 'https://ipinfo.io/'+dst, 'target': '_blank', 'rel': 'noopener noreferrer',
			           'class':'tc-link', 'onclick': 'event.stopPropagation()' }, dst)
			: '';

		var hostCell = E('div', { 'class': 'td', 'data-dst': dst });
		if (r.host) {
			hostCell.textContent = r.host;
		} else if (rdnsMode && !PRIVATE_RE.test(dst)) {
			hostCell.innerHTML = '<span class="tc-c-faint" style="font-style:italic">' + _('resolving…') + '</span>';
		} else {
			hostCell.textContent = '—';
		}

		var cellMap = {
			proto:   E('div', { 'class': 'td tc-fw-bold tc-c-speed' }, r.proto || ''),
			dst:     E('div', { 'class': 'td tc-mono' }, dstEl),
			host:    hostCell,
			port:    E('div', { 'class': 'td tc-right tc-mono' }, String(r.port || '')),
			service: E('div', { 'class': 'td tc-c-speed' }, escHtml(r.service || (SERVICE_PORTS[r.port]||''))),
			bytes:   E('div', { 'class': 'td tc-right tc-mono tc-fw-bold' }, fmtBytes(r.bytes)),
			state:   E('div', { 'class': 'td tc-fw-bold' + scCls }, state),
			oif:     E('div', { 'class': 'td tc-mono' }, r.oif ? escHtml(r.oif) : E('span', { 'class': 'tc-c-faint' }, '—'))
		};
		var cells = cols.map(function(c) { return cellMap[c.key]; });
		return E('div', { 'class': 'tr' }, cells);
	});

	return E('div', { 'class': 'table tc-table' }, [titleRow].concat(rows));
}

function buildSummaryTable(rows, sortCol, sortDir, onSort, onSelect, speedMap, dropMap, shapeMap, speedHistory, hiddenCols) {
	var cols = [
		{ key:'name',             label: _('Device'),   num:false, tip: _('Device hostname from DHCP lease') },
		{ key:'ip',               label:'IP',           num:false, tip: _('Local IP address') },
		{ key:'mac',              label:'MAC',          num:false, tip: _('Hardware MAC address'), hide:true },
		{ key:'_speed',           label: _('DL Speed'), num:true,  tip: _('Current download speed (bytes/sec from router to device)') },
		{ key:'_speed_up',        label: _('UL Speed'), num:true,  tip: _('Current upload speed (bytes/sec from device to router)') },
		{ key:'_spark',           label: '',            num:false, tip: _('Speed graph. Window = avg time. Orange dashed line = speed limit') },
		{ key:'conns',            label: _('Conns'),    num:true,  tip: _('Active connections in conntrack') },
		{ key:'total',            label: _('Bytes'),    num:true,  tip: _('Total bytes transferred (download + upload), accumulated on the router. Resets on reboot; hover a cell for the start time'), hide:true },
		{ key:'tcp',              label:'TCP',          num:true,  tip: _('TCP bytes transferred, accumulated on the router. Not measurable while flow offload is active'), hide:true },
		{ key:'udp',              label:'UDP',          num:true,  tip: _('UDP bytes transferred, accumulated on the router. Not measurable while flow offload is active'), hide:true },
		{ key:'blocked',          label: _('Inet'),     num:false, tip: _('Internet access status (paused = traffic blocked)') },
		{ key:'conn_type',        label: _('Link'),     num:false, tip: _('Connection interface (WiFi band, LAN port or routed)') },
		{ key:'app',              label: _('App'),      num:false, tip: _('Top application by traffic (needs the netifyd DPI agent)') },
		{ key:'_throttle_kbit',   label: _('Limit'),            num:true,  tip: _('Speed limit: shaper (queue) or limiter (drop)') },
		{ key:'_drop_packets',    label: _('Drop'),           num:true,  tip: _('Packets dropped by rate limiter'), hide:true },
		{ key:'_backlog',         label: '📦',           num:true,  tip: _('Bytes queued in traffic shaper'), hide:true }
	];

	hiddenCols = hiddenCols || {};
	var visibleCols = cols.filter(function(c) { return !hiddenCols[c.key]; });

	function ipToInt(s) {
		var p = String(s||'').split('.');
		if (p.length !== 4) return 0;
		return ((parseInt(p[0])||0)*16777216 + (parseInt(p[1])||0)*65536 + (parseInt(p[2])||0)*256 + (parseInt(p[3])||0));
	}

	speedMap = speedMap || {};
	dropMap  = dropMap  || {};
	shapeMap = shapeMap || {};
	speedHistory = speedHistory || {};

	var globalSpeedMax = 0;
	Object.keys(speedHistory).forEach(function(ip) {
		var hist = speedHistory[ip];
		if (hist) {
			hist.forEach(function(h) { if (h.speed > globalSpeedMax) globalSpeedMax = h.speed; });
		}
	});

	rows.forEach(function(r) {
		var s = speedMap[r.ip];
		r._speed = s ? s.current : 0;
		r._speed_up = s ? (s.current_up || 0) : 0;
		var d = dropMap[r.ip];
		r._drop_packets = d ? d.packets : 0;
		r._drop_bytes   = d ? d.bytes   : 0;
		var sh = shapeMap[r.ip];
		r._backlog = sh ? sh.backlog : 0;
		r._throttle_kbit = (r.shape_kbit || 0) > 0 ? r.shape_kbit : (r.rate_limit_kbit || 0);
		r._throttle_mode = (r.shape_kbit || 0) > 0 ? 'shaper' : ((r.rate_limit_kbit || 0) > 0 ? 'limiter' : 'none');
	});

	var sorted = rows.slice().sort(function(a, b) {
		var av = a[sortCol], bv = b[sortCol];
		if (typeof av === 'number') {
			var diff = sortDir === 'asc' ? av - bv : bv - av;
			if (diff !== 0) return diff;
			return String(a.name || '').localeCompare(String(b.name || ''));
		}
		if (typeof av === 'boolean') return sortDir === 'asc' ? (av?1:0)-(bv?1:0) : (bv?1:0)-(av?1:0);
		if (sortCol === 'ip') {
			var d = ipToInt(av) - ipToInt(bv);
			return sortDir === 'asc' ? d : -d;
		}
		av = String(av||''); bv = String(bv||'');
		return sortDir === 'asc' ? av.localeCompare(bv) : bv.localeCompare(av);
	});

	var hasSpeedData = Object.keys(speedMap).length > 0;
	var titleRow = E('div', { 'class': 'tr cbi-section-table-titles' }, visibleCols.map(function(c) {
		var arrow = c.key === sortCol ? (sortDir === 'asc' ? ' ▲' : ' ▼') : '';
		var compact = c.key === '_spark' || c.key === '_throttle_kbit' || c.key === '_drop_packets' || c.key === '_backlog';
		var style = (c.key === '_spark' ? 'cursor:default;width:68px;' : '') + (compact ? 'white-space:nowrap;width:1%;' : '');
		var attrs = { 'class': 'th', 'style': style || undefined, 'data-col': c.key, 'data-num': c.num ? '1' : '0' };
		if (c.tip) attrs['data-tip'] = c.tip;
		var label = c.label + arrow;
		if (c.key === '_speed' && !hasSpeedData) label = c.label + ' ';
		var th = E('div', attrs);
		th.innerHTML = label + ((c.key === '_speed' && !hasSpeedData) ? '<span class="tc-spinner"></span>' : '');
		if (c.key !== '_spark') th.addEventListener('click', function() { onSort(c.key, c.num); });
		return th;
	}));

	var tableRows = sorted.map(function(r) {
		var sd = speedMap[r.ip];
		var cellMap = {};

		var nameText = E('span', {}, escHtml(r.name));
		var renameBtn = E('span', {
			'class': 'tc-rename',
			'title': _('Rename device')
		}, '✎');
		renameBtn.addEventListener('click', function(ev) {
			ev.stopPropagation();
			promptRename(r.ip, r.name, function(newName) {
				r.name = newName || '*';
				nameText.textContent = r.name;
			});
		});
		cellMap.name = E('div', { 'class': 'td tc-fw-bold tc-c-speed tc-name-cell' }, [nameText, renameBtn]);
		cellMap.ip   = E('div', { 'class': 'td tc-mono' }, escHtml(r.ip));
		var macEl = r.mac ? E('a', { 'href':'/cgi-bin/luci/admin/network/dhcp','target':'_blank','rel':'noopener','class':'tc-link','title':_('Open DHCP/DNS bindings'),'onclick':'event.stopPropagation()' }, r.mac) : '';
		cellMap.mac  = E('div', { 'class': 'td tc-mono tc-sm tc-c-muted' }, macEl || '');

		// Down and up are measured separately (bytes_in / bytes_out); showing
		// only the download half hid the entire upload side of every device.
		cellMap._speed = E('div', {
			'class': 'td tc-right tc-mono',
			'data-speed-ip': r.ip,
			'title': sd ? (_('Avg')+': '+fmtSpeed(sd.avg)+' / '+_('Max')+': '+fmtSpeed(sd.max)) : _('Calculating…')
		});
		renderSpeedCell(cellMap._speed, sd);

		cellMap._speed_up = E('div', { 'class': 'td tc-right tc-mono', 'data-speed-up-ip': r.ip, 'title': sd ? (_('Avg')+': '+fmtSpeed(sd.avg_up||0)+' / '+_('Max')+': '+fmtSpeed(sd.max_up||0)) : _('Calculating…') });
		if (sd && (sd.current_up||0) > 1024) { cellMap._speed_up.className = 'td tc-right tc-mono tc-speed-active'; cellMap._speed_up.textContent = fmtSpeed(sd.current_up); }
		else { cellMap._speed_up.className = 'td tc-right tc-mono tc-speed-idle'; cellMap._speed_up.textContent = sd ? fmtSpeed(sd.current_up||0) : '—'; }

		var sparkTip = r._throttle_kbit > 0 ? (_('Limit') + ': ' + fmtRate(r._throttle_kbit)) : '';
		cellMap._spark = E('div', { 'class': 'td tc-center', 'style': 'padding:2px 4px', 'data-spark-ip': r.ip, 'data-tip': sparkTip || undefined });
		var sparkSvg = renderSparkline(speedHistory[r.ip], globalSpeedMax, 60, 20, r._throttle_kbit);
		if (sparkSvg) cellMap._spark.appendChild(sparkSvg);

		cellMap.conns = E('div', { 'class': 'td tc-right tc-fw-bold' }, String(r.conns||0));
		// Filled from the byte poll rather than from this row, so the totals
		// keep climbing between table rebuilds (see updateTotalCells).
		cellMap.total = E('div', { 'class': 'td tc-right tc-mono tc-sm', 'data-total-ip': r.ip });
		cellMap.tcp   = E('div', { 'class': 'td tc-right tc-mono tc-sm tc-c-speed', 'data-total-tcp-ip': r.ip });
		cellMap.udp   = E('div', { 'class': 'td tc-right tc-mono tc-sm tc-c-warn', 'data-total-udp-ip': r.ip });
		renderTotalCell(cellMap.total, r.total, r._live_total, r._total_since, r._total_pending, r._total_degraded);
		renderTotalCell(cellMap.tcp,   r.tcp,   r._live_tcp,   r._total_since, r._total_pending, r._total_degraded);
		renderTotalCell(cellMap.udp,   r.udp,   r._live_udp,   r._total_since, r._total_pending, r._total_degraded);

		var inetBadge = r.blocked
			? E('span', { 'class': 'tc-c-warn tc-fw-bold' }, '⏸ ' + _('blocked'))
			: E('span', { 'class': 'tc-c-faint' }, '—');
		cellMap.blocked = E('div', { 'class': 'td tc-center' }, inetBadge);

		var linkBadge;
		var ct = r.conn_type || 'ethernet';
		var isWifi = (ct === 'wifi' || ct === '2.4G' || ct === '5G' || ct === '6G');
		if (ct === '?') {
			var tip = _('Unknown — device unreachable');
			if (r.conn_last) {
				var parts = r.conn_last.split('@');
				var lastType = parts[0] || '';
				var lastTs = parseInt(parts[1], 10);
				if (lastTs) {
					var ago = Math.floor((Date.now()/1000) - lastTs);
					var agoStr = ago < 60 ? ago + 's' : ago < 3600 ? Math.floor(ago/60) + 'm' : Math.floor(ago/3600) + 'h';
					tip = _('Last seen') + ': ' + lastType + ', ' + agoStr + ' ' + _('ago');
				}
			}
			linkBadge = E('span', { 'class': 'tc-c-faint', 'style': 'cursor:help', 'title': tip }, '?');
		} else if (ct === 'routed') {
			linkBadge = E('span', { 'class': 'tc-c-muted', 'style': 'cursor:help', 'title': _('Behind a downstream router (routed subnet)') }, '⇄ ' + _('routed'));
		} else if (isWifi) {
			var wLabel = ct === 'wifi' ? 'WiFi' : ct;
			linkBadge = r.wifi_blocked
				? E('span', { 'class': 'tc-c-warn tc-fw-bold', 'style': 'text-decoration:line-through' }, wLabel)
				: E('span', { 'class': 'tc-c-speed' }, wLabel);
		} else {
			var ethLabel = (ct === 'ethernet') ? 'eth' : ct;
			linkBadge = E('span', { 'class': 'tc-c-muted' }, [mkEthIcon(14), document.createTextNode(ethLabel)]);
		}
		cellMap.conn_type = E('div', { 'class': 'td tc-center' }, linkBadge);

		var appBadge;
		if (r.app) {
			var appDetail = netifyMap[r.ip];
			var appTip = _('Top application by traffic');
			if (appDetail && appDetail.apps && appDetail.apps.length) {
				appTip = appDetail.apps.slice(0, 5).map(function(a) {
					return a.name + ' — ' + fmtBytes(a.bytes);
				}).join('\n');
			}
			appBadge = E('span', { 'class': 'tc-app-badge', 'title': appTip }, escHtml(r.app));
		} else {
			appBadge = E('span', { 'class': 'tc-c-faint' }, '—');
		}
		cellMap.app = E('div', { 'class': 'td tc-center' }, appBadge);

		var throttleBadge;
		if (r._throttle_mode === 'shaper') { throttleBadge = E('span', { 'class': 'tc-c-speed tc-fw-bold', 'title': _('Shaper (tc/HTB queue)') }, '≈ ' + fmtRate(r._throttle_kbit)); }
		else if (r._throttle_mode === 'limiter') { throttleBadge = E('span', { 'class': 'tc-c-warn tc-fw-bold', 'title': _('Limiter (nft drop)') }, '⚡ ' + fmtRate(r._throttle_kbit)); }
		else { throttleBadge = E('span', { 'class': 'tc-c-faint' }, '—'); }
		cellMap._throttle_kbit = E('div', { 'class': 'td tc-center' }, throttleBadge);

		var dp = r._drop_packets || 0;
		var dropBadge = dp > 0 ? E('span', { 'class': 'tc-c-err tc-fw-bold', 'title': fmtBytes(r._drop_bytes||0)+' '+_('dropped') }, String(dp)) : E('span', { 'class': 'tc-c-faint' }, '—');
		cellMap._drop_packets = E('div', { 'class': 'td tc-center', 'data-drop-ip': r.ip }, dropBadge);

		var bl = r._backlog || 0;
		var backlogBadge = bl > 0 ? E('span', { 'class': 'tc-c-speed tc-fw-bold', 'title': _('Bytes queued in tc') }, fmtBytes(bl)) : E('span', { 'class': 'tc-c-faint' }, '—');
		cellMap._backlog = E('div', { 'class': 'td tc-center', 'data-backlog-ip': r.ip }, backlogBadge);

		var cells = visibleCols.map(function(c) { return cellMap[c.key]; });
		var row = E('div', { 'class': 'tr', 'title': _('Click to inspect') + ' ' + r.name }, cells);
		row.addEventListener('click', function() { addRecentDevice(r.ip, r.name); onSelect(r.ip, r.name); });
		return row;
	});

	return E('div', { 'class': 'table tc-table tc-table--rows-clickable' }, [titleRow].concat(tableRows));
}

function setStatus(el, type, msg) {
	var cls = {loading: '', ok: 'success', error: 'error', action: 'warning'};
	el.className = 'alert-message ' + (cls[type] || '');
	el.innerHTML = type === 'loading' ? '<span class="tc-spinner"></span>'+escHtml(msg) : escHtml(msg);
}

function updateUrlParams(opts) {
	var params = new URLSearchParams();
	if (opts.lastIp && opts.lastIp !== '__all__') params.set('ip', opts.lastIp);
	if (opts.refresh && opts.refresh > 0) params.set('refresh', String(opts.refresh));
	if (opts.pollInterval) params.set('poll', String(opts.pollInterval));
	if (opts.avgWindow && opts.avgWindow !== 15) params.set('avg', String(opts.avgWindow));
	if (opts.avgMethod && opts.avgMethod !== 'simple') params.set('method', opts.avgMethod);
	if (opts.extendedStats) params.set('extended', '1');
	if (opts.showOverview) params.set('overview', '1');
	if (opts.rdns) params.set('rdns', '1');
	var newUrl = window.location.pathname + (params.toString() ? '?' + params.toString() : '');
	// Selecting a different device is a real navigation step, so push it and let
	// back/forward (including mobile back gestures and mouse back buttons) move
	// between devices. Option tweaks — columns, filters, intervals — only rewrite
	// the current entry, so they don't flood the history stack.
	var curIp = new URLSearchParams(window.location.search).get('ip') || '__all__';
	var newIp = opts.lastIp || '__all__';
	var state = { ip: newIp };
	if (curIp !== newIp) history.pushState(state, '', newUrl);
	else history.replaceState(state, '', newUrl);
}

function applyUrlParams(opts) {
	var urlParams = new URLSearchParams(window.location.search);
	var paramIp = urlParams.get('ip');
	var paramRefresh = urlParams.get('refresh');
	var paramPoll = urlParams.get('poll');
	var paramAvg = urlParams.get('avg');
	var paramMethod = urlParams.get('method');
	var paramExtended = urlParams.get('extended');
	var paramOverview = urlParams.get('overview');
	var paramRdns = urlParams.get('rdns');

	if (paramIp) opts.lastIp = paramIp;
	if (paramRefresh) opts.refresh = parseInt(paramRefresh) || 0;
	if (paramPoll) opts.pollInterval = parseInt(paramPoll) || 0;
	if (paramAvg) opts.avgWindow = parseInt(paramAvg) || 15;
	if (paramMethod && (paramMethod === 'ewma' || paramMethod === 'simple')) opts.avgMethod = paramMethod;
	if (paramExtended === '1') opts.extendedStats = true;
	if (paramOverview === '1') opts.showOverview = true;
	if (paramRdns === '1') opts.rdns = true;
	return opts;
}

function buildExtendedStatsPanel(ip, shapeMap, dropMap, speedMap) {
	var sm = shapeMap[ip];
	var dm = dropMap[ip];
	var spd = speedMap[ip];

	var tooltips = {
		'Drops': _('packets dropped by queue overflow'),
		'Overlimits': _('rate exceeded events'),
		'ECN marks': _('congestion signals without drop'),
		'Flows': _('active concurrent connections in queue'),
		'Queue memory': _('bytes allocated by the queue discipline'),
		'Lended / Borrowed': _('own-rate vs parent-rate packets'),
		'Utilization': _('current speed as percentage of rate limit'),
		'Packets dropped': _('traffic discarded by nft policer'),
		'Bytes dropped': _('traffic discarded by nft policer'),
		'Drop ratio': _('percentage of total traffic that was dropped')
	};
	var rows = [];

	function addRow(label, value, color) {
		var tip = tooltips[label] || '';
		rows.push(E('div', { 'class': 'tr' }, [
			E('div', { 'class': 'td tc-c-muted', 'title': tip }, label),
			E('div', { 'class': 'td tc-right tc-mono tc-fw-bold', 'style': color ? 'color:' + color : '' }, value)
		]));
	}

	if (sm && sm.rate_kbit > 0) {
		if (sm.drops != null) addRow(_('Drops'), String(sm.drops), sm.drops > 0 ? 'var(--tc-err)' : null);
		if (sm.overlimits != null) addRow(_('Overlimits'), String(sm.overlimits), sm.overlimits > 0 ? 'var(--tc-warn)' : null);
		if (sm.ecn_mark != null) addRow(_('ECN marks'), String(sm.ecn_mark), sm.ecn_mark > 0 ? 'var(--tc-warn)' : null);
		if (sm.new_flows != null || sm.old_flows != null) {
			addRow(_('Flows'), (sm.new_flows || 0) + ' ' + _('new') + ' / ' + (sm.old_flows || 0) + ' ' + _('old'), null);
		}
		if (sm.memory_used != null) addRow(_('Queue memory'), fmtBytes(sm.memory_used), null);
		if (sm.lended != null || sm.borrowed != null) {
			addRow(_('Lended') + ' / ' + _('Borrowed'), (sm.lended || 0) + ' / ' + (sm.borrowed || 0), null);
		}
		if (spd && sm.rate_kbit > 0) {
			var currentBps = spd.current || 0;
			var rateBytes = (sm.rate_kbit * 1000) / 8;
			var util = rateBytes > 0 ? ((currentBps / rateBytes) * 100) : 0;
			var utilColor = util > 95 ? 'var(--tc-err)' : util > 70 ? 'var(--tc-warn)' : 'var(--tc-ok)';
			addRow(_('Utilization'), util.toFixed(1) + '%', utilColor);
		}
	} else if (dm && dm.rate_kbit > 0) {
		addRow(_('Packets dropped'), String(dm.packets || 0), (dm.packets || 0) > 0 ? 'var(--tc-err)' : null);
		addRow(_('Bytes dropped'), fmtBytes(dm.bytes || 0), (dm.bytes || 0) > 0 ? 'var(--tc-err)' : null);
		var dropBytes = dm.bytes || 0;
		var passBytes = dm.pass_bytes || 0;
		var totalBytes = dropBytes + passBytes;
		var dropRatio = totalBytes > 0 ? ((dropBytes / totalBytes) * 100) : 0;
		var drColor = dropRatio > 10 ? 'var(--tc-err)' : dropRatio > 2 ? 'var(--tc-warn)' : null;
		addRow(_('Drop ratio'), dropRatio.toFixed(1) + '%', drColor);
	}

	if (rows.length === 0) {
		return E('div', { 'class': 'tc-ext-panel', 'style': 'color:var(--tc-muted)' }, _('No extended stats available for this device.'));
	}

	return E('div', { 'class': 'tc-ext-panel' }, [
		E('div', { 'class': 'tc-ext-panel__title' }, _('Extended Statistics')),
		E('div', { 'class': 'table tc-table' }, rows)
	]);
}

function buildExtendedStatsLegend(shapeMap, dropMap) {
	var labelStyle = 'color:var(--tc-muted);font-size:12px';
	var valueStyle = 'font-family:monospace;font-weight:600;color:currentColor;font-size:13px';
	var totalDrops = 0, totalOverlimits = 0, totalEcn = 0, totalMemory = 0;
	var totalDropPkts = 0, totalDropBytes = 0;
	var shapedCount = 0, limitedCount = 0;

	Object.keys(shapeMap).forEach(function(ip) {
		var sm = shapeMap[ip];
		if (sm && sm.rate_kbit > 0) {
			shapedCount++;
			totalDrops += (sm.drops || 0);
			totalOverlimits += (sm.overlimits || 0);
			totalEcn += (sm.ecn_mark || 0);
			totalMemory += (sm.memory_used || 0);
		}
	});
	Object.keys(dropMap).forEach(function(ip) {
		var dm = dropMap[ip];
		if (dm && dm.rate_kbit > 0) {
			limitedCount++;
			totalDropPkts += (dm.packets || 0);
			totalDropBytes += (dm.bytes || 0);
		}
	});

	var rows = [];
	function addRow(label, value, color) {
		var vs = color ? valueStyle + ';color:' + color : valueStyle;
		rows.push(E('div', { 'class': 'tc-ext-row' }, [
			E('span', { 'style': labelStyle }, label),
			E('span', { 'style': vs }, value)
		]));
	}

	if (shapedCount > 0) {
		addRow(_('Shaped devices'), String(shapedCount), 'var(--tc-speed)');
		addRow(_('Total drops'), String(totalDrops), totalDrops > 0 ? 'var(--tc-err)' : null);
		addRow(_('Overlimits'), String(totalOverlimits), totalOverlimits > 0 ? 'var(--tc-warn)' : null);
		addRow(_('ECN marks'), String(totalEcn));
		addRow(_('Total queue memory'), fmtBytes(totalMemory));
	}
	if (limitedCount > 0) {
		addRow(_('Limited devices'), String(limitedCount), 'var(--tc-warn)');
		addRow(_('Total dropped'), totalDropPkts + ' ' + _('pkts') + ' / ' + fmtBytes(totalDropBytes), totalDropPkts > 0 ? 'var(--tc-err)' : null);
	}
	if (rows.length === 0) {
		rows.push(E('div', { 'style': 'padding:4px 0;color:var(--tc-muted)' }, _('No extended stats available.')));
	}

	return E('div', { 'class': 'tc-ext-panel tc-ext-panel--sticky' }, [
		E('div', { 'class': 'tc-ext-panel__title' }, _('Extended Statistics') + ' (' + _('all devices') + ')'),
		E('div', { 'class': 'tc-ext-col-flex' }, rows)
	]);
}

function guessDeviceType(d) {
	var n = (d.name || '').toLowerCase();
	if (/iphone|android|pixel|galaxy|huawei|xiaomi|redmi|poco|oneplus|realme|oppo|vivo|phone/.test(n)) return 'phone';
	if (/ipad|tab|kindle/.test(n)) return 'tablet';
	if (/tv|roku|firestick|chromecast|appletv|hisense|samsung.*tv|lg.*tv|sony.*tv/.test(n)) return 'tv';
	if (/macbook|laptop|notebook|thinkpad|lenovo/.test(n)) return 'laptop';
	if (/imac|desktop|pc|workstation|mini/.test(n)) return 'desktop';
	if (/echo|alexa|homepod|nest|speaker/.test(n)) return 'speaker';
	if (/cam|camera|doorbell|ring/.test(n)) return 'camera';
	if (/printer|brother|hp.*jet|epson/.test(n)) return 'printer';
	if (/switch|router|ap|eap|ubnt|unifi/.test(n)) return 'network';
	return 'device';
}

function deviceIcon(type, size) {
	var icons = {
		phone:   '📱', tablet:  '📱', tv:      '📺', laptop:  '💻',
		desktop: '🖥️', speaker: '🔊', camera:  '📷', printer: '🖨️',
		network: '🌐', device:  '⬡'
	};
	return E('span', {'style':'font-size:'+(size||18)+'px;line-height:1'}, icons[type] || icons.device);
}


function buildSearchSelect(devices, placeholder, onSelect) {
	var selectedValue = '__all__';
	var recentIps = [];
	var MAX_RECENT = 5;
	var wrapper = E('div', { 'class': 'tc-search-wrapper' });
	var input = E('input', {
		'type': 'text',
		'placeholder': placeholder,
		'autocomplete': 'off',
		'class': 'tc-search-input'
	});
	var clearBtn = E('span', { 'class': 'tc-search-clear tc-hidden' }, '×');
	var dropdown = E('div', { 'class': 'tc-search-dropdown tc-hidden' });
	wrapper.appendChild(input);
	wrapper.appendChild(clearBtn);
	wrapper.appendChild(dropdown);

	var highlightIdx = -1;

	function addToRecent(ip) {
		recentIps = recentIps.filter(function(r) { return r !== ip; });
		recentIps.unshift(ip);
		if (recentIps.length > MAX_RECENT) recentIps.length = MAX_RECENT;
	}

	function highlightMatch(text, q) {
		if (!q) return escHtml(text);
		var lower = text.toLowerCase();
		var idx = lower.indexOf(q);
		if (idx === -1) return escHtml(text);
		return escHtml(text.substring(0, idx)) + '<b>' + escHtml(text.substring(idx, idx + q.length)) + '</b>' + escHtml(text.substring(idx + q.length));
	}

	function deviceLabel(d) {
		return d.name + '  —  ' + d.ip + (d.mac ? '  (' + d.mac + ')' : '');
	}

	function mkItem(it, idx, q) {
		var item = E('div', { 'class': 'tc-dropdown-item', 'data-value': it.value });
		if (q && it.value !== '__all__') {
			item.innerHTML = highlightMatch(it.label, q);
		} else {
			item.textContent = it.label;
		}
		if (it.section) {
			item.className = 'tc-dropdown-item--section';
			return item;
		}
		if (it.value === '__all__') {
			item.className = 'tc-dropdown-item tc-dropdown-item--all';
		}
		item.addEventListener('mousedown', function(ev) {
			ev.preventDefault();
			selectItem(it.value, it.label);
		});
		item.addEventListener('mouseenter', function() {
			highlightIdx = idx;
			updateHighlight(dropdown);
		});
		return item;
	}

	function renderItems(filter) {
		while (dropdown.firstChild) dropdown.removeChild(dropdown.firstChild);
		var q = (filter || '').toLowerCase();
		var items = [];
		items.push({ value: '__all__', label: '— ' + _('All active devices') + ' —', searchText: '' });

		if (!q && recentIps.length > 0) {
			items.push({ section: true, label: _('Recent'), value: '_hdr_recent' });
			recentIps.forEach(function(ip) {
				var d = devices.filter(function(dev) { return dev.ip === ip; })[0];
				if (d) items.push({ value: d.ip, label: deviceLabel(d), searchText: '' });
			});
			items.push({ section: true, label: _('All'), value: '_hdr_all' });
		}

		devices.forEach(function(d) {
			var st = (d.name + ' ' + d.ip + ' ' + (d.mac||'')).toLowerCase();
			if (!q || st.indexOf(q) !== -1) {
				items.push({ value: d.ip, label: deviceLabel(d), searchText: st });
			}
		});

		highlightIdx = -1;
		var actionIdx = 0;
		items.forEach(function(it) {
			var item = mkItem(it, actionIdx, q);
			dropdown.appendChild(item);
			if (!it.section) actionIdx++;
		});
	}

	function updateHighlight(dd) {
		var actionIdx = 0;
		Array.prototype.forEach.call(dd.children, function(el) {
			if (el.getAttribute('data-value') && el.getAttribute('data-value').indexOf('_hdr_') === 0) return;
			el.style.background = actionIdx === highlightIdx ? 'var(--tc-hover)' : '';
			actionIdx++;
		});
	}

	function selectItem(value, label, silent) {
		selectedValue = value;
		if (value === '__all__') {
			input.value = '';
			clearBtn.classList.add('tc-hidden');
		} else {
			addToRecent(value);
			input.value = label.replace(/\s+\(.*\)$/, '');
			clearBtn.classList.remove('tc-hidden');
		}
		dropdown.classList.add('tc-hidden');
		if (!silent) onSelect(value);
	}

	input.addEventListener('focus', function() {
		this.style.cursor = 'text';
		renderItems(input.value);
		dropdown.classList.remove('tc-hidden');
	});
	input.addEventListener('blur', function() {
		this.style.cursor = 'pointer';
		setTimeout(function() { dropdown.classList.add('tc-hidden'); }, 150);
	});
	input.addEventListener('click', function() {
		renderItems(input.value);
		dropdown.classList.remove('tc-hidden');
	});
	input.addEventListener('input', function() {
		renderItems(input.value);
		dropdown.classList.remove('tc-hidden');
	});
	input.addEventListener('keydown', function(ev) {
		var actionItems = [];
		Array.prototype.forEach.call(dropdown.children, function(el) {
			var v = el.getAttribute('data-value');
			if (v && v.indexOf('_hdr_') !== 0) actionItems.push(el);
		});
		if (ev.key === 'ArrowDown') {
			ev.preventDefault();
			highlightIdx = Math.min(highlightIdx + 1, actionItems.length - 1);
			updateHighlight(dropdown);
		} else if (ev.key === 'ArrowUp') {
			ev.preventDefault();
			highlightIdx = Math.max(highlightIdx - 1, 0);
			updateHighlight(dropdown);
		} else if (ev.key === 'Enter') {
			ev.preventDefault();
			if (highlightIdx >= 0 && highlightIdx < actionItems.length) {
				var el = actionItems[highlightIdx];
				selectItem(el.getAttribute('data-value'), el.textContent);
			}
		} else if (ev.key === 'Escape') {
			dropdown.classList.add('tc-hidden');
			input.blur();
		}
	});
	clearBtn.addEventListener('click', function() {
		selectItem('__all__', '');
		input.focus();
	});

	return {
		el: wrapper,
		getValue: function() { return selectedValue; },
		setValue: function(val, label) { selectItem(val, label || val, true); },
		updateDevices: function(newDevices) { devices = newDevices; }
	};
}

return view.extend({
	_timer:        null,
	_bytesTimer:   null,
	_dropTimer:    null,
	_shapeTimer:   null,
	_bytesHistory: {},
	_speedHistory: {},
	_fullHistory:  {},
	_speedMap:     {},
	_totalsMap:    {},
	_dropMap:      {},
	_shapeMap:     {},
	_speedEwma:    {},
	_speedEwmaUp:  {},
	// Global overview state. _ifBytes holds the previous raw counter sample per
	// interface (the overview diffs two samples exactly as pollBytes does for
	// devices), _ifHistory the derived rates, _ifMeta the last role/label map.
	_ifBytes:      {},
	_ifHistory:    {},
	_ifMeta:       [],
	_deviceTimer:  null,
	_pollMode:     null,
	_onPopState:   null,
	_rdnsCache:    {},
	_sortCol:    'bytes',
	_sortDir:    'desc',
	_sumCol:     'name',
	_sumDir:     'asc',
	_hiddenCols: {},
	_queryGen:   0,

	load: function() {
		return fs.read('/tmp/dhcp.leases').catch(function() { return ''; });
	},

	render: function(leasesRaw) {
		var self = this;
		var opts = loadOpts();
		opts = applyUrlParams(opts);
		saveOpts(opts);
		var devices = [];
		(leasesRaw || '').split('\n').forEach(function(line) {
			var p = line.trim().split(/\s+/);
			if (p.length >= 4 && p[2] && p[3] && p[3] !== '*') {
				devices.push({ ip: p[2], name: p[3], mac: p[1] || '' });
			}
		});
		devices.sort(function(a, b) { return a.name.localeCompare(b.name); });

		var savedIp = opts.lastIp || '__all__';

		function onDeviceSelect(value) {
			var o = loadOpts(); o.lastIp = value; saveOpts(o); updateUrlParams(o);
			if (value !== '__all__') {
				var _nd = devices.filter(function(d) { return d.ip === value; })[0];
				addRecentDevice(value, _nd ? _nd.name : null);
			}
			renderRecentChips();
			updateModeUI();
			runQuery();
		}

		var searchSelect = buildSearchSelect(devices, _('Search device (name, IP, MAC)…'), onDeviceSelect);
		if (savedIp && savedIp !== '__all__') {
			var matchDev = devices.filter(function(d) { return d.ip === savedIp; })[0];
			searchSelect.setValue(savedIp, matchDev ? matchDev.name + '  —  ' + matchDev.ip : savedIp);
		}

		// Back/forward between devices. updateUrlParams() only pushes when the
		// device changes, and by the time runQuery() re-runs the URL already
		// matches, so this cannot push another entry and loop.
		self._onPopState = function() {
			var urlIp = new URLSearchParams(window.location.search).get('ip') || '__all__';
			if (searchSelect.getValue() === urlIp) return;
			var o = loadOpts(); o.lastIp = urlIp; saveOpts(o);
			var dev = (self._lastRows || []).filter(function(d) { return d.ip === urlIp; })[0];
			searchSelect.setValue(urlIp, urlIp === '__all__' ? '' : (dev ? dev.name + '  —  ' + dev.ip : urlIp));
			updateModeUI();
			runQuery();
		};
		window.addEventListener('popstate', self._onPopState);

		// Recent devices — functions defined at top level

		// Quick-access bar: [All devices] + recent device chips
		var quickBar = E('div', {'class':'tc-quick-bar'});

		var allBtn = E('span', {'class':'cbi-button cbi-button-action'}, ['📊 ', _('All devices')]);
		allBtn.addEventListener('click', function() {
			searchSelect.setValue('__all__', '');
			onDeviceSelect('__all__');
		});
		quickBar.appendChild(allBtn);

		var recentContainer = E('span', {'class':'tc-recent-container'});
		quickBar.appendChild(recentContainer);


		function renderRecentChips() {
			while (recentContainer.firstChild) recentContainer.removeChild(recentContainer.firstChild);
			var recent = getRecentDevices();
			var currentIp = searchSelect.getValue();

			// Update All button style
			// cbi-button cbi-button-action has the active (filled) look by default;
			// when a device is selected we switch to outline-only variant
			allBtn.className = currentIp === '__all__' ? 'cbi-button cbi-button-action' : 'cbi-button cbi-button-action cbi-button-action';

			recent.forEach(function(entry) {
				var ip = entry.ip || entry;
				var storedName = entry.name;
				var dev = devices.filter(function(d) { return d.ip === ip; })[0];
				var label = (dev && dev.name) || storedName || ip;
				var isActive = ip === currentIp;
				var chip = E('span', {
					'class': isActive ? 'tc-recent-chip tc-recent-chip--active' : 'tc-recent-chip',
					'title': ip + (dev && dev.mac ? ' (' + dev.mac + ')' : '')
				}, [
					deviceIcon(guessDeviceType(dev || {name:label}), 12),
					document.createTextNode(' ' + label)
				]);
				chip.addEventListener('click', function() {
					var lbl = label !== ip ? label + '  —  ' + ip : ip;
					searchSelect.setValue(ip, lbl);
					onDeviceSelect(ip);
				});
				var removeBtn = E('span', {'class':'tc-recent-remove'}, '×');
				removeBtn.addEventListener('click', function(ev) {
					ev.stopPropagation();
					var r = getRecentDevices().filter(function(x) { return (x.ip || x) !== ip; });
					saveRecentDevices(r);
					renderRecentChips();
				});
				chip.appendChild(removeBtn);
				chip.addEventListener('mouseenter', function() { removeBtn.style.opacity = '1'; });
				chip.addEventListener('mouseleave', function() { removeBtn.style.opacity = '0'; });
				recentContainer.appendChild(chip);
			});
		}
		renderRecentChips();

		function mkToggle(id, label, checked, onChange) {
			var cb = E('input', { 'type': 'checkbox', 'id': id, 'class': 'tc-toggle-input' });
			cb.checked = !!checked;
			cb.addEventListener('change', onChange);
			var track = E('label', { 'class': 'tc-toggle', 'for': id });
			return E('div', { 'class': 'tc-toggle-wrap' }, [
				cb, track,
				E('label', { 'for': id, 'style': 'cursor:pointer;font-size:12px;user-select:none;color:currentColor' }, label)
			]);
		}
		function mkLabel(t) {
			return E('span', { 'class': 'tc-inline-label' }, t);
		}

		function mkChipPick(options, currentValue, onChange) {
			var wrapper = E('span', {'style':'display:inline-flex;flex-wrap:wrap;gap:2px;align-items:center'});
			var selected = currentValue;
			var chips = [];
			options.forEach(function(opt) {
				var chip = E('span', {'class': opt.v === selected ? 'tc-chip tc-chip--active' : 'tc-chip'}, opt.l);
				chip.addEventListener('click', function() {
					selected = opt.v;
					chips.forEach(function(c) { c.className = c._v === selected ? 'tc-chip tc-chip--active' : 'tc-chip'; });
					onChange(opt.v);
				});
				chip._v = opt.v;
				chips.push(chip);
				wrapper.appendChild(chip);
			});
			return { el: wrapper, getValue: function() { return selected; }, setValue: function(v) { selected = v; chips.forEach(function(c) { c.className = c._v === v ? 'tc-chip tc-chip--active' : 'tc-chip'; }); } };
		}

		var showStats = mkToggle('tm-stats', _('Stats'), opts.showStats !== false, function() {
			var o = loadOpts(); o.showStats = this.checked; saveOpts(o); updateUrlParams(o);
			statsDiv.classList.toggle('tc-hidden', !this.checked);
		});
		var showConns = mkToggle('tm-conns', _('Connections'), opts.showConns !== false, function() {
			var o = loadOpts(); o.showConns = this.checked; saveOpts(o); updateUrlParams(o);
			connsDiv.classList.toggle('tc-hidden', !this.checked);
		});
		// Off by default: it costs one extra rpcd call per poll tick, so a user
		// who never opens it never pays for it. The gate is read fresh in
		// pollBytes() rather than cached, so unticking it stops the call on the
		// very next tick.
		var overviewCheck = mkToggle('tm-overview', _('Overview'), opts.showOverview, function() {
			var o = loadOpts(); o.showOverview = this.checked; saveOpts(o); updateUrlParams(o);
			overviewDiv.classList.toggle('tc-hidden', !this.checked || !isAllMode());
			if (this.checked) {
				pollIfaces();
			} else {
				// Drop the samples too — keeping them would show a stale graph
				// with a gap in it when the panel is re-opened much later.
				self._ifHistory = {};
				self._ifBytes = {};
				self._ifMeta = [];
				while (overviewDiv.firstChild) { overviewDiv.removeChild(overviewDiv.firstChild); }
			}
		});
		var rdnsCheck = mkToggle('tm-rdns', _('rDNS'), opts.rdns, function() {
			var o = loadOpts(); o.rdns = this.checked; saveOpts(o); updateUrlParams(o);
		});
		var extStatsCheck = mkToggle('tm-extended', _('Extended'), opts.extendedStats, function() {
			var o = loadOpts(); o.extendedStats = this.checked; saveOpts(o); updateUrlParams(o);
			extStatsDiv.classList.toggle('tc-hidden', !this.checked);
			if (this.checked) updateExtendedStats();
		});
		var activityCheck = mkToggle('tm-activity', _('Activity'), opts.showActivity, function() {
			var o = loadOpts(); o.showActivity = this.checked; saveOpts(o);
			activityDiv.classList.toggle('tc-hidden', !this.checked);
			if (this.checked) {
				if (!activityDiv._loaded) {
					activityDiv._loaded = true;
					loadActivityPanel(activityDiv);
				}
				setTimeout(function() { activityDiv.scrollIntoView({behavior:'smooth',block:'start'}); }, 100);
			}
		});

		var overviewDiv = E('div', { 'class': opts.showOverview ? '' : 'tc-hidden' });
		var extStatsDiv = E('div', { 'class': opts.extendedStats ? '' : 'tc-hidden' });
		var deviceGraphDiv = E('div', { 'class': 'tc-device-graph tc-hidden' });
		var activityDiv = E('div', { 'class': opts.showActivity ? '' : 'tc-hidden' });

		var refreshPick = mkChipPick([
			{v:'0',l:_('Off')},{v:'5',l:'5s'},{v:'10',l:'10s'},{v:'30',l:'30s'},{v:'60',l:'60s'}
		], String(opts.refresh||0), function(v) {
			var o = loadOpts(); o.refresh = parseInt(v); saveOpts(o); updateUrlParams(o); self._setupTimer();
		});

		var pollIntervalPick = mkChipPick([
			{v:'0',l:_('Off')},{v:'1',l:'1s'},{v:'2',l:'2s'},{v:'5',l:'5s'}
		], String(opts.pollInterval !== undefined ? opts.pollInterval : 2), function(v) {
			var o = loadOpts(); o.pollInterval = parseInt(v); saveOpts(o); updateUrlParams(o);
			self._restartBytesPoll();
		});

		var avgWindowPick = mkChipPick([
			{v:'5',l:'5s'},{v:'15',l:'15s'},{v:'30',l:'30s'},{v:'60',l:'60s'}
		], String(opts.avgWindow||15), function(v) {
			var o = loadOpts(); o.avgWindow = parseInt(v); saveOpts(o); updateUrlParams(o);
		});

		var avgMethodPick = mkChipPick([
			{v:'simple',l:_('Simple')},{v:'ewma',l:_('EWMA')}
		], opts.avgMethod||'simple', function(v) {
			var o = loadOpts(); o.avgMethod = v; saveOpts(o); updateUrlParams(o);
		});

		var protoPick = mkChipPick([
			{v:'all',l:_('All')},{v:'tcp',l:'TCP'},{v:'udp',l:'UDP'}
		], opts.proto||'all', function(v) {
			var o = loadOpts(); o.proto = v; saveOpts(o);
		});

		var groupPick = mkChipPick(
			GROUP_OPTS, opts.groupBy||'none', function(v) {
			var o = loadOpts(); o.groupBy = v; saveOpts(o); runQuery();
		});

		var statusDiv = E('div', { 'class': 'tc-hidden' });
		var statsDiv  = E('div', { 'style': 'margin:8px 0', 'class': opts.showStats === false ? 'tc-hidden' : '' });
		var connsDiv  = E('div', { 'class': opts.showConns === false ? 'tc-hidden' : '' });

		function _rdnsBatch(addrs, gen) {
			if (!addrs.length) return;
			callNetworkRrdnsLookup(addrs, 5000, addrs.length).then(function(replies) {
				if (gen !== self._queryGen) return;
				addrs.forEach(function(dst) {
					var host = (replies && replies[dst]) || null;
					self._rdnsCache[dst] = host;
					Array.prototype.forEach.call(
						connsDiv.querySelectorAll('[data-dst="'+dst+'"]'),
						function(cell) {
							if (host) { cell.textContent = host; cell.style.color = ''; }
							else { cell.innerHTML = '<span class="tc-c-faint">—</span>'; }
						}
					);
				});
			}).catch(function() {
				if (gen !== self._queryGen) return;
				addrs.forEach(function(dst) {
					self._rdnsCache[dst] = null;
					Array.prototype.forEach.call(
						connsDiv.querySelectorAll('[data-dst="'+dst+'"]'),
						function(cell) { cell.innerHTML = '<span class="tc-c-faint">—</span>'; }
					);
				});
			});
		}

		// Speed graph popup on spark cell hover
		var graphPopup = E('div', {'class':'tc-graph-popup tc-hidden'});
		document.body.appendChild(graphPopup);
		self._graphPopup = graphPopup;
		var graphPopupIp = null;
		var graphPopupTimer = null;

		function showGraphPopup(cell) {
			var ip = cell.getAttribute('data-spark-ip');
			if (!ip) return;
			graphPopupIp = ip;
			updateGraphPopup();
			var rect = cell.getBoundingClientRect();
			graphPopup.style.left = Math.max(8, rect.left - 160) + 'px';
			graphPopup.style.top = (rect.bottom + 6) + 'px';
			graphPopup.classList.remove('tc-hidden');
			if (!graphPopupTimer) {
				graphPopupTimer = setInterval(updateGraphPopup, 2000);
				self._graphPopupTimer = graphPopupTimer;
			}
		}
		function updateGraphPopup() {
			if (!graphPopupIp) return;
			var hist = self._fullHistory[graphPopupIp];
			var sm = self._shapeMap[graphPopupIp], dm = self._dropMap[graphPopupIp];
			var lk = (sm && sm.rate_kbit > 0) ? sm.rate_kbit : ((dm && dm.rate_kbit > 0) ? dm.rate_kbit : 0);
			// Fallback: get limit from summary rows if shapeMap not yet populated
			if (!lk && self._lastRows) {
				var row = self._lastRows.filter(function(r) { return r.ip === graphPopupIp; })[0];
				if (row) lk = (row.shape_kbit || 0) > 0 ? row.shape_kbit : (row.rate_limit_kbit || 0);
			}
			while (graphPopup.firstChild) graphPopup.removeChild(graphPopup.firstChild);
			var svg = renderFullGraph(hist, lk, 440, 200);
			if (svg) {
				graphPopup.appendChild(svg);
				if (lk > 0) {
					graphPopup.appendChild(E('div', {'class':'tc-graph-popup__note'},
						_('Note: speed is measured before shaper — bursts above limit are normal')));
				}
			} else {
				graphPopup.appendChild(E('span', {'class':'tc-graph-popup__empty'}, _('Not enough data yet')));
			}
		}
		function hideGraphPopup() {
			graphPopup.classList.add('tc-hidden');
			graphPopupIp = null;
			if (graphPopupTimer) { clearInterval(graphPopupTimer); graphPopupTimer = null; self._graphPopupTimer = null; }
		}

		graphPopup.addEventListener('mouseleave', hideGraphPopup);

		connsDiv.addEventListener('mouseenter', function(ev) {
			var cell = ev.target.closest ? ev.target.closest('[data-spark-ip]') : null;
			if (cell) showGraphPopup(cell);
		}, true);
		connsDiv.addEventListener('mouseleave', function(ev) {
			var cell = ev.target.closest ? ev.target.closest('[data-spark-ip]') : null;
			if (!cell) return;
			var related = ev.relatedTarget;
			if (related && (graphPopup === related || graphPopup.contains(related))) return;
			hideGraphPopup();
		}, true);

		var inetBtn = E('button', { 'class': 'cbi-button' }, '');
		var wifiBtn = E('button', { 'class': 'cbi-button tc-hidden' }, '');

		function updateInetBtn(blocked) {
			if (blocked) {
				inetBtn.textContent = _('Unblock Internet');
				inetBtn.className = 'cbi-button cbi-button-positive';
				inetBtn._action = 'unblock';
			} else {
				inetBtn.textContent = _('Block Internet');
				inetBtn.className = 'cbi-button cbi-button-negative';
				inetBtn._action = 'block';
			}
		}
		updateInetBtn(false);

		function updateWifiBtn(wifiBlocked, hasMac) {
			if (!hasMac) { wifiBtn.classList.add('tc-hidden'); return; }
			wifiBtn.classList.remove('tc-hidden');
			wifiBtn.disabled = false;
			if (wifiBlocked) {
				wifiBtn.textContent = _('Unblock WiFi');
				wifiBtn.className = 'cbi-button cbi-button-positive';
				wifiBtn._wifiAction = 'unblock';
			} else {
				wifiBtn.textContent = _('Block WiFi');
				wifiBtn.className = 'cbi-button cbi-button-negative';
				wifiBtn._wifiAction = 'block';
			}
		}

		// ── Speed Limit: modern chip UI ──────────────────────────────
		var _rateSelected = '0';
		// Set while the user has the custom field open. The per-device poll
		// re-syncs this panel from the device's current rate, and without this
		// it would close the field (and overwrite what is being typed) a few
		// seconds after it was opened.
		var _customPinned = false;
		var _modeSelected = 'shaper';

		var rateChipsRow = E('div', {'class':'tc-chips-row'});
		var rateChips = [];
		RATE_PRESETS.filter(function(p) { return p.v !== 'custom'; }).forEach(function(preset) {
			var chip = E('span', {'class': preset.v === '0' ? 'tc-chip tc-chip' : 'tc-chip'}, preset.l);
			chip._val = preset.v;
			chip.addEventListener('click', function() {
				_rateSelected = preset.v;
				updateRateChips();
				_customPinned = false;
				customRow.classList.add('tc-hidden');
				applyRate();
			});
			rateChips.push(chip);
			rateChipsRow.appendChild(chip);
		});

		function updateRateChips() {
			rateChips.forEach(function(c) {
				if (c._val === '0') {
					c.className = c._val === _rateSelected ? 'tc-chip tc-chip--active' : 'tc-chip tc-chip';
				} else {
					c.className = c._val === _rateSelected ? 'tc-chip tc-chip--active' : 'tc-chip';
				}
			});
			if (_rateSelected === 'custom') {
				rateChips.forEach(function(c) { c.className = c._val === '0' ? 'tc-chip tc-chip' : 'tc-chip'; });
			}
		}

		// Custom input row
		var customInput = E('input', { 'type':'number', 'min':'1', 'step':'1', 'placeholder': _('value'),
			'class': 'tc-custom-input' });
		var customUnitBtns = E('span', {'class':'tc-custom-unit-btns'});
		var _customUnit = 'mbit';
		var mbitBtn = E('span', {'style':'padding:4px 8px;font-size:11px;cursor:pointer;background:var(--tc-speed);color:#fff'}, 'Mbit/s');
		var kbitBtn = E('span', {'style':'padding:4px 8px;font-size:11px;cursor:pointer;background:var(--tc-bg);color:currentColor'}, 'kbit/s');
		function updateUnitBtns() {
			mbitBtn.style.background = _customUnit === 'mbit' ? 'var(--tc-speed)' : 'var(--tc-bg)';
			mbitBtn.style.color = _customUnit === 'mbit' ? '#fff' : 'currentColor';
			kbitBtn.style.background = _customUnit === 'kbit' ? 'var(--tc-speed)' : 'var(--tc-bg)';
			kbitBtn.style.color = _customUnit === 'kbit' ? '#fff' : 'currentColor';
		}
		mbitBtn.addEventListener('click', function() { _customUnit = 'mbit'; updateUnitBtns(); });
		kbitBtn.addEventListener('click', function() { _customUnit = 'kbit'; updateUnitBtns(); });
		customUnitBtns.appendChild(mbitBtn);
		customUnitBtns.appendChild(kbitBtn);

		var customApplyBtn = E('button', {
			'class':'cbi-button cbi-button-action'
		}, _('Apply'));
		customApplyBtn.addEventListener('click', function() {
			_rateSelected = 'custom';
			updateRateChips();
			_customPinned = false;
			applyRate();
		});

		var customToggleBtn = E('span', {'class': 'tc-chip', 'data-tip': _('Enter a custom speed value')}, '✎ ' + _('Custom'));
		customToggleBtn.addEventListener('click', function() {
			customRow.classList.toggle('tc-hidden');
			_customPinned = !customRow.classList.contains('tc-hidden');
			if (_customPinned) customInput.focus();
		});
		rateChipsRow.appendChild(customToggleBtn);

		var customRow = E('div', {'class':'tc-custom-row tc-hidden'}, [
			customInput, customUnitBtns, customApplyBtn
		]);

		// Mode: segmented toggle (Shaper default)
		var modeToggle = E('div', {'class':'tc-mode-toggle'});
		var shaperBtn = E('span', {
			'style':'padding:5px 12px;font-size:11px;font-weight:600;cursor:pointer;transition:all .15s',
			'data-tip': _('Queues excess traffic (smoother streaming, lower jitter)')
		}, _('Shaper'));
		var limiterBtn = E('span', {
			'style':'padding:5px 12px;font-size:11px;font-weight:500;cursor:pointer;transition:all .15s',
			'data-tip': _('Drops excess packets (instant enforcement, low overhead)')
		}, _('Limiter'));
		function updateModeToggle() {
			shaperBtn.style.background = _modeSelected === 'shaper' ? 'var(--tc-speed)' : 'var(--tc-bg)';
			shaperBtn.style.color = _modeSelected === 'shaper' ? '#fff' : 'currentColor';
			shaperBtn.style.fontWeight = _modeSelected === 'shaper' ? '600' : '500';
			limiterBtn.style.background = _modeSelected === 'limiter' ? 'var(--tc-warn)' : 'var(--tc-bg)';
			limiterBtn.style.color = _modeSelected === 'limiter' ? '#fff' : 'currentColor';
			limiterBtn.style.fontWeight = _modeSelected === 'limiter' ? '600' : '500';
		}
		shaperBtn.addEventListener('click', function() { _modeSelected = 'shaper'; updateModeToggle(); });
		limiterBtn.addEventListener('click', function() { _modeSelected = 'limiter'; updateModeToggle(); });
		modeToggle.appendChild(shaperBtn);
		modeToggle.appendChild(limiterBtn);
		updateModeToggle();

		// ── Network-wide / subnet target ──────────────────────────────
		// With "All active devices" selected there is no single IP to act on,
		// so the target is typed instead: "all" or a CIDR. Only the limiter
		// supports blocks — tc classids are derived from a single address, so
		// the shaper cannot express a subnet.
		var _scopeSelected = 'each';
		var scopeInput = E('input', {
			'type': 'text',
			'class': 'tc-custom-input',
			'value': 'all',
			'placeholder': '10.0.20.0/24',
			'style': 'width:150px',
			'data-tip': _('"all" for every device, or a CIDR such as 10.0.20.0/24')
		});

		var scopeChips = E('div', {'class':'tc-chips-row', 'style':'gap:4px'});
		function updateScopeChips() {
			Array.prototype.forEach.call(scopeChips.children, function(c) {
				c.className = c._v === _scopeSelected ? 'tc-chip tc-chip--active' : 'tc-chip';
			});
		}
		[
			{ v: 'each',   l: _('per device'), tip: _('Every address gets its own bucket — 5 Mbit each') },
			{ v: 'shared', l: _('shared'),     tip: _('One bucket for the whole target — 5 Mbit total') }
		].forEach(function(o) {
			var c = E('span', {'class':'tc-chip', 'data-tip': o.tip}, o.l);
			c._v = o.v;
			c.addEventListener('click', function() { _scopeSelected = o.v; updateScopeChips(); });
			scopeChips.appendChild(c);
		});
		updateScopeChips();

		var scopeRow = E('div', {'class':'tc-custom-row tc-hidden', 'style':'align-items:center;gap:8px'}, [
			E('span', {'class':'tc-inline-label'}, _('Target:')),
			scopeInput,
			scopeChips
		]);

		var rateLimitRow = E('div', {
			'class': 'tc-rate-panel tc-hidden'
		}, [
			E('div', {'class':'tc-rate-panel__header'}, [
				E('span', {'class':'tc-rate-panel__title'}, _('Speed Limit')),
				modeToggle
			]),
			scopeRow,
			rateChipsRow,
			customRow
		]);

		// Compat shims for existing code that uses ratePick/modePick interface
		var ratePick = {
			getValue: function() { return _rateSelected; },
			setValue: function(v) { _rateSelected = v; updateRateChips(); },
			el: rateChipsRow
		};
		var modePick = {
			getValue: function() { return _modeSelected; },
			setValue: function(v) { _modeSelected = v; updateModeToggle(); },
			el: modeToggle
		};
		function getRateKbit() {
			if (_rateSelected !== 'custom') return _rateSelected;
			var n = parseFloat(customInput.value);
			if (!n || n <= 0) return '0';
			if (_customUnit === 'mbit') return String(Math.round(n * 1000));
			return String(Math.round(n));
		}

		function applyRate() {
			var all  = isAllMode();
			// In all-devices mode the target is the typed scope ("all" or a
			// CIDR); otherwise it's the selected device's address.
			var ip   = all ? (scopeInput.value || 'all').trim() : searchSelect.getValue();
			var name = '';
			var kbit = getRateKbit();
			// A block target has no single tc classid, so the shaper can't
			// express it — force the limiter rather than silently doing nothing.
			var mode = all ? 'limiter' : _modeSelected;
			var scope = all ? _scopeSelected : '';

			if (all && kbit !== '0') {
				setStatus(statusDiv, 'loading',
					_('Limiting') + ' ' + ip + ' → ' + fmtRate(parseInt(kbit)) + ' (' + scope + ')…');
				callRatelimit(ip, parseInt(kbit), name, scope).then(function(res) {
					setStatus(statusDiv, (res && res.ok) ? 'action' : 'error', (res && res.msg) || '?');
					runQuery();
				}).catch(function(e) { setStatus(statusDiv, 'error', '✗ '+e.message); });
				return;
			}
			if (all) {
				setStatus(statusDiv, 'loading', _('Removing throttle…'));
				callRatelimit(ip, 0, name, scope).then(function(res) {
					setStatus(statusDiv, 'ok', (res && res.msg) || _('Throttle removed'));
					runQuery();
				}).catch(function(e) { setStatus(statusDiv, 'error', '✗ '+e.message); });
				return;
			}

			if (kbit === '0') {
				setStatus(statusDiv, 'loading', _('Removing throttle…'));
				Promise.all([
					callRatelimit(ip, 0, name),
					callShapeRemove(ip, name)
				]).then(function(results) {
					var res = results[0] || {};
					setStatus(statusDiv, 'ok', res.msg || _('Throttle removed'));
					runQuery();
				}).catch(function(e) { setStatus(statusDiv, 'error', '✗ '+e.message); });
			} else if (mode === 'shaper') {
				setStatus(statusDiv, 'loading', _('Shaping') + ' → ' + fmtRate(parseInt(kbit)) + '…');
				callRatelimit(ip, 0, name)
					.then(function() { return callShapeAdd(ip, parseInt(kbit), name); })
					.then(function(res) {
						setStatus(statusDiv, (res && res.ok) ? 'action' : 'error', (res && res.msg) || '?');
						runQuery();
					})
					.catch(function(e) { setStatus(statusDiv, 'error', '✗ '+e.message); });
			} else {
				setStatus(statusDiv, 'loading', _('Limiting') + ' → ' + fmtRate(parseInt(kbit)) + '…');
				callShapeRemove(ip, name)
					.then(function() { return callRatelimit(ip, parseInt(kbit), name); })
					.then(function(res) {
						setStatus(statusDiv, (res && res.ok) ? 'action' : 'error', (res && res.msg) || '?');
						runQuery();
					})
					.catch(function(e) { setStatus(statusDiv, 'error', '✗ '+e.message); });
			}
		}

		var actionRow = E('div', { 'class': 'tc-action-row' },
			[inetBtn, wifiBtn]);

		function isAllMode() { return searchSelect.getValue() === '__all__'; }

		function updateModeUI() {
			var all = isAllMode();
			actionRow.classList.toggle('tc-hidden', all);
			// The throttle panel used to be hidden in all-devices mode, which
			// left no way to limit a subnet or the whole network at all.
			rateLimitRow.classList.remove('tc-hidden');
			scopeRow.classList.toggle('tc-hidden', !all);
			modeToggle.classList.toggle('tc-hidden', all);
			rdnsCheck.classList.toggle('tc-hidden', all);
			extStatsCheck.classList.toggle('tc-hidden', all);
			// The overview is a whole-router view, so it belongs to the
			// all-devices mode only; its toggle goes with it rather than
			// sitting there doing nothing while a device is selected.
			overviewCheck.classList.toggle('tc-hidden', !all);
			overviewDiv.classList.toggle('tc-hidden', !all || !loadOpts().showOverview);
			extStatsDiv.classList.toggle('tc-hidden', all || !loadOpts().extendedStats);
			if (typeof updateTableSectionMode === 'function') updateTableSectionMode();
		}

		function updateSpeedCells() {
			var globalMax = 0;
			Object.keys(self._speedHistory).forEach(function(ip) {
				var hist = self._speedHistory[ip];
				if (hist) hist.forEach(function(h) { if (h.speed > globalMax) globalMax = h.speed; });
			});

			Object.keys(self._speedMap).forEach(function(ip) {
				var s = self._speedMap[ip];
				var cell = connsDiv.querySelector('[data-speed-ip="'+ip+'"]');
				if (!cell) return;
				// renderSpeedCell keeps the layout classes ('td tc-right tc-mono')
				// rather than assigning className outright, which is what used to
				// break this cell's alignment.
				renderSpeedCell(cell, s);
				cell.title = _('Avg')+': '+fmtSpeed(s.avg)+' / '+_('Max')+': '+fmtSpeed(s.max);

				var upCell = connsDiv.querySelector('[data-speed-up-ip="'+ip+'"]');
				if (upCell) {
					var up = s.current_up || 0;
					upCell.className = 'td tc-right tc-mono ' +
						(up > 1024 ? 'tc-speed-active' : 'tc-speed-idle');
					upCell.textContent = fmtSpeed(up);
					upCell.title = _('Avg')+': '+fmtSpeed(s.avg_up||0)+' / '+_('Max')+': '+fmtSpeed(s.max_up||0);
				}

				var sparkCell = connsDiv.querySelector('[data-spark-ip="'+ip+'"]');
				if (sparkCell) {
					while (sparkCell.firstChild) sparkCell.removeChild(sparkCell.firstChild);
					var sm = self._shapeMap[ip], dm = self._dropMap[ip];
					var lk = (sm && sm.rate_kbit > 0) ? sm.rate_kbit : ((dm && dm.rate_kbit > 0) ? dm.rate_kbit : 0);
					var svg = renderSparkline(self._speedHistory[ip], globalMax, 60, 20, lk);
					if (svg) sparkCell.appendChild(svg);
				}
			});

		}

		function pollDrops() {
			if (document.hidden) return;
			callRatelimitStats().then(function(data) {
				if (!Array.isArray(data)) return;
				data.forEach(function(d) {
					self._dropMap[d.ip] = { packets: d.packets, bytes: d.bytes, rate_kbit: d.rate_kbit, pass_packets: d.pass_packets, pass_bytes: d.pass_bytes };
				});
				if (isAllMode()) {
					Object.keys(self._dropMap).forEach(function(ip) {
						var dp = self._dropMap[ip].packets || 0;
						var db = self._dropMap[ip].bytes   || 0;
						var cell = connsDiv.querySelector('[data-drop-ip="'+ip+'"]');
						if (!cell) return;
						while (cell.firstChild) cell.removeChild(cell.firstChild);
						if (dp > 0) {
							cell.appendChild(E('span', {
								'class': 'tc-c-err tc-fw-bold',
								'title': fmtBytes(db) + ' ' + _('dropped')
							}, String(dp)));
						} else {
							cell.appendChild(E('span', { 'class': 'tc-c-faint' }, '—'));
						}
					});
				}
				updateExtendedStats();
			}).catch(function(){});
		}

		function pollShapeStats() {
			if (document.hidden) return;
			callShapeStats().then(function(data) {
				if (!Array.isArray(data)) return;
				data.forEach(function(d) {
					self._shapeMap[d.ip] = {
						packets: d.packets, bytes: d.bytes, backlog: d.backlog, rate_kbit: d.rate_kbit,
						drops: d.drops, overlimits: d.overlimits, requeues: d.requeues,
						lended: d.lended, borrowed: d.borrowed, ecn_mark: d.ecn_mark,
						new_flows: d.new_flows, old_flows: d.old_flows,
						target_us: d.target_us, memory_used: d.memory_used
					};
				});
				if (isAllMode()) {
					Object.keys(self._shapeMap).forEach(function(ip) {
						var bl = self._shapeMap[ip].backlog || 0;
						var cell = connsDiv.querySelector('[data-backlog-ip="'+ip+'"]');
						if (!cell) return;
						while (cell.firstChild) cell.removeChild(cell.firstChild);
						if (bl > 0) {
							cell.appendChild(E('span', { 'class': 'tc-c-speed tc-fw-bold', 'title': _('Bytes queued in tc') }, fmtBytes(bl)));
						} else {
							cell.appendChild(E('span', { 'class': 'tc-c-faint' }, '—'));
						}
					});
				}
				updateExtendedStats();
			}).catch(function(){});
		}

		// Global overview. Deliberately has NO timer of its own: it is driven
		// from pollBytes(), so it inherits the Poll chip, the document.hidden
		// check and the start/stop lifecycle for free. A private setInterval
		// here would ignore the Poll setting and would be one more thing to
		// remember to clear on teardown — the bug class this repo has shipped
		// before with the speed-graph popup.
		function pollIfaces() {
			if (!loadOpts().showOverview || !isAllMode()) return;
			callIfaces().then(function(list) {
				if (!Array.isArray(list)) return;
				var now = Date.now();
				self._ifMeta = list;

				var seen = {};
				list.forEach(function(itf) {
					seen[itf.dev] = true;
					var prev = self._ifBytes[itf.dev];
					if (prev) {
						var dt = (now - prev.time) / 1000;
						if (dt >= 0.5) {
							var dRx = itf.rx_bytes - prev.rx;
							var dTx = itf.tx_bytes - prev.tx;
							// An interface that went down and came back up
							// restarts its counters at zero; a negative delta is
							// that, not traffic.
							if (dRx < 0) dRx = 0;
							if (dTx < 0) dTx = 0;
							if (!self._ifHistory[itf.dev]) self._ifHistory[itf.dev] = [];
							var h = self._ifHistory[itf.dev];
							h.push({ speed: dRx / dt, up: dTx / dt, time: now });
							if (h.length > IFACE_HISTORY_MAX) h.splice(0, h.length - IFACE_HISTORY_MAX);
						}
					}
					self._ifBytes[itf.dev] = { rx: itf.rx_bytes, tx: itf.tx_bytes, time: now };
				});
				// Forget interfaces that disappeared (a tunnel torn down, a
				// modem unplugged) so their history cannot grow unbounded
				// across a long session.
				Object.keys(self._ifHistory).forEach(function(dev) {
					if (!seen[dev]) { delete self._ifHistory[dev]; delete self._ifBytes[dev]; }
				});

				renderOverview();
			}).catch(function(){});
		}

		function renderOverview() {
			var o = loadOpts();
			if (!o.showOverview || !isAllMode()) return;
			var nameByIp = {};
			(self._lastRows || []).forEach(function(r) { nameByIp[r.ip] = r.name; });
			var panel = buildOverviewPanel(
				self._ifMeta, self._ifHistory, self._speedMap, nameByIp,
				!!o.ovShowOther,
				function(next) {
					var oo = loadOpts(); oo.ovShowOther = next; saveOpts(oo);
					renderOverview();
				},
				(o.pollInterval !== undefined ? o.pollInterval : 2) <= 0
			);
			while (overviewDiv.firstChild) overviewDiv.removeChild(overviewDiv.firstChild);
			overviewDiv.appendChild(panel);
		}

		function pollBytes() {
			if (document.hidden) return;
			// Runs in BOTH modes: byte counters are per-device, and the device
			// view's speed graph is fed from this history. Only the summary-table
			// repaint below is all-devices-specific.
			callBytes().then(function(data) {
				if (!Array.isArray(data)) return;
				var now = Date.now();
				var o = loadOpts();
				var pollInterval = o.pollInterval || 2;
				var avgWindow = o.avgWindow || 15;
				var avgMethod = o.avgMethod || 'simple';
				var maxSamples = Math.max(2, Math.round(avgWindow / (pollInterval || 2)));

				var activeIps = {};
				data.forEach(function(d) { activeIps[d.ip] = true; });
				// The router keeps a device's total while it is idle, but the
				// table only lists devices with live flows, so the browser-side
				// copy is dropped with the rest of that device's state.
				Object.keys(self._totalsMap).forEach(function(ip) {
					if (!activeIps[ip]) {
						delete self._totalsMap[ip];
					}
				});
				Object.keys(self._speedHistory).forEach(function(ip) {
					if (!activeIps[ip]) {
						delete self._speedHistory[ip];
						delete self._fullHistory[ip];
						delete self._speedMap[ip];
						delete self._speedEwma[ip];
						delete self._speedEwmaUp[ip];
						delete self._bytesHistory[ip];
					}
				});

				data.forEach(function(d) {
					var prev = self._bytesHistory[d.ip];
					if (prev) {
						var dt = (now - prev.time) / 1000;
						if (dt < 0.5) return;
						var dIn = d.bytes_in - prev.bytes_in;
						var dOut = d.bytes_out - prev.bytes_out;
						// Counter reset or wrap — discard this sample
						if (dIn < 0) dIn = 0;
						if (dOut < 0) dOut = 0;
						var speed = dIn / dt;
						var speedUp = dOut / dt;
						// Spike filter: cap at link speed (1 Gbit/s = 125 MB/s)
						var MAX_BPS = 125000000;
						if (speed > MAX_BPS) speed = 0;
						if (speedUp > MAX_BPS) speedUp = 0;

						if (!self._fullHistory[d.ip]) self._fullHistory[d.ip] = [];
						var fh = self._fullHistory[d.ip];
						fh.push({speed: speed, up: speedUp, time: now});
						if (fh.length > FULL_HISTORY_MAX) fh.splice(0, fh.length - FULL_HISTORY_MAX);

						if (avgMethod === 'ewma') {
							var alpha = 2 / (maxSamples + 1);
							var prevEwma = self._speedEwma[d.ip] || 0;
							var ewma = alpha * speed + (1 - alpha) * prevEwma;
							self._speedEwma[d.ip] = ewma;
							var prevEwmaUp = self._speedEwmaUp[d.ip] || 0;
							var ewmaUp = alpha * speedUp + (1 - alpha) * prevEwmaUp;
							self._speedEwmaUp[d.ip] = ewmaUp;
							if (!self._speedHistory[d.ip]) self._speedHistory[d.ip] = [];
							self._speedHistory[d.ip].push({speed: speed, up: speedUp, time: now});
							if (self._speedHistory[d.ip].length > maxSamples) self._speedHistory[d.ip].shift();
							var max = 0, maxUp = 0;
							self._speedHistory[d.ip].forEach(function(h){
								if (h.speed > max) max = h.speed;
								if ((h.up || 0) > maxUp) maxUp = h.up;
							});
							self._speedMap[d.ip] = {
								current: speed,
								up: speedUp,
								avg: ewma,
								max: max,
								current_up: speedUp,
								avg_up: ewmaUp,
								max_up: maxUp
							};
						} else {
							if (!self._speedHistory[d.ip]) self._speedHistory[d.ip] = [];
							self._speedHistory[d.ip].push({speed: speed, up: speedUp, time: now});
							if (self._speedHistory[d.ip].length > maxSamples) self._speedHistory[d.ip].shift();
							var hist = self._speedHistory[d.ip];
							var sum = 0, sMax = 0, sumUp = 0, sMaxUp = 0;
							hist.forEach(function(h){
								sum += h.speed; if (h.speed > sMax) sMax = h.speed;
								sumUp += (h.up || 0); if ((h.up || 0) > sMaxUp) sMaxUp = h.up;
							});
							self._speedMap[d.ip] = {
								current: speed,
								up: speedUp,
								avg: sum / hist.length,
								max: sMax,
								current_up: speedUp,
								avg_up: sumUp / hist.length,
								max_up: sMaxUp
							};
						}
					}
					self._bytesHistory[d.ip] = {
						bytes_in: d.bytes_in,
						bytes_out: d.bytes_out,
						time: now
					};

					// Lifetime totals, accumulated by trafficctl-totals.sh.
					// The proto fields arrive as -1 when the router cannot
					// measure them (nft counters under flow offload), and that
					// -1 is carried through untouched so the cell can say so
					// instead of printing a zero nobody can explain.
					var tcpT = (d.bytes_tcp_total == null) ? -1 : Number(d.bytes_tcp_total);
					var udpT = (d.bytes_udp_total == null) ? -1 : Number(d.bytes_udp_total);
					var liveTcp = (d.bytes_tcp == null) ? -1 : Number(d.bytes_tcp);
					var liveUdp = (d.bytes_udp == null) ? -1 : Number(d.bytes_udp);
					self._totalsMap[d.ip] = {
						total: (Number(d.bytes_in_total) || 0) + (Number(d.bytes_out_total) || 0),
						tcp: tcpT,
						udp: udpT,
						liveTotal: (Number(d.bytes_in) || 0) + (Number(d.bytes_out) || 0),
						liveTcp: liveTcp,
						liveUdp: liveUdp,
						since: Number(d.total_since) || 0,
						degraded: (d.degraded === true)
					};
				});
				if (isAllMode()) {
					if (self._sumCol === '_speed') {
						runAll();
					} else {
						updateSpeedCells();
						updateTotalCells();
					}
				}
				updateDeviceGraph();
				// Same tick as the device counters, so the overview's "Top
				// talkers" and the summary table can never disagree about who
				// is busy.
				pollIfaces();
			}).catch(function(){});
		}

		function updateDeviceGraph() {
			var ip = searchSelect.getValue();
			if (!ip || ip === '__all__') {
				deviceGraphDiv.classList.add('tc-hidden');
				return;
			}
			var hist = self._fullHistory[ip];
			if (!hist || hist.length < 2) return;
			var sm = self._shapeMap[ip], dm = self._dropMap[ip];
			var lk = (sm && sm.rate_kbit > 0) ? sm.rate_kbit : ((dm && dm.rate_kbit > 0) ? dm.rate_kbit : 0);
			var w = deviceGraphDiv.offsetWidth || 560;
			var svg = renderFullGraph(hist, lk, w, 160);
			if (!svg) return;
			while (deviceGraphDiv.firstChild) deviceGraphDiv.removeChild(deviceGraphDiv.firstChild);
			deviceGraphDiv.appendChild(svg);
			deviceGraphDiv.classList.remove('tc-hidden');
		}

		function runSingle(ip) {
			var o = loadOpts();
			var proto = (o.proto && o.proto !== 'all') ? o.proto : '';
			self._queryGen++;
			var gen = self._queryGen;

			setStatus(statusDiv, 'loading', _('Running…'));

			callDevice(ip, proto).then(function(data) {
				if (!data || data.error) {
					setStatus(statusDiv, 'error', (data && data.error) || _('Unknown error'));
					return;
				}

				if (opts.showStats !== false) {
					var protoTcp = Number(data.protocols.tcp) || 0;
					var protoUdp = Number(data.protocols.udp) || 0;
					var protoOther = Number(data.protocols.other) || 0;
					var connCount = protoTcp + protoUdp + protoOther;
					var parts = [_('Connections') + ': <b>'+connCount+'</b>'];
					if (connCount > 0) {
						parts.push('TCP: <b>'+protoTcp+'</b>');
						parts.push('UDP: <b>'+protoUdp+'</b>');
						if (data.tcp_states) {
							Object.keys(data.tcp_states).forEach(function(s) {
								parts.push(escHtml(s)+': <b>'+(Number(data.tcp_states[s]) || 0)+'</b>');
							});
						}
					}
					if ((data.shape_kbit || 0) > 0) {
						parts.push(_('Shaped') + ': <b style="color:var(--tc-speed)">🌊 '+fmtRate(data.shape_kbit)+'</b>');
						var sm = self._shapeMap[data.ip || searchSelect.getValue()] || {};
						if ((sm.backlog||0) > 0) parts.push(_('Queued') + ': <b style="color:var(--tc-speed)">'+fmtBytes(sm.backlog)+'</b>');
						if ((sm.bytes||0) > 0) parts.push(_('Passed') + ': <b>'+fmtBytes(sm.bytes)+'</b>');
					} else if ((data.rate_limit_kbit || 0) > 0) {
						parts.push(_('Speed limit') + ': <b style="color:var(--tc-warn)">⚡ '+fmtRate(data.rate_limit_kbit)+'</b>');
						var dm = self._dropMap[data.ip || searchSelect.getValue()] || {};
						if ((dm.packets||0) > 0) {
							parts.push(_('Dropped') + ': <b style="color:var(--tc-err)">🚫 '+(Number(dm.packets) || 0)+' pkts / '+fmtBytes(dm.bytes||0)+'</b>');
						}
					}
					var wifiPart = data.wifi_blocked
						? ' &nbsp;|&nbsp; <b style="color:var(--tc-warn)">📵 ' + _('WiFi blocked') + '</b> ('+escHtml(data.mac||'') + ')'
						: (data.mac ? ' &nbsp;|&nbsp; <span style="color:var(--tc-faint)">MAC: '+escHtml(data.mac)+'</span>' : '');
					statsDiv.className = 'alert-message ' + (data.blocked ? 'error' : 'info');
					statsDiv.innerHTML = (data.blocked
						? '<b>⛔ ' + _('BLOCKED') + '</b> — '+(Number(data.block_packets) || 0)+' pkts, '+fmtBytes(Number(data.block_bytes) || 0)+' ' + _('dropped') + ' &nbsp;|&nbsp; '
						: '') + parts.join(' &nbsp;|&nbsp; ') + wifiPart;
				}

				updateInetBtn(data.blocked);
				updateWifiBtn(data.wifi_blocked, !!data.mac);

				var curShapeRate = data.shape_kbit || 0;
				var curLimitRate = data.rate_limit_kbit || 0;
				var curRate = curShapeRate > 0 ? curShapeRate : curLimitRate;
				modePick.setValue(curShapeRate > 0 ? 'shaper' : (curLimitRate > 0 ? 'limiter' : 'shaper'));

				var curRateStr = String(curRate);
				var matched = RATE_PRESETS.some(function(p) { return p.v === curRateStr; });
				// Leave the panel alone entirely while the custom field is
				// open — this runs on every poll.
				if (_customPinned) {
					/* user is editing */
				} else if (matched) {
					ratePick.setValue(curRateStr);
					customRow.classList.add('tc-hidden');
				} else if (curRate > 0) {
					ratePick.setValue('custom');
					customInput.value = curRate;
					_customUnit = 'kbit'; updateUnitBtns();
					customRow.classList.remove('tc-hidden');
				} else {
					ratePick.setValue('0');
					customRow.classList.add('tc-hidden');
				}

				while (connsDiv.firstChild) connsDiv.removeChild(connsDiv.firstChild);
				if (!data.connections || data.connections.length === 0) {
					connsDiv.appendChild(E('p', {'style':'color:var(--tc-muted);padding:12px 0'}, _('No active connections.')));
				} else {
					var groupBy = o.groupBy || 'none';
					var tbl;
					if (groupBy !== 'none') {
						var groups = groupConnections(data.connections, groupBy);
						tbl = buildGroupedTable(groups, self._sortCol === 'bytes' || self._sortCol === 'count' ? self._sortCol : 'bytes', self._sortDir);
						Array.prototype.forEach.call(tbl.querySelectorAll('.th'), function(th) {
							th.addEventListener('click', function() {
								var col = th.getAttribute('data-col');
								if (self._sortCol === col) {
									self._sortDir = self._sortDir === 'asc' ? 'desc' : 'asc';
								} else {
									self._sortCol = col;
									self._sortDir = th.getAttribute('data-num') === '1' ? 'desc' : 'asc';
								}
								runQuery();
							});
						});
						connsDiv.appendChild(E('div',{'style':'overflow-x:auto'},[tbl]));
						connsDiv.appendChild(E('p',{'style':'color:var(--tc-faint);font-size:11px;margin-top:6px'},
							groups.length + ' ' + _('groups from') + ' ' + data.connections.length + ' ' + _('connections') + '. ' + _('Click header to sort.')));
					} else {
						tbl = buildTable(data.connections, self._sortCol, self._sortDir, o.rdns, self._connHiddenCols);
						Array.prototype.forEach.call(tbl.querySelectorAll('.th'), function(th) {
							th.addEventListener('click', function() {
								var col = th.getAttribute('data-col');
								if (self._sortCol === col) {
									self._sortDir = self._sortDir === 'asc' ? 'desc' : 'asc';
								} else {
									self._sortCol = col;
									self._sortDir = th.getAttribute('data-num') === '1' ? 'desc' : 'asc';
								}
								runQuery();
							});
						});
						connsDiv.appendChild(E('div',{'style':'overflow-x:auto'},[tbl]));
						connsDiv.appendChild(E('p',{'style':'color:var(--tc-faint);font-size:11px;margin-top:6px'},
							data.connections.length + ' ' + _('connections') + '. ' + _('Click header to sort.')));

						if (o.rdns) {
							var seen = {}, uncached = [];
							data.connections.forEach(function(c) {
								var dst = c.dst || '';
								if (!dst || seen[dst] || PRIVATE_RE.test(dst)) return;
								seen[dst] = true;
								if (self._rdnsCache[dst] !== undefined) {
									var cached = self._rdnsCache[dst];
									Array.prototype.forEach.call(
										connsDiv.querySelectorAll('[data-dst="'+dst+'"]'),
										function(cell) {
											if (cached) { cell.textContent = cached; cell.style.color = ''; }
											else { cell.innerHTML = '<span class="tc-c-faint">—</span>'; }
										}
									);
								} else {
									uncached.push(dst);
								}
							});
							_rdnsBatch(uncached, gen);
						}
					}
				}
				setStatus(statusDiv, 'ok', '✓ ' + _('Done'));
			})
			.catch(function(e) { setStatus(statusDiv, 'error', '✗ '+e.message); });
		}

		self._tableFilter = null;
		self._lastRows = [];

		function applyTableFilter(rows) {
			var f = self._tableFilter;
			if (!f) return rows;
			if (f === 'blocked') return rows.filter(function(r) { return r.blocked; });
			if (f === 'wifi_blocked') return rows.filter(function(r) { return r.wifi_blocked; });
			if (f === 'limited') return rows.filter(function(r) { return (r.rate_limit_kbit||0) > 0; });
			if (f === 'shaped') return rows.filter(function(r) { return (r.shape_kbit||0) > 0; });
			return rows;
		}

		function setTableFilter(f) {
			self._tableFilter = (self._tableFilter === f) ? null : f;
			renderSummary(self._lastRows);
		}

		// The summary's own total/tcp/udp fields are live conntrack sums, which
		// collapse when flows expire (#26). Replace them with the lifetime
		// totals the byte poll carries, keeping the live values for the cell
		// tooltips. Done on the row objects rather than inside the table
		// builder so that sorting by Bytes sorts by the number on screen.
		function mergeTotals(rows) {
			rows.forEach(function(r) {
				var t = self._totalsMap[r.ip];
				r._total_pending = !t;
				if (!t) {
					r.total = -1; r.tcp = -1; r.udp = -1;
					r._total_degraded = false;
					return;
				}
				r.total = t.total;
				r.tcp = t.tcp;
				r.udp = t.udp;
				r._live_total = t.liveTotal;
				r._live_tcp = t.liveTcp;
				r._live_udp = t.liveUdp;
				r._total_since = t.since;
				r._total_degraded = t.degraded;
			});
		}

		// Repaints the cumulative cells in place on every byte poll, so the
		// totals climb at the poll interval instead of freezing until the next
		// full table rebuild — a counter that only moves every few seconds
		// looks broken in exactly the way this change is meant to fix.
		function updateTotalCells() {
			var specs = [
				['data-total-ip',     'total',    'liveTotal'],
				['data-total-tcp-ip', 'tcp',      'liveTcp'],
				['data-total-udp-ip', 'udp',      'liveUdp']
			];
			Object.keys(self._totalsMap).forEach(function(ip) {
				var t = self._totalsMap[ip];
				specs.forEach(function(spec) {
					var cell = connsDiv.querySelector('[' + spec[0] + '="' + ip + '"]');
					if (!cell) {
						return;
					}
					renderTotalCell(cell, t[spec[1]], t[spec[2]], t.since, false, t.degraded);
				});
			});
		}

		function renderSummary(rows) {
			self._lastRows = rows;
			mergeTotals(rows);
			var limited = rows.filter(function(r){return (r.rate_limit_kbit||0) > 0;}).length;
			var shaped  = rows.filter(function(r){return (r.shape_kbit||0) > 0;}).length;
			var blocked = rows.filter(function(r){return r.blocked;}).length;
			var wifiBlk = rows.filter(function(r){return r.wifi_blocked;}).length;
			var totalDropPkts = Object.keys(self._dropMap).reduce(function(s, ip) { return s + (self._dropMap[ip].packets||0); }, 0);

			var lnk = 'cursor:pointer;text-decoration:underline;text-decoration-style:dashed';
			var activeFilter = self._tableFilter;

			statsDiv.className = 'alert-message info';
			while (statsDiv.firstChild) statsDiv.removeChild(statsDiv.firstChild);

			function mkFilterVal(filter, color, text) {
				var active = activeFilter === filter;
				var b = E('b', {'style': lnk+';color:'+color+(active?';font-weight:700':''), 'data-filter': filter}, text);
				return b;
			}

			var parts = [];
			parts.push(E('span', {}, [document.createTextNode(_('Active') + ': '), E('b', {}, String(rows.length))]));
			parts.push(E('span', {}, [document.createTextNode(_('Blocked') + ': '), mkFilterVal('blocked', 'var(--tc-err)', String(blocked))]));
			parts.push(E('span', {}, [document.createTextNode(_('WiFi') + ': '), mkFilterVal('wifi_blocked', 'var(--tc-warn)', String(wifiBlk))]));
			if (limited > 0) parts.push(E('span', {}, [document.createTextNode(_('Limited') + ': '), mkFilterVal('limited', 'var(--tc-warn)', '⚡' + limited)]));
			if (shaped > 0) parts.push(E('span', {}, [document.createTextNode(_('Shaped') + ': '), mkFilterVal('shaped', 'var(--tc-speed)', '🌊' + shaped)]));
			if (totalDropPkts > 0) {
				parts.push(E('span', {}, [
					document.createTextNode(_('Dropped') + ': '), E('b', {'style':'color:var(--tc-err)'}, '🚫' + totalDropPkts)
				]));
			}

			parts.forEach(function(el, i) {
				if (i > 0) statsDiv.appendChild(E('span', {'style':'margin:0 6px;color:var(--tc-faint)'}, '|'));
				statsDiv.appendChild(el);
				var filterEl = el.querySelector('[data-filter]');
				if (filterEl) {
					filterEl.addEventListener('click', function() { setTableFilter(filterEl.getAttribute('data-filter')); });
				}
			});

			if (activeFilter) {
				statsDiv.appendChild(E('span', {'style':'margin-left:10px;cursor:pointer;color:var(--tc-muted);font-size:11px'}, '✕ ' + _('clear filter')));
				statsDiv.lastChild.addEventListener('click', function() { self._tableFilter = null; renderSummary(rows); });
			}

			// Says once, in words, what the ⚠ in every byte cell means. The
			// Flow Offload banner above already explains the mode, but on this
			// hardware its reassurance — that trafficctl switches to nftables
			// counters — is exactly what does not hold.
			if (rows.some(function(r) { return r._total_degraded; })) {
				statsDiv.appendChild(E('div', {
					'style': 'margin-top:8px;padding:6px 8px;border-left:3px solid var(--tc-err);' +
						'background:rgba(211,84,0,0.10);font-size:11px'
				}, [
					E('strong', {}, '⚠ ' + _('Byte totals unavailable on this router.')),
					document.createTextNode(' ' + _('Flow offload is active and the kernel does not support the nftables counter maps trafficctl uses in that mode, so byte counters stop updating for offloaded connections. Speeds and totals would be far too low, so they are not shown. Disabling hardware offload in Settings → Flow Offload restores them.'))
				]));
			}

			var filtered = applyTableFilter(rows);
			while (connsDiv.firstChild) connsDiv.removeChild(connsDiv.firstChild);
			if (filtered.length === 0) {
				connsDiv.appendChild(E('p',{'style':'color:var(--tc-muted);padding:12px 0'}, _('No devices match filter.')));
			} else {
				var tbl = buildSummaryTable(
					filtered,
					self._sumCol,
					self._sumDir,
					function(key, isNum) {
						if (self._sumCol === key) {
							self._sumDir = self._sumDir === 'asc' ? 'desc' : 'asc';
						} else {
							self._sumCol = key;
							self._sumDir = isNum ? 'desc' : 'asc';
						}
						renderSummary(rows);
					},
					function(ip) {
						var dev = rows.filter(function(r) { return r.ip === ip; })[0];
						var lbl = dev && dev.name && dev.name !== '*' ? dev.name + '  —  ' + ip : ip;
						searchSelect.setValue(ip, lbl);
						var o = loadOpts(); o.lastIp = ip; saveOpts(o); updateUrlParams(o);
						updateModeUI();
						runQuery();
					},
					self._speedMap,
					self._dropMap,
					self._shapeMap,
					self._speedHistory,
					self._hiddenCols
				);
				connsDiv.appendChild(E('div',{'style':'overflow-x:auto'},[tbl]));
				connsDiv.appendChild(E('p',{'style':'color:var(--tc-faint);font-size:11px;margin-top:6px'},
					_('Click a row to inspect that device. Download speed updates every 2 seconds.')));
			}
		}

		function runAll() {
			setStatus(statusDiv, 'loading', _('Scanning all devices…'));

			callTrafficctl().then(function(rows) {
				if (!Array.isArray(rows)) rows = [];
				searchSelect.updateDevices(rows);
				renderSummary(rows);

				// Breakdown for the App column tooltips; fire-and-forget so a
				// missing or slow netifyd never delays the table.
				if (rows.some(function(r) { return r.app; })) {
					callNetifyList().then(function(list) {
						if (!Array.isArray(list)) return;
						var m = {};
						list.forEach(function(d) { m[d.ip] = d; });
						netifyMap = m;
					}).catch(function() {});
				}
				setStatus(statusDiv, 'ok', '✓ ' + _('Done'));
				self._startBytesPoll();
			})
			.catch(function(e) { setStatus(statusDiv, 'error', '✗ '+e.message); });
		}

		function updateExtendedStats() {
			var o = loadOpts();
			if (!o.extendedStats) return;
			while (extStatsDiv.firstChild) extStatsDiv.removeChild(extStatsDiv.firstChild);
			var ip = searchSelect.getValue();
			if (ip === '__all__') {
				extStatsDiv.appendChild(buildExtendedStatsLegend(self._shapeMap, self._dropMap));
			} else {
				extStatsDiv.appendChild(buildExtendedStatsPanel(ip, self._shapeMap, self._dropMap, self._speedMap));
			}
		}

		function runQuery() {
			var ip = searchSelect.getValue();
			var o = loadOpts(); o.lastIp = ip; saveOpts(o);
			updateUrlParams(o);
			updateModeUI();
			// Switching between all-devices and a single device changes which
			// timers should be running, so tear them down and let the branch
			// below start the right set.
			var mode = (ip === '__all__') ? 'all' : 'device';
			if (self._pollMode !== mode) {
				self._pollMode = mode;
				self._stopBytesPoll();
			}
			if (ip === '__all__') {
				deviceGraphDiv.classList.add('tc-hidden');
				runAll();
			} else {
				runSingle(ip);
				self._startBytesPoll();
			}
			updateExtendedStats();
		}

		// rateBtn handler removed — applyRate() is called directly from chip clicks

		wifiBtn.addEventListener('click', function() {
			var ip   = searchSelect.getValue();
			var action = wifiBtn._wifiAction;
			wifiBtn.disabled = true;
			var name = '';
			setStatus(statusDiv, 'loading', (action==='block' ? _('Adding to') : _('Removing from')) + ' ' + _('WiFi deny list') + ': ' + name + '…');
			var fn = action === 'block' ? callMacfilterAdd : callMacfilterRemove;
			fn(ip).then(function(res) {
				setStatus(statusDiv, (res && res.ok) ? (action==='block'?'action':'ok') : 'error', (res && res.msg) || '?');
				runQuery();
			}).catch(function(e) {
				setStatus(statusDiv, 'error', '✗ '+e.message);
			}).then(function() {
				wifiBtn.disabled = false;
			});
		});

		inetBtn.addEventListener('click', function() {
			var ip = searchSelect.getValue();
			if (!ip || ip === '__all__') return;
			inetBtn.disabled = true;
			var action = inetBtn._action;
			var fn = action === 'block' ? callBlock : callUnblock;
			fn(ip, '').then(function() {
				runQuery();
			}).catch(function(e) {
				setStatus(statusDiv, 'error', e.message);
			}).then(function() {
				inetBtn.disabled = false;
			});
		});

		this._setupTimer = function() {
			if (self._timer) { clearInterval(self._timer); self._timer = null; }
			var iv = parseInt(loadOpts().refresh||0);
			if (iv > 0) self._timer = setInterval(runQuery, iv*1000);
		};

		this._startBytesPoll = function() {
			if (self._bytesTimer) return;
			var o = loadOpts();
			var pollMs = (o.pollInterval !== undefined ? o.pollInterval : 2) * 1000;
			if (pollMs <= 0) return;
			pollBytes();
			self._bytesTimer = setInterval(pollBytes, pollMs);
			pollDrops();
			self._dropTimer = setInterval(pollDrops, 5000);
			pollShapeStats();
			self._shapeTimer = setInterval(pollShapeStats, 5000);
			// Device view: keep the connection table live as well, instead of
			// freezing until the user manually refreshes. Floored at 3s because
			// this re-reads conntrack for the device on every tick.
			if (!isAllMode()) {
				self._deviceTimer = setInterval(function() {
					if (document.hidden) return;
					var ip = searchSelect.getValue();
					if (ip && ip !== '__all__') runSingle(ip);
				}, Math.max(pollMs, 3000));
			}
		};
		this._stopBytesPoll = function() {
			if (self._bytesTimer)  { clearInterval(self._bytesTimer);  self._bytesTimer  = null; }
			if (self._dropTimer)   { clearInterval(self._dropTimer);   self._dropTimer   = null; }
			if (self._shapeTimer)  { clearInterval(self._shapeTimer);  self._shapeTimer  = null; }
			if (self._deviceTimer) { clearInterval(self._deviceTimer); self._deviceTimer = null; }
		};
		this._restartBytesPoll = function() {
			self._stopBytesPoll();
			self._startBytesPoll();
		};

		this._setupTimer();
		setTimeout(function() { runQuery(); }, 0);

		var savedHidden = opts.hiddenCols || {};
		self._hiddenCols = savedHidden;

		var colChipDefs = [
			{key:'name', label:_('Device')}, {key:'ip', label:'IP'}, {key:'mac', label:'MAC'},
			{key:'_speed', label:_('DL Speed')}, {key:'_speed_up', label:_('UL Speed')},
			{key:'_spark', label:_('Graph')},
			{key:'conns', label:_('Conns')}, {key:'total', label:_('Bytes')},
			{key:'tcp', label:'TCP'}, {key:'udp', label:'UDP'},
			{key:'blocked', label:_('Inet')}, {key:'conn_type', label:_('Link')},
			{key:'_throttle_kbit', label:_('Speed Limit')},
			{key:'_drop_packets', label:_('Drops')}, {key:'_backlog', label:_('Queue')}
		];
		var colChipsContainer = E('div', {'class':'tc-chips-wrap'});
		colChipDefs.forEach(function(ct) {
			var chip = E('span', {
				'class': savedHidden[ct.key] ? 'tc-col-chip tc-col-chip--off' : 'tc-col-chip tc-col-chip--on',
				'data-tip': _('Click to toggle column visibility')
			}, ct.label);
			chip.addEventListener('click', function() {
				if (self._hiddenCols[ct.key]) { delete self._hiddenCols[ct.key]; chip.className = 'tc-col-chip tc-col-chip--on'; }
				else { self._hiddenCols[ct.key] = true; chip.className = 'tc-col-chip tc-col-chip--off'; }
				var o = loadOpts(); o.hiddenCols = self._hiddenCols; saveOpts(o);
				if (isAllMode()) runAll();
			});
			colChipsContainer.appendChild(chip);
		});

		// Per-device connection table column toggles
		var connColDefs = [
			{key:'proto', label:_('Proto')}, {key:'dst', label:_('Dst IP')},
			{key:'host', label:_('Hostname')}, {key:'port', label:_('Port')},
			{key:'service', label:_('Service')}, {key:'bytes', label:_('Bytes')},
			{key:'state', label:_('State')}, {key:'oif', label:_('Iface')}
		];
		// 'oif' (egress interface) is only populated for policy-routed (mwan3)
		// connections, so hide it by default; users on such setups enable it
		// via the column chip.
		var savedConnHidden = opts.connHiddenCols || { oif: true };
		self._connHiddenCols = savedConnHidden;
		var connColChipsContainer = E('div', {'class':'tc-chips-wrap'});
		connColDefs.forEach(function(ct) {
			var chip = E('span', {
				'class': savedConnHidden[ct.key] ? 'tc-col-chip tc-col-chip--off' : 'tc-col-chip tc-col-chip--on',
				'data-tip': _('Click to toggle column visibility')
			}, ct.label);
			chip.addEventListener('click', function() {
				if (self._connHiddenCols[ct.key]) { delete self._connHiddenCols[ct.key]; chip.className = 'tc-col-chip tc-col-chip--on'; }
				else { self._connHiddenCols[ct.key] = true; chip.className = 'tc-col-chip tc-col-chip--off'; }
				var o = loadOpts(); o.connHiddenCols = self._connHiddenCols; saveOpts(o);
				if (!isAllMode()) runQuery();
			});
			connColChipsContainer.appendChild(chip);
		});

		var sep = function() { return E('span', {'class':'tc-sep'}); };
		var sectionLabel = function(t) { return E('div', {'class':'tc-section-label'}, t); };

		var settingsBody = E('div', {'class':'tc-settings-body tc-hidden'});
		var settingsCollapsed = true;
		var settingsToggle = E('div', {'class':'tc-settings-toggle'}, [E('span', {}, '▸'), E('span', {}, _('Settings'))]);

		settingsToggle.addEventListener('click', function() {
			settingsCollapsed = !settingsCollapsed;
			settingsBody.classList.toggle('tc-hidden', settingsCollapsed);
			settingsToggle.firstChild.textContent = settingsCollapsed ? '▸' : '▾';
		});

		// ── Collapsible subsection helper ──────────────────────────────────
		function mkCollapsible(title, content, startOpen) {
			var body = E('div', {'class': 'tc-collapsible-body' + (startOpen ? '' : ' tc-hidden')});
			if (content) body.appendChild(content);
			var arrow = E('span', {'class':'tc-c-muted', 'style':'font-size:11px'}, startOpen ? ' ▾' : ' ▸');
			var label = sectionLabel(title);
			label.style.cursor = 'pointer';
			label.appendChild(arrow);
			label.addEventListener('click', function() {
				var open = !body.classList.contains('tc-hidden');
				body.classList.toggle('tc-hidden');
				arrow.textContent = open ? ' ▸' : ' ▾';
			});
			return {label: label, body: body, el: E('div', {}, [label, body])};
		}

		// ── Telegram Bot section (lazy-loaded) ─────────────────────────────
		var tgSection = mkCollapsible(_('Telegram Bot'), null, false);
		var tgLoaded = false;
		tgSection.label.addEventListener('click', function() {
			if (!tgLoaded && !tgSection.body.classList.contains('tc-hidden')) {
				tgLoaded = true;
				loadTelegramUI(tgSection.body);
			}
		});

		function loadTelegramUI(container) {
			var statusSpan = E('span', {'style':'font-size:12px;margin-left:8px;color:var(--tc-muted)'}, _('Loading…'));
			container.appendChild(statusSpan);

			callTelegramGet().then(function(cfg) {
				while (container.firstChild) container.removeChild(container.firstChild);

				var section = E('div', {'class':'tg-section'});
				container.appendChild(section);

				// ── Auto-save with debounce ──
				var saveTimer = null;
				var setupDone = false;
				var saveStatus = E('span', {'class':'tg-save-status'});
				var doSave = function() {
					if (!setupDone) return;
					if (saveTimer) clearTimeout(saveTimer);
					saveTimer = setTimeout(function() {
						saveStatus.textContent = _('Saving…');
						saveStatus.style.color = 'var(--tc-muted)';
						var tk = tokenInput.value;
						if (tk === '' && cfg.bot_token_set) tk = '***';
						var inetEl = container.querySelector('#tm-tg-inet');
						var wifiEl = container.querySelector('#tm-tg-wifi');
						var limitEl = container.querySelector('#tm-tg-limit');
						var shapeEl = container.querySelector('#tm-tg-shape');
						callTelegramSet(
							container.querySelector('#tm-tg-enabled').checked,
							tk,
							chatInput.value,
							parseInt(cfg.poll_interval) || 3,
							container.querySelector('#tm-tg-new').checked,
							container.querySelector('#tm-tg-known').checked,
							controlMode,
							templateArea.value,
							inetEl ? inetEl.checked : cfg.btn_block_inet,
							wifiEl ? wifiEl.checked : cfg.btn_block_wifi,
							limitEl ? limitEl.checked : cfg.btn_limiter,
							shapeEl ? shapeEl.checked : cfg.btn_shaper
						).then(function(res) {
							if (res && res.ok) {
								saveStatus.textContent = '✓';
								saveStatus.style.color = 'var(--tc-ok)';
								cfg.bot_token_set = !!(tk && tk !== '***') || cfg.bot_token_set;
								if (tk && tk !== '***') {
									tokenInput.value = '';
									tokenInput.type = 'password';
									tokenInput.placeholder = '••••••••  ✓ ' + _('saved');
								}
							} else {
								saveStatus.textContent = '✗ ' + (res && res.msg || 'error');
								saveStatus.style.color = 'var(--tc-err)';
							}
						}).catch(function(e) {
							saveStatus.textContent = '✗ ' + e.message;
							saveStatus.style.color = 'var(--tc-err)';
						});
					}, 600);
				};

				// ── Status dot ──
				var dot = E('span', {
					'class': 'tg-status-dot ' + (cfg.bot_running ? 'tg-status-dot--on' : 'tg-status-dot--off'),
					'title': cfg.bot_running ? _('Bot is running') : _('Bot is stopped')
				});

				// ── Enabled toggle ──
				var tgEnabled = mkToggle('tm-tg-enabled', _('Enabled'), cfg.enabled, doSave);
				section.appendChild(E('div', {'class':'tg-row'}, [tgEnabled, dot, saveStatus]));

				// ── Token + Chat ID ──
				var tokenInput = E('input', {
					'type': 'password',
					'class': 'tg-input tg-input--token',
					'value': '',
					'placeholder': cfg.bot_token_set ? '••••••••  ✓ ' + _('saved') : _('Paste bot token')
				});
				tokenInput.addEventListener('change', doSave);
				var eyeBtn = E('span', {'class':'tg-eye','title':_('Show/hide token')}, '👁');
				eyeBtn.addEventListener('click', function() {
					tokenInput.type = tokenInput.type === 'password' ? 'text' : 'password';
				});
				var chatInput = E('input', {
					'type': 'text',
					'class': 'tg-input tg-input--chat',
					'value': cfg.chat_id || '',
					'placeholder': _('Chat ID')
				});
				chatInput.addEventListener('change', doSave);
				var testResult = E('span', {'style':'font-size:11px;margin-left:4px'});
				var testBtn = E('button', {'class':'tg-btn'}, _('Test'));
				testBtn.addEventListener('click', function() {
					testBtn.disabled = true;
					testResult.textContent = _('Sending…');
					testResult.style.color = 'var(--tc-muted)';
					var tk = tokenInput.value || '***';
					callTelegramTest(tk, chatInput.value, templateArea.value || '').then(function(res) {
						testResult.textContent = (res && res.ok) ? '✓ ' + (res.msg || 'OK') : '✗ ' + (res && res.msg || 'error');
						testResult.style.color = (res && res.ok) ? 'var(--tc-ok)' : 'var(--tc-err)';
					}).catch(function(e) {
						testResult.textContent = '✗ ' + e.message;
						testResult.style.color = 'var(--tc-err)';
					}).then(function() { testBtn.disabled = false; });
				});
				section.appendChild(E('div', {'class':'tg-row'}, [
					E('span', {'class':'tg-label'}, _('Token:')), tokenInput, eyeBtn,
					E('span', {'style':'width:12px'}),
					E('span', {'class':'tg-label'}, _('Chat ID:')), chatInput,
					testBtn, testResult
				]));

				// ── Mode segmented control ──
				var controlMode = cfg.control_enabled !== false;
				var controlSection = E('div', {});
				var notifySection = E('div', {});
				function setMode(ctrl) {
					controlMode = ctrl;
					segControl.className = 'tg-segmented__item' + (ctrl ? ' tg-segmented__item--active' : '');
					segNotify.className = 'tg-segmented__item' + (!ctrl ? ' tg-segmented__item--active' : '');
					controlSection.classList.toggle('tc-hidden', !ctrl);
					doSave();
				}

				var segNotify = document.createElement('div');
				segNotify.className = 'tg-segmented__item' + (!controlMode ? ' tg-segmented__item--active' : '');
				segNotify.textContent = '🔔 ' + _('Notifications only');
				segNotify.onclick = function() { setMode(false); };

				var segControl = document.createElement('div');
				segControl.className = 'tg-segmented__item' + (controlMode ? ' tg-segmented__item--active' : '');
				segControl.textContent = '🎛 ' + _('Full control');
				segControl.onclick = function() { setMode(true); };

				var segmented = E('div', {'class':'tg-segmented'}, [segNotify, segControl]);

				section.appendChild(E('div', {'class':'tg-row'}, [segmented]));

				// ── Notifications ──
				notifySection.appendChild(E('div', {'class':'tg-divider'}, _('Notifications')));
				var notifyNew = mkToggle('tm-tg-new', _('New devices'), cfg.notify_new_device, doSave);
				var notifyKnown = mkToggle('tm-tg-known', _('Known devices'), cfg.notify_known_device, doSave);
				notifySection.appendChild(E('div', {'class':'tg-row'}, [notifyNew, notifyKnown]));

				// ── Custom template ──
				var templateArea = E('textarea', {
					'class': 'tg-input tg-input--template',
					'placeholder': '🆕 New device\\n{{ name }} ({{ ip }})\\nMAC: {{ mac }}\\nLink: {{ link }}'
				}, cfg.notify_template || '');
				templateArea.addEventListener('input', function() { renderPreview(); doSave(); });

				var previewBubble = E('div', {'class':'tg-bubble'});
				var defaultTpl = '🆕 <b>New device</b>\n{{ name }} ({{ ip }})\nMAC: <code>{{ mac }}</code>\nLink: {{ link }}';
				var renderPreview = function() {
					var tpl = templateArea.value || defaultTpl;
					var txt = tpl
						.replace(/\{\{\s*name\s*\}\}/g, 'MacBookPro')
						.replace(/\{\{\s*ip\s*\}\}/g, '192.168.0.100')
						.replace(/\{\{\s*mac\s*\}\}/g, 'aa:bb:cc:dd:ee:ff')
						.replace(/\{\{\s*link\s*\}\}/g, '5G')
						.replace(/\{\{\s*date\s*\}\}/g, new Date().toISOString().slice(0,10))
						.replace(/\{\{\s*time\s*\}\}/g, new Date().toTimeString().slice(0,5))
						.replace(/\{\{\s*datetime\s*\}\}/g, new Date().toISOString().slice(0,10) + ' ' + new Date().toTimeString().slice(0,5))
						.replace(/\{\{\s*router\s*\}\}/g, 'OpenWrt')
						.replace(/\{\{\s*ssid\s*\}\}/g, 'MyNetwork_5G')
						.replace(/\{\{\s*signal\s*\}\}/g, '-52')
						.replace(/\{\{\s*freq\s*\}\}/g, '5GHz')
						.replace(/\{\{\s*iface\s*\}\}/g, 'wlan1')
						.replace(/\{\{\s*clients\s*\}\}/g, '12')
						.replace(/\{\{\s*uptime\s*\}\}/g, '3d 5h')
						.replace(/\{\{\s*wan_ip\s*\}\}/g, '85.192.48.1')
						.replace(/\{\{\s*load\s*\}\}/g, '0.42')
						.replace(/\{\{\s*conns\s*\}\}/g, '47');
					previewBubble.innerHTML = txt.replace(/\\n/g, '<br>').replace(/\n/g, '<br>');
				};
				renderPreview();

				var varRef = E('div', {'style':'font-size:12px;line-height:1.7;color:currentColor'}, [
					E('div', {'style':'font-weight:600;margin-bottom:4px'}, _('Variables')),
					E('div', {}, [E('code', {}, '{{ name }}'), document.createTextNode(' — ' + _('device hostname'))]),
					E('div', {}, [E('code', {}, '{{ ip }}'), document.createTextNode(' — ' + _('IP address'))]),
					E('div', {}, [E('code', {}, '{{ mac }}'), document.createTextNode(' — ' + _('MAC address'))]),
					E('div', {}, [E('code', {}, '{{ link }}'), document.createTextNode(' — ' + _('connection type (5G, LAN)'))]),
					E('div', {}, [E('code', {}, '{{ date }}'), document.createTextNode(' — ' + _('date (2026-05-26)'))]),
					E('div', {}, [E('code', {}, '{{ time }}'), document.createTextNode(' — ' + _('time (14:32)'))]),
					E('div', {}, [E('code', {}, '{{ datetime }}'), document.createTextNode(' — ' + _('date + time'))]),
					E('div', {}, [E('code', {}, '{{ router }}'), document.createTextNode(' — ' + _('router hostname'))]),
					E('div', {}, [E('code', {}, '{{ ssid }}'), document.createTextNode(' — ' + _('WiFi SSID'))]),
					E('div', {}, [E('code', {}, '{{ signal }}'), document.createTextNode(' — ' + _('WiFi signal (dBm)'))]),
					E('div', {}, [E('code', {}, '{{ freq }}'), document.createTextNode(' — ' + _('WiFi band (2.4/5GHz)'))]),
					E('div', {}, [E('code', {}, '{{ iface }}'), document.createTextNode(' — ' + _('network interface'))]),
					E('div', {}, [E('code', {}, '{{ clients }}'), document.createTextNode(' — ' + _('total connected clients'))]),
					E('div', {}, [E('code', {}, '{{ uptime }}'), document.createTextNode(' — ' + _('router uptime'))]),
					E('div', {}, [E('code', {}, '{{ wan_ip }}'), document.createTextNode(' — ' + _('WAN IP'))]),
					E('div', {}, [E('code', {}, '{{ load }}'), document.createTextNode(' — ' + _('CPU load (1 min)'))]),
					E('div', {}, [E('code', {}, '{{ conns }}'), document.createTextNode(' — ' + _('device connections'))]),
					E('div', {'style':'margin-top:6px;color:var(--tc-muted);font-size:11px'}, [
						document.createTextNode(_('HTML:') + ' '),
						E('code', {}, '<b>'), document.createTextNode(' '),
						E('code', {}, '<i>'), document.createTextNode(' '),
						E('code', {}, '<code>'), document.createTextNode(' '),
						E('code', {}, '<a href="">'),
						document.createTextNode('. \\n = ' + _('line break'))
					])
				]);

				var templateToggle = E('span', {
					'style': 'font-size:12px;cursor:pointer;color:var(--tc-muted);user-select:none'
				}, '▸ ' + _('Customize message'));
				var templateBody = E('div', {'class':'tc-hidden','style':'margin-top:6px'});
				templateBody.appendChild(E('div', {'style':'display:flex;gap:14px;align-items:flex-start;flex-wrap:wrap'}, [
					E('div', {'style':'flex:1;min-width:200px'}, [templateArea]),
					varRef
				]));
				templateBody.appendChild(E('div', {'style':'margin-top:8px'}, [
					E('span', {'class':'tg-label','style':'display:block;margin-bottom:4px'}, _('Preview:')),
					previewBubble
				]));
				templateToggle.addEventListener('click', function() {
					var show = templateBody.classList.contains('tc-hidden');
					templateBody.classList.toggle('tc-hidden');
					templateToggle.textContent = (show ? '▾ ' : '▸ ') + _('Customize message');
				});
				notifySection.appendChild(E('div', {'style':'margin-top:8px'}, [templateToggle, templateBody]));

				// ── Control section (conditionally visible) ──
				controlSection.appendChild(E('div', {'class':'tg-divider'}, _('Control')));
				var btnInet = mkToggle('tm-tg-inet', _('Block Internet'), cfg.btn_block_inet, function() { updateKbd(); doSave(); });
				var btnWifi = mkToggle('tm-tg-wifi', _('Block WiFi'), cfg.btn_block_wifi, function() { updateKbd(); doSave(); });
				var btnLimit = mkToggle('tm-tg-limit', _('Limiter'), cfg.btn_limiter, function() { updateKbd(); doSave(); });
				var btnShape = mkToggle('tm-tg-shape', _('Shaper'), cfg.btn_shaper, function() { updateKbd(); doSave(); });
				controlSection.appendChild(E('div', {'class':'tg-row'}, [btnInet, btnWifi, btnLimit, btnShape]));

				// Dynamic keyboard preview
				var kbdBubble = E('div', {'class':'tg-bubble tg-bubble--kbd'});
				var updateKbd = function() {
					while (kbdBubble.firstChild) kbdBubble.removeChild(kbdBubble.firstChild);
					var inetEl = controlSection.querySelector('#tm-tg-inet');
					var wifiEl = controlSection.querySelector('#tm-tg-wifi');
					var limitEl = controlSection.querySelector('#tm-tg-limit');
					var shapeEl = controlSection.querySelector('#tm-tg-shape');
					var inetOn = inetEl ? inetEl.checked : cfg.btn_block_inet;
					var wifiOn = wifiEl ? wifiEl.checked : cfg.btn_block_wifi;
					var limitOn = limitEl ? limitEl.checked : cfg.btn_limiter;
					var shapeOn = shapeEl ? shapeEl.checked : cfg.btn_shaper;
					if (!inetOn && !wifiOn && !limitOn && !shapeOn) {
						kbdBubble.appendChild(E('div', {'style':'font-size:11px;color:var(--tc-faint);padding:4px'}, _('No action buttons enabled')));
						return;
					}
					var row1 = [];
					if (inetOn) row1.push(E('span', {'class':'tg-kbd-btn'}, '⏸ Block Internet'));
					if (wifiOn) row1.push(E('span', {'class':'tg-kbd-btn'}, '📵 Block WiFi'));
					if (row1.length) kbdBubble.appendChild(E('div', {'class':'tg-kbd-row'}, row1));
					if (limitOn) {
						var limitBtns = [];
						RATE_PRESETS.forEach(function(p) {
							if (p.v === '0' || p.v === 'custom') return;
							limitBtns.push(E('span', {'class':'tg-kbd-btn'},  + p.l.replace(' Mbit/s', 'M').replace(/\s/g, '')));
						});
						for (var li = 0; li < limitBtns.length; li += 3) {
							kbdBubble.appendChild(E('div', {'class':'tg-kbd-row'}, limitBtns.slice(li, li + 3)));
						}
					}
					if (shapeOn) {
						var shapeBtns = [];
						RATE_PRESETS.forEach(function(p) {
							if (p.v === '0' || p.v === 'custom') return;
							shapeBtns.push(E('span', {'class':'tg-kbd-btn'}, '🔧 ' + p.l.replace(' Mbit/s', 'M').replace(/\s/g, '')));
						});
						for (var si = 0; si < shapeBtns.length; si += 3) {
							kbdBubble.appendChild(E('div', {'class':'tg-kbd-row'}, shapeBtns.slice(si, si + 3)));
						}
					}
					kbdBubble.appendChild(E('div', {'class':'tg-kbd-row'}, [
						E('span', {'class':'tg-kbd-btn'}, '⬅️ Back')
					]));
				};
				updateKbd();

				controlSection.appendChild(E('div', {'style':'margin-top:8px'}, [
					E('span', {'class':'tg-label','style':'display:block;margin-bottom:4px'}, _('Inline keyboard preview:')),
					kbdBubble
				]));

				// Commands + flow explanation
				controlSection.appendChild(E('div', {'style':'margin-top:10px'}, [
					E('span', {'class':'tg-label','style':'display:block;margin-bottom:4px'}, _('Bot commands:')),
					E('div', {'class':'tg-commands'}, [
						E('div', {}, [E('code', {}, '/devices'), document.createTextNode(' — ' + _('device list → tap device → action buttons'))]),
						E('div', {}, [E('code', {}, '/status'), document.createTextNode(' — ' + _('all active blocks, limits, and shapes'))]),
						E('div', {}, [E('code', {}, '/help'), document.createTextNode(' — ' + _('command list and bot mode'))])
					]),
					E('div', {'style':'font-size:10px;color:var(--tc-faint);margin-top:4px'},
						_('Flow: /devices → select device → inline keyboard with enabled actions above'))
				]));

				if (!controlMode) controlSection.classList.add('tc-hidden');
				section.appendChild(controlSection);
				section.appendChild(notifySection);
				setupDone = true;
			}).catch(function(e) {
				statusSpan.textContent = '✗ ' + e.message;
				statusSpan.style.color = 'var(--tc-err)';
			});
		}

		// ── Assemble settings sections ─────────────────────────────────────
		settingsBody.appendChild(tgSection.el);

		var displaySection = mkCollapsible(_('Display'), E('div', {'class':'tc-settings-section-row'}, [
			showStats, showConns, overviewCheck, extStatsCheck, rdnsCheck, activityCheck,
			sep(),
			E('span', {'data-tip':_('Auto-refresh interval for summary table')}, [mkLabel(_('Refresh')+':'), refreshPick.el])
		]), false);
		settingsBody.appendChild(displaySection.el);

		// ── Logging & Persistence section (lazy-loaded) ────────────────────
		var loggingSection = mkCollapsible(_('Logging & Persistence'), null, false);
		var loggingLoaded = false;
		loggingSection.label.addEventListener('click', function() {
			if (!loggingLoaded && !loggingSection.body.classList.contains('tc-hidden')) {
				loggingLoaded = true;
				loadLoggingUI(loggingSection.body);
			}
		});

		function loadLoggingUI(container) {
			var statusSpan = E('span', {'style':'font-size:12px;color:var(--tc-muted)'}, _('Loading…'));
			container.appendChild(statusSpan);

			callLoggingGet().then(function(cfg) {
				while (container.firstChild) container.removeChild(container.firstChild);

				var logStatus = E('span', {'class':'tg-save-status'});
				var logTimer = null;
				var doLogSave = function() {
					if (logTimer) clearTimeout(logTimer);
					logTimer = setTimeout(function() {
						logStatus.textContent = _('Saving…');
						logStatus.style.color = 'var(--tc-muted)';
						callLoggingSet(
							container.querySelector('#tm-log-enabled').checked,
							null, null,
							container.querySelector('#tm-log-syslog').checked,
							container.querySelector('#tm-log-blocks').checked,
							container.querySelector('#tm-log-ratelimits').checked,
							container.querySelector('#tm-log-shapes').checked,
							container.querySelector('#tm-log-telegram').checked,
							container.querySelector('#tm-log-config').checked,
							container.querySelector('#tm-persist-rules').checked
						).then(function(res) {
							logStatus.textContent = (res && res.ok) ? '✓' : '✗';
							logStatus.style.color = (res && res.ok) ? 'var(--tc-ok)' : 'var(--tc-err)';
						}).catch(function(e) {
							logStatus.textContent = '✗';
							logStatus.style.color = 'var(--tc-err)';
						});
					}, 400);
				};

				var logEnabled = mkToggle('tm-log-enabled', _('Logging'), cfg.enabled, doLogSave);
				var logSyslog = mkToggle('tm-log-syslog', _('Syslog'), cfg.syslog, doLogSave);
				var persistRules = mkToggle('tm-persist-rules', _('Persist rules'), cfg.persist_rules, doLogSave);

				var logBlocks = mkToggle('tm-log-blocks', _('Blocks'), cfg.log_blocks, doLogSave);
				var logRatelimits = mkToggle('tm-log-ratelimits', _('Ratelimits'), cfg.log_ratelimits, doLogSave);
				var logShapes = mkToggle('tm-log-shapes', _('Shapes'), cfg.log_shapes, doLogSave);
				var logTelegram = mkToggle('tm-log-telegram', _('Telegram'), cfg.log_telegram, doLogSave);
				var logConfig = mkToggle('tm-log-config', _('Config'), cfg.log_config, doLogSave);

				container.appendChild(E('div', {'class':'tc-log-row'}, [logEnabled, logSyslog, persistRules, logStatus]));
				container.appendChild(E('div', {'style':'margin-top:6px'}, [
					E('div', {'style':'font-size:11px;color:var(--tc-muted);margin-bottom:4px'}, _('Log categories')),
					E('div', {'class':'tc-log-row'}, [logBlocks, logRatelimits, logShapes, logTelegram, logConfig])
				]));
			}).catch(function(e) {
				statusSpan.textContent = '✗ ' + e.message;
				statusSpan.style.color = 'var(--tc-err)';
			});
		}
		settingsBody.appendChild(loggingSection.el);

		// ── New Device Defaults section (lazy-loaded) ──────────────────────
		var newDevSection = mkCollapsible(_('New Device Defaults'), null, false);
		var newDevLoaded = false;
		newDevSection.label.addEventListener('click', function() {
			if (!newDevLoaded && !newDevSection.body.classList.contains('tc-hidden')) {
				newDevLoaded = true;
				loadNewDeviceUI(newDevSection.body);
			}
		});

		function loadNewDeviceUI(container) {
			var statusSpan = E('span', {'style':'font-size:12px;color:var(--tc-muted)'}, _('Loading…'));
			container.appendChild(statusSpan);

			callNewDeviceGet().then(function(cfg) {
				while (container.firstChild) container.removeChild(container.firstChild);

				var saveStatus = E('span', {'class':'tg-save-status'});
				var hint = E('div', {'style':'font-size:11px;color:var(--tc-muted);margin-top:6px'});
				var modePick = null;
				var saveTimer = null;

				// The baseline is what stops the feature limiting the whole
				// LAN, so its size is shown rather than left implicit: an
				// operator can tell a populated ledger from an empty one.
				function renderHint(c) {
					var kbit = parseInt(rateInput.value, 10);
					if (enabledToggle.querySelector('input').checked && (!kbit || kbit <= 0)) {
						hint.textContent = _('Set a rate above 0 — with no rate this does nothing.');
						hint.style.color = 'var(--tc-warn)';
						return;
					}
					hint.style.color = 'var(--tc-muted)';
					if (c && c.seeded) {
						hint.textContent = _('Devices already known:') + ' ' + (c.seen_count || 0) +
							' — ' + _('these are never limited by this setting.');
					} else {
						hint.textContent = _('No baseline recorded yet. It is taken from the current leases when you switch this on.');
					}
				}

				var doSave = function() {
					if (saveTimer) clearTimeout(saveTimer);
					saveTimer = setTimeout(function() {
						saveStatus.textContent = _('Saving…');
						saveStatus.style.color = 'var(--tc-muted)';
						var kbit = parseInt(rateInput.value, 10);
						if (isNaN(kbit) || kbit < 0) kbit = 0;
						callNewDeviceSet(
							enabledToggle.querySelector('input').checked,
							kbit,
							modePick.getValue()
						).then(function(res) {
							saveStatus.textContent = (res && res.ok) ? '✓' : '✗';
							saveStatus.style.color = (res && res.ok) ? 'var(--tc-ok)' : 'var(--tc-err)';
							if (res && res.ok) {
								callNewDeviceGet().then(renderHint).catch(function() {});
							}
						}).catch(function() {
							saveStatus.textContent = '✗';
							saveStatus.style.color = 'var(--tc-err)';
						});
					}, 400);
				};

				var enabledToggle = mkToggle('tm-nd-enabled', _('Limit new devices'), cfg.enabled, function() {
					renderHint(cfg);
					doSave();
				});

				var rateInput = E('input', {
					'type': 'number',
					'min': '0',
					'class': 'tg-input tg-input--chat',
					'value': cfg.limit_kbit || 0,
					'placeholder': _('kbit/s')
				});
				rateInput.addEventListener('change', function() {
					renderHint(cfg);
					doSave();
				});

				modePick = mkChipPick([
					{ v: 'limiter', l: _('Limiter') },
					{ v: 'shaper', l: _('Shaper') }
				], cfg.limit_mode || 'limiter', doSave);

				container.appendChild(E('div', {'class':'tc-log-row'}, [
					enabledToggle, mkLabel(_('Rate')), rateInput, mkLabel(_('kbit/s')),
					modePick.el, saveStatus
				]));
				container.appendChild(hint);
				container.appendChild(E('div', {'style':'font-size:11px;color:var(--tc-muted);margin-top:4px'},
					_('Applied once, the first time a device appears on the network. A device that already has a limit is left alone.')));

				renderHint(cfg);
			}).catch(function(e) {
				statusSpan.textContent = '✗ ' + e.message;
				statusSpan.style.color = 'var(--tc-err)';
			});
		}
		settingsBody.appendChild(newDevSection.el);

		// ── Flow Offload section (lazy-loaded) ─────────────────────────────
		var offloadSection = mkCollapsible(_('Flow Offload'), null, false);
		var offloadLoaded = false;
		offloadSection.label.addEventListener('click', function() {
			if (!offloadLoaded && !offloadSection.body.classList.contains('tc-hidden')) {
				offloadLoaded = true;
				loadOffloadUI(offloadSection.body);
			}
		});

		function loadOffloadUI(container) {
			var statusSpan = E('span', {'style':'font-size:12px;color:var(--tc-muted)'}, _('Loading…'));
			container.appendChild(statusSpan);

			callConfigGet().then(function(cfg) {
				while (container.firstChild) container.removeChild(container.firstChild);

				var saveStatus = E('span', {'class':'tg-save-status'});
				var saveTimer = null;
				var swCb, hwCb;

				function doSave() {
					if (saveTimer) clearTimeout(saveTimer);
					saveTimer = setTimeout(function() {
						saveStatus.textContent = _('Applying…');
						saveStatus.style.color = 'var(--tc-muted)';
						callConfigSet(undefined, undefined, swCb.checked, hwCb.checked).then(function(res) {
							saveStatus.textContent = (res && res.ok) ? '✓ ' + _('Applied — firewall reloading') : '✗';
							saveStatus.style.color = (res && res.ok) ? 'var(--tc-ok)' : 'var(--tc-err)';
						}).catch(function(e) {
							saveStatus.textContent = '✗';
							saveStatus.style.color = 'var(--tc-err)';
						});
					}, 400);
				}

				// Current mode badge
				var modeLabels = {
					'none':              ['⊘', _('No offload'),              'var(--tc-muted)'],
					'software':          ['◑', _('Software offload'),        'var(--tc-speed)'],
					'hardware-counter':  ['●', _('Hardware offload'),        'var(--tc-warn)'],
					'hardware':          ['●', _('Hardware offload'),        'var(--tc-warn)']
				};
				var ml = modeLabels[cfg.offload_mode] || ['?', cfg.offload_mode, 'var(--tc-muted)'];
				var modeBadge = E('div', {'style':'margin-bottom:10px;font-size:12px'}, [
					E('span', {'style':'color:'+ml[2]+';font-size:15px;margin-right:4px'}, ml[0]),
					E('span', {'style':'color:var(--tc-muted)'}, _('Current mode: ')),
					E('b', {}, ml[1])
				]);

				// SW toggle row
				var swToggleEl = mkToggle('tc-offload-sw', _('Software flow offload'), cfg.sw, function() {
					hwCb.disabled = !swCb.checked;
					if (!swCb.checked) { hwCb.checked = false; }
					doSave();
				});
				swCb = swToggleEl.querySelector('input');
				var swDesc = E('div', {'class':'tc-offload-desc'},
					_('Accelerates routing in the kernel via nftables flowtable. Speed monitoring and traffic shaping work normally.'));

				// HW toggle row
				var hwToggleEl = mkToggle('tc-offload-hw', _('Hardware flow offload'), cfg.hw, doSave);
				hwCb = hwToggleEl.querySelector('input');
				if (!cfg.sw) hwCb.disabled = true;
				var hwDesc = E('div', {'class':'tc-offload-desc'},
					_('Offloads routing to the hardware engine (PPE/NPU). Requires software offload. ' +
					  '⚠ On many platforms (e.g. Mediatek Filogic) the driver does not report byte counters back to the kernel — real-time speed monitoring will show zero.'));

				container.appendChild(modeBadge);
				container.appendChild(E('div', {'class':'tc-offload-row'}, [swToggleEl, saveStatus]));
				container.appendChild(swDesc);
				container.appendChild(E('div', {'class':'tc-offload-row tc-offload-row--hw'}, [hwToggleEl]));
				container.appendChild(hwDesc);
			}).catch(function(e) {
				statusSpan.textContent = '✗ ' + (e.message || e);
				statusSpan.style.color = 'var(--tc-err)';
			});
		}
		settingsBody.appendChild(offloadSection.el);

		var connFiltersRow = E('div', {'class':'tc-conn-filters-row'}, [
			E('span', {'data-tip':_('Filter connections by protocol')}, [mkLabel(_('Proto')+':'), protoPick.el]),
			sep(),
			E('span', {'data-tip':_('Group connections table rows')}, [mkLabel(_('Group')+':'), groupPick.el])
		]);
		var tableSection = mkCollapsible(_('Table & Speed'), E('div', {'class':'tc-table-speed-inner'}, [
			E('div', {'class':'tc-table-speed-row'}, [
				E('span', {'data-tip':_('How often live data is polled: speeds, graphs, drop/backlog counters, and the connection table in device view')}, [mkLabel(_('Poll')+':'), pollIntervalPick.el]),
				sep(),
				E('span', {'data-tip':_('Time window for speed averaging')}, [mkLabel(_('Window')+':'), avgWindowPick.el]),
				sep(),
				E('span', {'data-tip':_('Simple = arithmetic mean, EWMA = exponential weighted moving average')}, [mkLabel(_('Method')+':'), avgMethodPick.el])
			]),
			E('div', {'style':'font-size:11px;color:var(--tc-muted);margin-bottom:4px'}, _('Visible columns')),
			colChipsContainer,
			connColChipsContainer,
			connFiltersRow
		]), false);
		settingsBody.appendChild(tableSection.el);

		function updateTableSectionMode() {
			var all = isAllMode();
			colChipsContainer.classList.toggle('tc-hidden', !all);
			connColChipsContainer.classList.toggle('tc-hidden', all);
			connFiltersRow.classList.toggle('tc-hidden', all);
		}
		updateTableSectionMode();

		var settingsPanel = E('div', {'class':'tc-settings-panel'}, [settingsToggle, settingsBody]);

		function loadActivityPanel(container) {
			container.className = 'tc-activity-panel';
			var statusSpan = E('span', {'style':'font-size:12px;color:var(--tc-muted)'}, _('Loading…'));
			container.appendChild(statusSpan);

			callActivityLog(100).then(function(res) {
				while (container.firstChild) container.removeChild(container.firstChild);
				if (!res || !res.lines || !res.lines.length) {
					container.appendChild(E('div', {'style':'font-size:12px;color:var(--tc-muted)'}, _('No activity recorded yet.')));
					return;
				}
				var logArea = E('div', {'class':'tc-log-area'});
				var lines = res.lines.slice().reverse();
				lines.forEach(function(line) {
					var lineEl = E('div', {'class':'tc-log-line'});
					lineEl.textContent = line;
					logArea.appendChild(lineEl);
				});
				var refreshBtn = E('button', {
					'class': 'cbi-button',
					'style': 'font-size:11px;padding:2px 10px;margin-top:6px'
				}, _('Refresh'));
				refreshBtn.addEventListener('click', function() {
					while (container.firstChild) container.removeChild(container.firstChild);
					container._loaded = false;
					loadActivityPanel(container);
				});
				container.appendChild(logArea);
				container.appendChild(refreshBtn);
			}).catch(function(e) {
				statusSpan.textContent = '✗ ' + e.message;
				statusSpan.style.color = 'var(--tc-err)';
			});
		}

		if (opts.showActivity) {
			activityDiv._loaded = true;
			loadActivityPanel(activityDiv);
		}

		callVersion().then(function(res) {
			var el = document.getElementById('tc-version-footer');
			if (el && res && res.version) {
				el.textContent = 'trafficctl v' + res.version + ' (' + TRAFFICCTL_BUILD + ')';
			}
		});

		var mkOffloadBanner = function(mode) {
			if (!mode || mode === 'none') return null;

			var bg, border, icon, body;
			var para = function(text) { return E('p', {'style': 'margin:6px 0'}, text); };
			var bold = function(text) { return E('strong', {}, text); };
			var link = function(url, text) {
				return E('a', {'href': url, 'target': '_blank',
					'style': 'color:inherit;text-decoration:underline'}, text);
			};

			var openwrtUrl = 'https://openwrt.org/docs/guide-user/perf_and_log/flow_offloading';
			var kernelUrl  = 'https://docs.kernel.org/networking/nf_flowtable.html#hardware-offload';
			var nftUrl     = 'https://wiki.nftables.org/wiki-nftables/index.php/Flowtables';

			var sep = E('span', {'style': 'opacity:0.35;margin:0 6px'}, '|');
			var docLinks = para([
				link(openwrtUrl, 'OpenWrt: Flow offloading ↗'), sep.cloneNode(true),
				link(kernelUrl,  'Linux kernel: nf_flowtable ↗'), sep.cloneNode(true),
				link(nftUrl,     'nftables: Flowtables ↗')
			]);

			if (mode === 'hardware-counter') {
				bg     = 'rgba(211,84,0,0.10)';
				border = '#d35400';
				icon   = '⚠️';
				body   = E('div', {}, [
					para(bold(_('Hardware flow offloading active — real-time speed monitoring unavailable.'))),
					para([_('The flowtable '),
						E('code', {}, 'counter'),
						_(' flag should sync hardware byte counts back to conntrack, but on many ' +
						  'platforms (e.g. Mediatek Filogic) the driver does not implement the stats ' +
						  'callback, so conntrack counters remain frozen for active flows.')]),
					para(bold(_('To restore speed monitoring:'))),
					E('ul', {'class': 'tc-offload-ul'}, [
						E('li', {}, [
							_('Disable hardware offload (keeps software offload): '),
							E('code', {}, 'uci set firewall.@defaults[0].flow_offloading_hw=0 && uci commit firewall && fw4 reload'),
						]),
						E('li', {}, _('Or disable all flow offload in LuCI → Network → Firewall → General Settings.')),
					]),
					para(_('Blocking, rate limiting, and traffic shaping continue to work regardless.')),
					docLinks,
				]);
				} else if (mode === 'hardware') {
				bg     = 'rgba(211,84,0,0.10)';
				border = '#d35400';
				icon   = '⚠️';
				body   = E('div', {}, [
					para(bold(_('Hardware flow offloading is active.'))),
					para(_('The router offloads established connections from the CPU to the hardware (NIC/SoC), ' +
						  'achieving 2–3× higher throughput and lower CPU usage.')),
					para(_('In this mode the kernel\'s conntrack, firewall, and tc are bypassed for offloaded flows:')),
					E('ul', {'class': 'tc-offload-ul'}, [
						E('li', {}, _('Speed monitoring — conntrack byte counters are not updated')),
						E('li', {}, _('Traffic shaping (tc/HTB) — bypassed for offloaded flows')),
						E('li', {}, _('Rate limiting — applies only to new connections')),
					]),
					para([_('WiFi blocking and internet blocking of new connections still work. '),
						_('Shaped devices are usually not offloaded (kernel detects the HTB qdisc).')]),
					para(bold(_('How to get full functionality without disabling offload:'))),
					para([_('The flowtable '),
						E('code', {}, 'counter'),
						_(' flag (Linux 5.7+, set automatically by fw4/nftables) periodically syncs ' +
						  'hardware byte counts back to conntrack — trafficctl detects this and all features work normally.')]),
					para(_('If your current firmware uses fw3 (iptables) or ships a kernel older than 5.7, ' +
						  'a router with modern OpenWrt and fw4 support will have this working out of the box.')),
					docLinks,
				]);
			} else {
				bg     = 'rgba(243,156,18,0.10)';
				border = '#f39c12';
				icon   = 'ℹ️';
				body   = E('div', {}, [
					para(bold(_('Software flow offloading is active.'))),
					para(_('The kernel fast-paths established connections through a flowtable, ' +
						  'bypassing conntrack byte updates for higher throughput.')),
					para(_('Speed is measured via nftables counters installed at a higher priority ' +
						  '(before the flowtable), so graphs are accurate.')),
					para(_('Traffic shaping and blocking are not affected.')),
					docLinks,
				]);
			}

			var banner = E('div', {
				'class': 'tc-offload-banner',
				'style': 'border:1px solid ' + border + ';background:' + bg
			}, [
				E('div', {'class': 'tc-offload-banner__row'}, [
					E('span', {'class': 'tc-offload-banner__icon'}, icon),
					E('div', {'class': 'tc-offload-banner__body'}, body),
					E('span', {
						'class': 'tc-offload-banner__close',
						'title': _('Dismiss')
					}, '×')
				])
			]);
			banner.firstChild.lastChild.addEventListener('click', function() {
				banner.classList.add('tc-hidden');
			});
			return banner;
		};

		var offloadBanner = E('div', {'id': 'tc-offload-banner', 'class': 'tc-hidden'});

		// Debug: add ?offload_debug=1 to URL to preview all banner types at once
		if (window.location.search.indexOf('offload_debug') !== -1) {
			['hardware-counter', 'software', 'hardware'].forEach(function(mode) {
				var b = mkOffloadBanner(mode);
				if (b) offloadBanner.appendChild(b);
			});
			offloadBanner.classList.remove('tc-hidden');
		} else {
			callConfigGet().then(function(cfg) {
				var b = mkOffloadBanner(cfg && cfg.offload_mode);
				if (!b) return;
				offloadBanner.appendChild(b);
				offloadBanner.classList.remove('tc-hidden');
			});
		}

		return E('div', {'class':'cbi-map', 'style':'color:currentColor'}, [
			E('h2', {'style':'color:currentColor'}, _('Traffic Control')),
			E('div', {'class':'cbi-section'}, [
				offloadBanner,
				E('div', {'style':'margin-bottom:10px'}, [
						E('div', {'style':'display:flex;align-items:center;gap:10px;flex-wrap:wrap'}, [searchSelect.el, actionRow]),
						quickBar
					]),
				statusDiv,
				rateLimitRow,
				settingsPanel,
				overviewDiv,
				statsDiv,
				extStatsDiv,
				deviceGraphDiv,
				connsDiv,
				activityDiv
			]),
			E('div', {'id':'tc-version-footer','class':'tc-version-footer'},
				'trafficctl (' + TRAFFICCTL_BUILD + ')')
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null,

	handleTeardown: function() {
		if (this._timer) { clearInterval(this._timer); this._timer = null; }
		this._stopBytesPoll && this._stopBytesPoll();
		if (this._onPopState) { window.removeEventListener('popstate', this._onPopState); this._onPopState = null; }
		if (this._graphPopupTimer) { clearInterval(this._graphPopupTimer); this._graphPopupTimer = null; }
		if (this._graphPopup && this._graphPopup.parentNode) { this._graphPopup.parentNode.removeChild(this._graphPopup); this._graphPopup = null; }
		// The overview panel lives inside the view's own tree, so the DOM goes
		// with it — but its sample history is on the view object and would be
		// carried into the next visit, where it would draw a graph with a hole
		// the size of the time spent on another page.
		this._ifHistory = {};
		this._ifBytes = {};
		this._ifMeta = [];
	}
});
