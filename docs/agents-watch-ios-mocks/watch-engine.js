(function () {
  'use strict';
  if (window.TailscodeWatch) return;

  var TAU = Math.PI * 2;
  function clamp(x, a, b) { return x < a ? a : x > b ? b : x; }
  function lerp(a, b, t) { return a + (b - a) * t; }
  function smooth(t) { t = clamp(t, 0, 1); return t * t * (3 - 2 * t); }
  function easeOut(t) { t = clamp(t, 0, 1); return 1 - Math.pow(1 - t, 3); }
  function bump(x) { return Math.exp(-(x * x) / 0.0072); }
  function breath(t, period, animated) { return animated ? 0.5 + 0.5 * Math.sin(TAU * t / period) : 0.6; }
  function knock(t, period, second, animated) {
    if (!animated) return 0.35;
    var p = t % period;
    return Math.max(bump(p), 0.8 * bump(p - second));
  }

  function hex(h) {
    h = h.replace('#', '');
    return [parseInt(h.slice(0, 2), 16) / 255, parseInt(h.slice(2, 4), 16) / 255, parseInt(h.slice(4, 6), 16) / 255];
  }
  function mix(a, b, t) { return [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t]; }
  function lift(c, t) { return mix(c, [1, 1, 1], t); }
  function sink(c, t) { return mix(c, [0, 0, 0], t); }
  function hue(c) {
    var hi = Math.max(c[0], c[1], c[2]), lo = Math.min(c[0], c[1], c[2]), span = hi - lo;
    if (span <= 0.04) return -1;
    var d;
    if (hi === c[0]) d = 60 * (((c[1] - c[2]) / span) % 6);
    else if (hi === c[1]) d = 60 * ((c[2] - c[0]) / span + 2);
    else d = 60 * ((c[0] - c[1]) / span + 4);
    return d < 0 ? d + 360 : d;
  }
  function rgba(c, a) {
    return 'rgba(' + Math.round(clamp(c[0], 0, 1) * 255) + ',' + Math.round(clamp(c[1], 0, 1) * 255) + ',' + Math.round(clamp(c[2], 0, 1) * 255) + ',' + (a == null ? 1 : clamp(a, 0, 1)).toFixed(3) + ')';
  }

  var THEMES = {
    rosepine: { name: 'Rosé Pine', canvas: '#191724', rule: '#26233a', text: '#e0def4', textDim: '#908caa', accent: '#9ccfd8', warn: '#f6c177', danger: '#eb6f92', info: '#c4a7e7', special: '#ebbcba' },
    tokyonight: { name: 'Tokyo Night', canvas: '#1a1b26', rule: '#292e42', text: '#c0caf5', textDim: '#7a84b0', accent: '#9ece6a', warn: '#e0af68', danger: '#f7768e', info: '#bb9af7', special: '#7dcfff' },
    suomi: { name: 'Suomi', canvas: '#0a1522', rule: '#1b3049', text: '#e9f1f9', textDim: '#8ba3bd', accent: '#5fd9a3', warn: '#eec26b', danger: '#f0788a', info: '#85c7f0', special: '#bb9ce8' },
    phosphor: { name: 'Phosphor', canvas: '#030806', rule: '#0e2a20', text: '#b8ffd0', textDim: '#5b9c76', accent: '#39ff88', warn: '#ffd166', danger: '#ff5d5d', info: '#67e8f9', special: '#c9a7ff' }
  };

  function palette(id, night) {
    var s = THEMES[id] || THEMES.rosepine;
    var canvas = hex(s.canvas), info = hex(s.info), warn = hex(s.warn), danger = hex(s.danger), special = hex(s.special);
    var h = hue(special);
    var P = {
      ground: sink(canvas, 0.12), deep: sink(canvas, 0.62), text: lift(hex(s.text), 0.3), dim: lift(hex(s.textDim), 0.12),
      rule: hex(s.rule), working: hex(s.accent), thinking: (h >= 215 && h <= 320) ? special : mix([0.68, 0.56, 1], info, 0.12),
      needs: warn, failed: danger, overdue: lift(mix(warn, danger, 0.62), 0.08),
      quiet: sink(mix(hex(s.textDim), info, 0.22), 0.12), finished: info
    };
    if (night) {
      var warm = [1, 0.64, 0.4];
      Object.keys(P).forEach(function (k) { P[k] = sink(mix(P[k], warm, k === 'ground' || k === 'deep' ? 0.06 : 0.22), k === 'ground' || k === 'deep' ? 0.25 : 0.2); });
    }
    return P;
  }

  function ink(P, s) {
    switch (s) {
      case 'working': return P.working;
      case 'thinking': return P.thinking;
      case 'needs': case 'retrying': case 'stuck': return P.needs;
      case 'overdue': return P.overdue;
      case 'quiet': return P.quiet;
      case 'background': return P.working;
      case 'done': return P.finished;
      case 'failed': return P.failed;
      default: return P.dim;
    }
  }

  var DEVICES = {
    'ipad-l': { name: 'iPad Pro 13″', pose: 'Landscape', w: 1376, h: 1032, safe: [0, 0, 20, 0], corner: 18, turn: 'ipad-p', seen: 'iPad' },
    'ipad-p': { name: 'iPad Pro 13″', pose: 'Portrait', w: 1032, h: 1376, safe: [0, 0, 20, 0], corner: 18, turn: 'ipad-l', seen: 'iPad' },
    'duo-wide': { name: 'iPhone Duo', pose: 'Open, wide', w: 951, h: 669, safe: [0, 84, 0, 0], corner: 55, turn: 'duo-tall', seen: 'iPhone' },
    'duo-tall': { name: 'iPhone Duo', pose: 'Open, tall', w: 669, h: 951, safe: [82, 0, 34, 0], corner: 55, turn: 'duo-wide', seen: 'iPhone' },
    'duo-book': { name: 'iPhone Duo', pose: 'Book, 127°', w: 951, h: 669, safe: [0, 84, 0, 0], corner: 55, fold: { axis: 'v', from: 455.5, to: 495.5 }, turn: 'duo-laptop', seen: 'iPhone' },
    'duo-laptop': { name: 'iPhone Duo', pose: 'Laptop, 127°', w: 669, h: 951, safe: [82, 0, 34, 0], corner: 55, fold: { axis: 'h', from: 455.5, to: 495.5 }, turn: 'duo-book', seen: 'iPhone' },
    'duo-closed': { name: 'iPhone Duo', pose: 'Closed', w: 466, h: 678, safe: [82, 84, 34, 0], corner: 59, turn: 'duo-tent', seen: 'iPhone' },
    'duo-tent': { name: 'iPhone Duo', pose: 'Closed, tent', w: 678, h: 466, safe: [0, 84, 21, 0], corner: 59, turn: 'duo-closed', seen: 'iPhone' },
    'phone-l': { name: 'iPhone Air', pose: 'Landscape, on a stand', w: 912, h: 420, safe: [0, 62, 21, 62], corner: 55, seen: 'iPhone' },
    'display': { name: 'External display', pose: '16:9, from an iPad', w: 1920, h: 1080, safe: [0, 0, 0, 0], corner: 6, seen: 'iPad' },
    'window': { name: 'iPad window', pose: 'Stage Manager', w: 760, h: 560, safe: [0, 0, 0, 0], corner: 12, seen: 'iPad' }
  };

  function worker(id, name, state, words, o) {
    return Object.assign({ id: id, name: name, state: state, words: words, todo: null, started: 60, born: -99, ended: null, quietFor: 0 }, o || {});
  }
  function tile(id, title, state, o) {
    return Object.assign({
      id: id, title: title, machine: 'studio', model: 'Opus', state: state, words: '', detail: '', cmd: '', lead: '',
      started: 120, since: 0, ctx: 0.4, workers: [], phrases: [], attempt: 0
    }, o || {});
  }

  var PHRASES = {
    reconnect: ['Changing Backoff.swift', 'Looking at ReconnectTests.swift', 'Running the reconnect tests', 'Searching the code for “jitter”', 'Changing Backoff.swift'],
    landing: ['Changing footer.css', 'Looking at index.html', 'Checking every link', 'Building the site', 'Changing footer.css'],
    index: ['Running the index tests', 'Looking at IndexStore.swift', 'Changing IndexStore.swift', 'Running the index tests'],
    backup: ['Copying photos to the vault', 'Checking what changed', 'Copying photos to the vault'],
    ci: ['Looking at the build script', 'Changing ci.yml', 'Running the build']
  };

  var PAST = [[/^Changing /, 'Changed '], [/^Looking at /, 'Looked at '], [/^Running /, 'Ran '], [/^Searching /, 'Searched '], [/^Checking /, 'Checked '], [/^Building /, 'Built '], [/^Copying /, 'Copied '], [/^Reading /, 'Read '], [/^Following /, 'Followed '], [/^Getting /, 'Got ']];
  function past(s) { for (var i = 0; i < PAST.length; i++) if (PAST[i][0].test(s)) return s.replace(PAST[i][0], PAST[i][1]); return s; }

  var RECENT = [
    { outcome: 'done', title: 'Deploy check', ago: 30 },
    { outcome: 'stopped', title: 'Lint sweep', ago: 50 },
    { outcome: 'done', title: 'Docs pass', ago: 300 },
    { outcome: 'done', title: 'Icon export', ago: 780 }
  ];

  function scene(name) {
    var reconnect = function (o) {
      return tile('w', 'Fix reconnect test', 'working', Object.assign({ words: 'Changing Backoff.swift', started: 372, ctx: 0.46, phrases: PHRASES.reconnect, model: 'Opus' }, o || {}));
    };
    var landing = function (o) {
      return tile('l', 'Landing page refresh', 'working', Object.assign({ machine: 'homelab', model: 'Sonnet', words: 'Changing footer.css', started: 940, ctx: 0.63, phrases: PHRASES.landing }, o || {}));
    };
    var ask = function (overdue) {
      return tile('ask', 'CI migration', overdue ? 'overdue' : 'needs', { model: 'Opus', lead: 'Wants to run', words: 'Clearing the build folder, then building the project', cmd: 'rm -rf build && swift build -c release', since: overdue ? 432 : 20, started: 610, ctx: 0.38, phrases: PHRASES.ci });
    };
    var m = { tiles: [], recent: RECENT.slice(), listed: [{ title: 'Schema diff', machine: 'homelab', agents: 2 }], seed: 7 };
    if (name.indexOf('c-') === 0) {
      m.listed = [];
      m.recent = [];
      var base = reconnect();
      if (name === 'c-working') m.tiles = [base];
      else if (name === 'c-squad') {
        base.workers = [worker('k1', 'Explore', 'working', 'Reading the retry paths', { todo: [4, 6], started: 190 }), worker('k2', 'Plan', 'working', 'Searching the code', { started: 75 })];
        m.tiles = [base];
      } else if (name === 'c-needs') m.tiles = [ask(false)];
      else if (name === 'c-overdue') m.tiles = [ask(true)];
      else if (name === 'c-retry') m.tiles = [tile('doc', 'Docs translation', 'retrying', { machine: 'homelab', model: 'Sonnet', words: 'The AI service is busy, trying again', attempt: 2, started: 260, ctx: 0.31 })];
      else if (name === 'c-quiet') m.tiles = [reconnect({ state: 'quiet', words: 'Nothing has moved for 3m', since: 180 })];
      else if (name === 'c-ctx') m.tiles = [reconnect({ ctx: 0.91 })];
      m.tiles.forEach(function (x) { x.id = 'a'; });
    } else if (name === 'calm') {
      m.listed = [];
      m.seed = 3;
    } else if (name === 'busy' || name === 'live') {
      m.tiles = [
        reconnect({ workers: [worker('x1', 'Explore', 'working', 'Reading the retry paths', { todo: [4, 6], started: 190 }), worker('x2', 'Test runner', 'background', 'Running the tests', { started: 420 })] }),
        landing(),
        tile('t', 'Draft changelog', 'thinking', { model: 'Fable', words: 'Thinking', started: 95, ctx: 0.18, history: ['Read the commit log', 'Looked at CHANGELOG.md'] }),
        tile('r', 'Release notes', 'background', { model: 'Sonnet', words: 'Running the tests', started: 1320, ctx: 0.52, history: ['Wrote the release notes', 'Started the tests'] })
      ];
    } else if (name === 'attention') {
      m.tiles = [
        ask(false),
        reconnect({ workers: [worker('x1', 'Explore', 'working', 'Reading the retry paths', { todo: [4, 6], started: 190 })] }),
        tile('doc', 'Docs translation', 'retrying', { machine: 'homelab', model: 'Sonnet', words: 'The AI service is busy, trying again', attempt: 2, started: 260, ctx: 0.31 }),
        tile('idx', 'Index rebuild', 'working', { words: 'Running the index tests', started: 150, ctx: 0.22, phrases: PHRASES.index }),
        tile('bak', 'Nightly backup', 'working', { machine: 'attic', model: 'Haiku', words: 'Copying photos to the vault', started: 2400, ctx: 0.12, phrases: PHRASES.backup }),
        tile('rel', 'Release notes', 'stuck', { model: 'Sonnet', words: 'Running the tests', detail: 'no word from it for 9m', started: 2700, ctx: 0.52 })
      ];
    } else if (name === 'alarm') {
      m.tiles = [
        ask(true),
        tile('auth', 'Auth flow', 'failed', { words: 'The build failed', detail: 'swift build exited with status 1', started: 840, ctx: 0.71, since: 90 }),
        tile('doc', 'Docs translation', 'retrying', { machine: 'homelab', model: 'Sonnet', words: 'The AI service is busy, trying again', attempt: 3, started: 400, ctx: 0.31 }),
        reconnect({ state: 'quiet', words: 'Quiet for 3m', since: 180 }),
        tile('bak', 'Nightly backup', 'away', { machine: 'attic', model: 'Haiku', words: 'attic is not answering', detail: 'last seen 4m ago', started: 2400, ctx: 0.12 }),
        landing()
      ];
    } else if (name === 'squad') {
      m.tiles = [
        reconnect({ workers: [
          worker('a1', 'Explore', 'working', 'Reading the retry paths', { todo: [4, 6], started: 190 }),
          worker('a2', 'Plan', 'working', 'Searching the code', { started: 75 }),
          worker('a3', 'Review', 'working', 'Looking at Backoff.swift', { started: 40 }),
          worker('a4', 'Docs sweep', 'quiet', 'Quiet for 2m', { started: 300, quietFor: 120 }),
          worker('a5', 'Test runner', 'background', 'Running the tests', { started: 420 }),
          worker('a6', 'Lint sweep', 'working', 'Checking the style', { started: 30 })
        ] }),
        landing({ workers: [
          worker('b1', 'Footer styles', 'working', 'Changing footer.css', { started: 50 }),
          worker('b2', 'Link check', 'working', 'Following the redirects', { todo: [7, 9], started: 95 })
        ] })
      ];
    }
    return m;
  }

  function moodOf(tiles) {
    var s = { working: 0, needs: 0, overdue: 0, failed: 0, background: 0, quiet: 0 };
    tiles.forEach(function (t) {
      if (t.leaving) return;
      if (t.state === 'working' || t.state === 'thinking' || t.state === 'retrying') s.working++;
      else if (t.state === 'needs') s.needs++;
      else if (t.state === 'overdue') s.overdue++;
      else if (t.state === 'failed') s.failed++;
      else if (t.state === 'background' || t.state === 'stuck') s.background++;
      else if (t.state === 'quiet') s.quiet++;
    });
    s.mood = (s.overdue || s.failed) ? 'alarm' : s.needs ? 'attention' : (s.working || s.background || s.quiet) ? 'busy' : 'calm';
    return s;
  }

  function wallBase(n, aspect) {
    var shape = aspect >= 1.2 ? 'l' : aspect <= 0.9 ? 'p' : 's';
    if (n <= 0) return [0, 0];
    if (n === 1) return [1, 1];
    if (n === 2) return shape === 'l' ? [2, 1] : [1, 2];
    if (n === 3) return shape === 'l' ? [3, 1] : shape === 'p' ? [1, 3] : [2, 2];
    if (n === 4) return [2, 2];
    return shape === 'p' ? [2, 3] : [3, 2];
  }

  function rect(x, y, w, h) { return { x: x, y: y, w: Math.max(0, w), h: Math.max(0, h) }; }

  function placeGrid(n, area, aspect, gap, columnsOverride) {
    if (!n) return [];
    var cr = columnsOverride ? [columnsOverride.length, Math.ceil(n / columnsOverride.length)] : wallBase(n, aspect);
    var c = cr[0], r = cr[1];
    var ch = (area.h - gap * (r - 1)) / r;
    var cells = [];
    for (var row = 0; row < r; row++) {
      var start = row * c, inRow = Math.min(c, n - start);
      if (inRow <= 0) break;
      if (columnsOverride) {
        for (var j = 0; j < inRow; j++) {
          var col = columnsOverride[j];
          cells.push(rect(col.x, area.y + row * (ch + gap), col.w, ch));
        }
        continue;
      }
      var spans = [];
      for (var k = 0; k < inRow; k++) spans.push(1);
      var spare = c - inRow, turn = 0;
      while (spare > 0) { spans[turn % inRow]++; spare--; turn++; }
      var cw = (area.w - gap * (c - 1)) / c, x = area.x;
      for (var s = 0; s < inRow; s++) {
        var w = cw * spans[s] + gap * (spans[s] - 1);
        cells.push(rect(x, area.y + row * (ch + gap), w, ch));
        x += w + gap;
      }
    }
    return cells;
  }

  function capacity(sessions) { return sessions <= 1 ? 6 : sessions === 2 ? 5 : sessions === 3 ? 4 : 3; }

  function cutCell(cell, t, sessions, u, gap, showSquads) {
    var live = t.workers.filter(function (w) { return !w.gone; });
    var out = { cell: cell, main: cell, workers: [], plus: null, dots: 0 };
    if (!live.length) return out;
    if (!showSquads) { out.dots = live.length; return out; }
    var g = gap * 0.6;
    var minW = Math.max(13 * u, 104), minH = Math.max(5.4 * u, 40);
    var wide = cell.w / cell.h >= 1.2;
    var main, area;
    var share = live.length === 1 ? 0.34 : live.length === 2 ? 0.36 : live.length === 3 ? 0.4 : 0.46;
    if (wide) {
      var mw = Math.max(cell.w * (1 - share), Math.min(cell.w * 0.62, 30 * u));
      main = rect(cell.x, cell.y, mw, cell.h);
      area = rect(cell.x + mw + g, cell.y, cell.w - mw - g, cell.h);
    } else {
      var mh = Math.max(cell.h * (1 - share - 0.02), Math.min(cell.h * 0.6, 18 * u));
      main = rect(cell.x, cell.y, cell.w, mh);
      area = rect(cell.x, cell.y + mh + g, cell.w, cell.h - mh - g);
    }
    var cap = capacity(sessions);
    var k = Math.min(cap, live.length);
    var best = null;
    while (k >= 1 && !best) {
      for (var cols = 1; cols <= k; cols++) {
        var rows = Math.ceil(k / cols);
        var tw = (area.w - g * (cols - 1)) / cols, th = (area.h - g * (rows - 1)) / rows;
        if (tw < minW || th < minH) continue;
        var score = Math.abs(Math.log((tw / th) / 2.4));
        if (!best || score < best.score) best = { cols: cols, rows: rows, tw: tw, th: th, score: score };
      }
      if (!best) k--;
    }
    if (!best || k < 1) { out.dots = live.length; return out; }
    out.main = main;
    var spill = live.length > k;
    var shown = spill ? k - 1 : k;
    for (var i = 0; i < k; i++) {
      var cx = i % best.cols, cy = Math.floor(i / best.cols);
      var rr = rect(area.x + cx * (best.tw + g), area.y + cy * (best.th + g), best.tw, best.th);
      if (i < shown) out.workers.push({ w: live[i], r: rr });
      else {
        var hidden = live.slice(shown);
        out.plus = { r: rr, n: hidden.length, look: hidden.some(function (w) { return w.state === 'quiet' || w.state === 'stuck'; }) };
      }
    }
    return out;
  }

  function sizes(u, compact) {
    return {
      head: Math.max(4.6 * u, compact ? 20 : 24), watch: Math.max(1.75 * u, 12), clock: Math.max(6.6 * u, 30), date: Math.max(1.75 * u, 12),
      title: Math.max(2.05 * u, 13), words: Math.max(2.45 * u, 13), detail: Math.max(1.55 * u, 11), small: Math.max(1.5 * u, 11), worker: Math.max(1.6 * u, 11.5)
    };
  }

  function layout(dev, model, style) {
    var W = dev.w, H = dev.h, sf = dev.safe;
    var u = dev.u || Math.min(H, W * 1.15) / 100;
    var compact = u < 6.4;
    var pad = Math.max(2.2 * u, 14), gap = Math.max(1.6 * u, 9);
    var x0 = sf[3] + pad, y0 = sf[0] + pad, x1 = W - sf[1] - pad, y1 = H - sf[2] - pad;
    var fs = sizes(u, compact);
    var L = { W: W, H: H, u: u, pad: pad, gap: gap, fs: fs, compact: compact, fold: dev.fold || null, tiles: {}, order: [] };
    var live = model.tiles;
    var n = live.length;
    var ribbonH = Math.max(1.0 * u, 7);
    var railsH = fs.small * 2.3;
    var showRails = style.rails;
    var showRibbon = style.ribbon;
    function finishTiles(area, aspect, cols) {
      var cells = placeGrid(n, area, aspect, gap, cols);
      live.forEach(function (t, i) {
        L.tiles[t.id] = cutCell(cells[i], t, n, u, gap, style.squads);
        L.order.push(t.id);
      });
    }
    if (style.solo) {
      L.mode = 'solo';
      var soloArea = rect(x0, y0, x1 - x0, y1 - y0);
      if (n) finishTiles(soloArea, soloArea.w / soloArea.h, null);
      return L;
    }
    if (dev.fold && dev.fold.axis === 'v') {
      L.mode = 'book';
      var left = rect(x0, y0, dev.fold.from - gap - x0, y1 - y0);
      var right = rect(dev.fold.to + gap, y0, x1 - dev.fold.to - gap, y1 - y0);
      L.headline = { x: left.x, y: left.y, w: left.w, size: fs.head * 0.86, lines: 2 };
      L.watch = { x: left.x, y: left.y + fs.head * 0.86 * 2.2, w: left.w };
      L.clock = { x: right.x + right.w, y: right.y, align: 'right', size: fs.clock * 0.9 };
      var top = y0 + fs.head * 0.86 * 2.2 + fs.watch * 1.6 + gap;
      var bottom = y1 - (showRibbon ? ribbonH + gap * 1.2 : 0);
      L.ribbon = showRibbon ? rect(left.x, y1 - ribbonH, left.w, ribbonH) : null;
      L.rails = showRails ? rect(right.x, y1 - railsH, right.w, railsH) : null;
      var railsCut = showRails ? railsH + gap * 1.2 : 0;
      var area = rect(x0, top, x1 - x0, Math.min(bottom, y1 - railsCut) - top);
      if (n) finishTiles(area, 1, [{ x: left.x, w: left.w }, { x: right.x, w: right.w }]);
      L.calm = { cx: left.x + left.w / 2, cy: top + (area.h) * 0.45, R: Math.min(left.w, area.h) * 0.22, tx: right.x, tw: right.w };
    } else if (dev.fold && dev.fold.axis === 'h') {
      L.mode = 'laptop';
      var upper = rect(x0, y0, x1 - x0, dev.fold.from - gap - y0);
      var base = rect(x0, dev.fold.to + gap, x1 - x0, y1 - dev.fold.to - gap);
      L.base = base;
      if (n) finishTiles(upper, upper.w / upper.h, null);
      L.clock = { x: base.x, y: base.y + gap, align: 'left', size: fs.clock * 1.7 };
      L.headline = { x: base.x + base.w * 0.5, y: base.y + gap + fs.clock * 0.2, w: base.w * 0.5, size: fs.head * 0.8, lines: 2 };
      L.watch = { x: base.x + base.w * 0.5, y: base.y + gap + fs.clock * 0.2 + fs.head * 0.8 * 2.3, w: base.w * 0.5 };
      var ry = base.y + gap + fs.clock * 1.7 * 1.25 + fs.date * 1.6 + gap * 2.2;
      L.ribbon = showRibbon ? rect(base.x, ry, base.w, ribbonH * 1.8) : null;
      ribbonH *= 1.8;
      L.rails = showRails ? rect(base.x, ry + ribbonH + gap * 1.4, base.w, railsH) : null;
      var cy = (showRails ? ry + ribbonH + gap * 1.4 + railsH : ry + ribbonH) + gap * 2;
      L.controls = rect(base.x, Math.max(cy, y1 - 52), base.w, 48);
      L.calm = { cx: upper.x + upper.w / 2, cy: upper.y + upper.h * 0.42, R: Math.min(upper.w, upper.h) * 0.2, tx: upper.x, tw: upper.w, ty: upper.y + upper.h * 0.78 };
    } else if (W / H >= 1.35 && H < 560) {
      L.mode = 'side';
      var colW = clamp((x1 - x0) * 0.33, 170, 330);
      L.clock = { x: x0, y: y0, align: 'left', size: Math.max(fs.clock * 1.3, 40) };
      var hy = y0 + L.clock.size * 1.05 + fs.date * 1.5 + gap;
      L.headline = { x: x0, y: hy, w: colW, size: Math.max(fs.head * 0.85, 18), lines: 3 };
      L.watch = { x: x0, y: hy + Math.max(fs.head * 0.85, 18) * 3.3, w: colW };
      L.ribbon = showRibbon ? rect(x0, y1 - ribbonH, colW, ribbonH) : null;
      L.rails = null;
      var sideArea = rect(x0 + colW + gap * 2, y0, x1 - x0 - colW - gap * 2, y1 - y0);
      if (n) finishTiles(sideArea, sideArea.w / sideArea.h, null);
      L.calm = { cx: sideArea.x + sideArea.w / 2, cy: sideArea.y + sideArea.h * 0.42, R: Math.min(sideArea.w, sideArea.h) * 0.22, tx: sideArea.x, tw: sideArea.w, ty: sideArea.y + sideArea.h * 0.78 };
    } else {
      L.mode = 'stack';
      var narrow = W < 600;
      var clockW = narrow ? fs.clock * 2.4 : fs.clock * 3.1;
      L.clock = { x: x1, y: y0 - fs.clock * 0.08, align: 'right', size: narrow ? fs.clock * 0.82 : fs.clock };
      L.headline = { x: x0, y: y0, w: x1 - x0 - clockW - gap, size: narrow ? fs.head * 0.86 : fs.head, lines: narrow ? 2 : 1 };
      var hh = L.headline.size * (L.headline.lines === 2 ? 2.2 : 1.16);
      L.watch = { x: x0, y: y0 + hh + u * 0.3, w: x1 - x0 - (narrow ? 0 : clockW) };
      var topY = y0 + Math.max(hh + fs.watch * 1.5, L.clock.size * 1.05 + fs.date * 1.5) + gap * 1.4;
      var railsRoom = showRails && !(narrow && H < 700) ? railsH + gap : 0;
      L.rails = railsRoom ? rect(x0, y1 - railsH, x1 - x0, railsH) : null;
      L.ribbon = showRibbon ? rect(x0, y1 - railsRoom - ribbonH, x1 - x0, ribbonH) : null;
      var botY = y1 - railsRoom - (showRibbon ? ribbonH + gap * 1.4 : 0);
      var stackArea = rect(x0, topY, x1 - x0, botY - topY);
      if (n) finishTiles(stackArea, W / H, null);
      L.calm = { cx: stackArea.x + stackArea.w / 2, cy: stackArea.y + stackArea.h * 0.4, R: Math.min(stackArea.w, stackArea.h) * 0.2, tx: stackArea.x, tw: stackArea.w, ty: stackArea.y + stackArea.h * 0.74 };
    }
    return L;
  }

  var GROUND_VS = '#version 300 es\nconst vec2 P[3]=vec2[3](vec2(-1.,-1.),vec2(3.,-1.),vec2(-1.,3.));\nvoid main(){gl_Position=vec4(P[gl_VertexID],0.,1.);}';
  var GROUND_FS = [
    '#version 300 es',
    'precision highp float;',
    'out vec4 o;',
    'uniform vec4 uVP; uniform vec2 uSize; uniform float uScale; uniform float uU; uniform vec2 uShift;',
    'uniform vec3 uGround, uDeep, uText, uTint, uVig;',
    'uniform float uTintA, uVigA, uDim, uTime, uAurora, uGridA;',
    'uniform int uNL; uniform vec4 uLR[8]; uniform vec4 uLI[8];',
    'uniform int uNR; uniform vec4 uRR[12]; uniform vec4 uRI[12]; uniform vec4 uRP[12];',
    'float sdr(vec2 p, vec2 c, vec2 hs, float r){ vec2 q=abs(p-c)-hs+r; return length(max(q,0.))+min(max(q.x,q.y),0.)-r; }',
    'float h21(vec2 p){ p=fract(p*vec2(123.34,456.21)); p+=dot(p,p+45.32); return fract(p.x*p.y); }',
    'float vn(vec2 p){ vec2 i=floor(p), f=fract(p); vec2 w=f*f*(3.-2.*f); return mix(mix(h21(i),h21(i+vec2(1.,0.)),w.x), mix(h21(i+vec2(0.,1.)),h21(i+vec2(1.,1.)),w.x), w.y); }',
    'void main(){',
    '  vec2 l = gl_FragCoord.xy - uVP.xy;',
    '  vec2 p = vec2(l.x, uVP.w - l.y) / uScale - uShift;',
    '  vec2 uv = clamp(p / uSize, 0., 1.);',
    '  vec3 col = mix(uDeep, uGround, uv.y);',
    '  float m = max(uSize.x, uSize.y);',
    '  float bd = length(p - vec2(.5*uSize.x, .42*uSize.y)) / (.7*m);',
    '  col = mix(col, uTint, uTintA * max(0., 1. - bd));',
    '  if (uAurora > 0.) {',
    '    vec2 q = p / (uU*34.);',
    '    float n = vn(q + vec2(uTime*.021, -uTime*.013)) * .62 + vn(q*2.3 - vec2(uTime*.034, uTime*.017)) * .38;',
    '    float b = smoothstep(.5, .72, n) * (1. - smoothstep(.72, .92, n));',
    '    col += uTint * b * .06 * uAurora * (1. - uv.y*.45);',
    '  }',
    '  float gs = max(24., uU*6.);',
    '  vec2 gd = abs(fract((p - gs*.5) / gs + .5) - .5) * gs * uScale;',
    '  float line = max(1. - smoothstep(0., 1., gd.x), 1. - smoothstep(0., 1., gd.y));',
    '  col = mix(col, uText, uGridA * line);',
    '  for (int i=0;i<8;i++){ if(i>=uNL) break; vec4 r=uLR[i]; float d=sdr(p, r.xy+r.zw*.5, r.zw*.5, uU*1.6); if(d>0.) col += uLI[i].rgb*uLI[i].a*exp(-d/(uU*7.)); }',
    '  for (int i=0;i<12;i++){ if(i>=uNR) break; vec4 r=uRR[i]; float d=sdr(p, r.xy+r.zw*.5, r.zw*.5, uRP[i].z); float b=(d-uRP[i].x)/max(uRP[i].y,.001); col += uRI[i].rgb*uRI[i].a*exp(-b*b)*step(0.,d); }',
    '  float e = min(min(p.x, uSize.x-p.x), min(p.y, uSize.y-p.y));',
    '  float v = clamp(1. - e / (.13*min(uSize.x,uSize.y)), 0., 1.);',
    '  col = mix(col, uVig, uVigA * v * v);',
    '  col *= uDim;',
    '  col += (h21(gl_FragCoord.xy) - .5) / 255.;',
    '  o = vec4(col, 1.);',
    '}'
  ].join('\n');

  var QUAD_HEAD = [
    '#version 300 es',
    'uniform vec4 uWorld; uniform vec2 uCanvas; uniform vec2 uShift;',
    'vec4 place(vec2 p){ vec2 px = uWorld.xy + (p + uShift) * uWorld.z; return vec4(px.x/uCanvas.x*2.-1., 1.-px.y/uCanvas.y*2., 0., 1.); }'
  ].join('\n');

  var PLATE_VS = QUAD_HEAD + '\n' + [
    'layout(location=0) in vec2 aCorner;',
    'layout(location=1) in vec4 aRect; layout(location=2) in vec4 aInk; layout(location=3) in vec4 aP1; layout(location=4) in vec4 aP2;',
    'out vec2 vP; out vec4 vRect; out vec4 vInk; out vec4 vP1; out vec4 vP2;',
    'void main(){ float m=3.; vec2 p=aRect.xy-m+aCorner*(aRect.zw+2.*m); vP=p; vRect=aRect; vInk=aInk; vP1=aP1; vP2=aP2; gl_Position=place(p); }'
  ].join('\n');

  var PLATE_FS = [
    '#version 300 es',
    'precision highp float;',
    'in vec2 vP; in vec4 vRect; in vec4 vInk; in vec4 vP1; in vec4 vP2;',
    'uniform vec3 uText; uniform vec3 uDimInk; uniform float uDim; uniform float uU; uniform float uScale;',
    'out vec4 o;',
    'float sdr(vec2 p, vec2 c, vec2 hs, float r){ vec2 q=abs(p-c)-hs+r; return length(max(q,0.))+min(max(q.x,q.y),0.)-r; }',
    'void main(){',
    '  vec2 c=vRect.xy+vRect.zw*.5; vec2 hs=vRect.zw*.5; float r=min(vP1.x, min(hs.x,hs.y));',
    '  float d=sdr(vP,c,hs,r); float aa=.8/uScale;',
    '  float inside=1.-smoothstep(-aa,aa,d);',
    '  float ty=clamp((vP.y-vRect.y)/max(vRect.w,1.),0.,1.);',
    '  vec3 col=vec3(0.); float a=0.;',
    '  float g=mix(.085,.03,ty); col+=uText*g; a+=g;',
    '  float wa=vP1.y*1.6*max(0.,1.-ty/.9); col+=vInk.rgb*wa; a+=wa*.45;',
    '  col+=vInk.rgb*vP2.y; a+=vP2.y*.45;',
    '  float sh=smoothstep(-1.8*uU,0.,d)*vP2.z; col+=vec3(1.)*sh*.045; a+=sh*.02;',
    '  float rimY=abs(vP.y-(vRect.y+1.2/uScale)); float rim=(1.-smoothstep(0.,1.2/uScale,rimY))*step(vRect.x+r,vP.x)*step(vP.x,vRect.x+vRect.z-r);',
    '  col+=vec3(1.)*rim*.1; a+=rim*.05;',
    '  if(vP2.x>.5){ float s=fract((vP.x+vP.y)/(1.3*uU)); float ln=1.-smoothstep(.06,.12,abs(s-.5)); col+=uDimInk*.2*ln; a+=.1*ln; }',
    '  col*=inside; a*=inside;',
    '  float bw=max(vP1.w,1./uScale); float bnd=1.-smoothstep(bw*.5-aa*.5,bw*.5+aa*.5,abs(d+bw*.5));',
    '  col+=vInk.rgb*vP1.z*bnd; a+=vP1.z*bnd;',
    '  float op=vInk.a*uDim; o=vec4(col*op, clamp(a,0.,1.)*op);',
    '}'
  ].join('\n');

  var GLYPH_VS = QUAD_HEAD + '\n' + [
    'layout(location=0) in vec2 aCorner;',
    'layout(location=1) in vec4 aC; layout(location=2) in vec4 aInk; layout(location=3) in vec4 aK; layout(location=4) in vec4 aX;',
    'out vec2 vQ; out vec4 vInk; out vec4 vK; out vec4 vX; out float vS;',
    'void main(){ vec2 q=(aCorner*2.-1.)*aC.w; vQ=q; vInk=aInk; vK=aK; vX=aX; vS=aC.z; gl_Position=place(aC.xy+q*aC.z); }'
  ].join('\n');

  var GLYPH_FS = [
    '#version 300 es',
    'precision highp float;',
    'in vec2 vQ; in vec4 vInk; in vec4 vK; in vec4 vX; in float vS;',
    'uniform float uScale; uniform float uDim; uniform vec3 uText;',
    'out vec4 o;',
    'float seg(vec2 p, vec2 a, vec2 b){ vec2 pa=p-a, ba=b-a; float h=clamp(dot(pa,ba)/dot(ba,ba),0.,1.); return length(pa-ba*h); }',
    'float band(float d, float w, float aa){ return 1.-smoothstep(w*.5-aa, w*.5+aa, abs(d)); }',
    'float fill(float d, float aa){ return 1.-smoothstep(-aa, aa, d); }',
    'void main(){',
    '  int k=int(vK.x+.5); vec2 q=vQ; float r=length(q); float aa=1./max(1.,vS*uScale);',
    '  vec3 ink=vInk.rgb; vec3 c=vec3(0.); float a=0.;',
    '  if(k==0){ float R=vK.y; float core=fill(r-R,aa); float hl=clamp(1.-length(q-vec2(-.35*R,-.4*R))/(R*1.1),0.,1.);',
    '    vec3 cc=mix(ink,vec3(1.),.3*hl*hl); float halo=exp(-max(r-R,0.)/(R*.6))*vK.z*(1.-core); c=cc*core+ink*halo*.55; a=core+halo*.3; }',
    '  else if(k==1){ float b=band(r-vK.y,vK.z,aa); float ang=atan(q.x,-q.y); float t=(ang<0.?ang+6.2831853:ang)/6.2831853;',
    '    float on=1.-smoothstep(vK.w-.003,vK.w+.003,t); c=ink*b*on+uText*b*vX.x*(1.-on); a=b*on+b*vX.x*(1.-on); }',
    '  else if(k==2){ float b=band(r-vK.y,vK.z,aa); float f=fract(atan(q.y,q.x)/6.2831853*14.+vK.w); float dsh=smoothstep(0.,.06,f)*(1.-smoothstep(.56,.62,f)); c=ink*b*dsh; a=b*dsh; }',
    '  else if(k==3){ float b=band(r-vK.y,vK.z,aa)*.75; vec2 dp=vec2(sin(vK.w),-cos(vK.w))*vK.y; float dt=fill(length(q-dp)-vX.x,aa); float v=max(b,dt); c=ink*v; a=v; }',
    '  else if(k==4){ float d=min(seg(q,vec2(-.26,.0),vec2(-.07,.19)),seg(q,vec2(-.07,.19),vec2(.27,-.18))); float s=band(d,.1,aa); float ring=band(r-.43,.045,aa)*.4; float v=max(s,ring); c=ink*v; a=v; }',
    '  else if(k==5){ float d=min(seg(q,vec2(-.19,-.19),vec2(.19,.19)),seg(q,vec2(-.19,.19),vec2(.19,-.19))); float s=band(d,.1,aa); float ring=band(r-.43,.045,aa)*.4; float v=max(s,ring); c=ink*v; a=v; }',
    '  else if(k==6){ vec2 dq=abs(q)-vec2(.17); float d=length(max(dq,0.))+min(max(dq.x,dq.y),0.)-.03; float s=fill(d,aa)*.85; float ring=band(r-.43,.045,aa)*.35; float v=max(s,ring); c=ink*v; a=v; }',
    '  else if(k==7){ float b=(r-vK.y)/max(vK.z,.001); float g=exp(-b*b); c=ink*g; a=g; }',
    '  else if(k==8){ float g=exp(-(r*r)/max(vK.y*vK.y,.0001)); c=ink*g; a=g; }',
    '  else if(k==9){ float dsk=fill(r-vK.y,aa); float s=fract((q.x+q.y)*5.); float h=smoothstep(0.,.08,s)*(1.-smoothstep(.42,.5,s)); float e=band(r-vK.y,.05,aa); float v=max(dsk*h*.5,e*.8); c=ink*v; a=v; }',
    '  else if(k==10){ float dsk=fill(r-vK.y,aa)*.9; c=ink*dsk; a=dsk; }',
    '  float op=vInk.a*uDim; o=vec4(c*op, a*op);',
    '}'
  ].join('\n');

  var POINT_VS = QUAD_HEAD + '\n' + [
    'layout(location=0) in vec4 aP; layout(location=1) in vec4 aCol;',
    'out vec4 vC; out float vCore;',
    'void main(){ gl_Position=place(aP.xy); gl_PointSize=max(1.,aP.z*uWorld.z); vC=aCol; vCore=aP.w; }'
  ].join('\n');

  var POINT_FS = [
    '#version 300 es',
    'precision highp float;',
    'in vec4 vC; in float vCore; uniform float uDim; out vec4 o;',
    'void main(){ float d=length(gl_PointCoord-.5)*2.; float core=1.-smoothstep(vCore*.75,vCore,d); float halo=(1.-smoothstep(vCore,1.,d))*.22;',
    '  float a=max(core,halo)*vC.a*uDim; if(a<.002) discard; o=vec4(vC.rgb*a,a); }'
  ].join('\n');

  function compile(gl, vs, fs) {
    function sh(type, src) {
      var s = gl.createShader(type);
      gl.shaderSource(s, src);
      gl.compileShader(s);
      if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(s) + '\n' + src);
      return s;
    }
    var p = gl.createProgram();
    gl.attachShader(p, sh(gl.VERTEX_SHADER, vs));
    gl.attachShader(p, sh(gl.FRAGMENT_SHADER, fs));
    gl.linkProgram(p);
    if (!gl.getProgramParameter(p, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(p));
    var u = {};
    var count = gl.getProgramParameter(p, gl.ACTIVE_UNIFORMS);
    for (var i = 0; i < count; i++) {
      var info = gl.getActiveUniform(p, i);
      var name = info.name.replace(/\[0\]$/, '');
      u[name] = gl.getUniformLocation(p, info.name);
    }
    return { p: p, u: u };
  }

  function Batch(gl, floatsPer, layoutSpec, max, instanced) {
    this.gl = gl; this.per = floatsPer; this.max = max; this.n = 0;
    this.data = new Float32Array(floatsPer * max);
    this.vao = gl.createVertexArray();
    gl.bindVertexArray(this.vao);
    if (instanced) {
      var corner = gl.createBuffer();
      gl.bindBuffer(gl.ARRAY_BUFFER, corner);
      gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([0, 0, 1, 0, 0, 1, 1, 1]), gl.STATIC_DRAW);
      gl.enableVertexAttribArray(0);
      gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 0, 0);
    }
    this.buf = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, this.buf);
    gl.bufferData(gl.ARRAY_BUFFER, this.data.byteLength, gl.DYNAMIC_DRAW);
    var offset = 0;
    for (var i = 0; i < layoutSpec.length; i++) {
      var loc = layoutSpec[i][0], size = layoutSpec[i][1];
      gl.enableVertexAttribArray(loc);
      gl.vertexAttribPointer(loc, size, gl.FLOAT, false, floatsPer * 4, offset * 4);
      if (instanced) gl.vertexAttribDivisor(loc, 1);
      offset += size;
    }
    gl.bindVertexArray(null);
    this.instanced = instanced;
  }
  Batch.prototype.reset = function () { this.n = 0; };
  Batch.prototype.push = function (arr) {
    if (this.n >= this.max) return;
    this.data.set(arr, this.n * this.per);
    this.n++;
  };
  Batch.prototype.draw = function () {
    if (!this.n) return;
    var gl = this.gl;
    gl.bindVertexArray(this.vao);
    gl.bindBuffer(gl.ARRAY_BUFFER, this.buf);
    gl.bufferSubData(gl.ARRAY_BUFFER, 0, this.data, 0, this.n * this.per);
    if (this.instanced) gl.drawArraysInstanced(gl.TRIANGLE_STRIP, 0, 4, this.n);
    else gl.drawArrays(gl.POINTS, 0, this.n);
    gl.bindVertexArray(null);
  };

  function Motes(count, seed) {
    this.count = count;
    this.x = new Float32Array(count); this.y = new Float32Array(count);
    this.hd = new Float32Array(count); this.sz = new Float32Array(count); this.ph = new Float32Array(count);
    this.tx = new Float32Array(count * 4); this.ty = new Float32Array(count * 4);
    this.seed = seed >>> 0 || 0x9e3779b9;
    for (var i = 0; i < count; i++) this.respawn(i, true);
  }
  Motes.prototype.rnd = function () {
    var s = this.seed;
    s ^= s << 13; s >>>= 0; s ^= s >>> 17; s ^= s << 5; s >>>= 0;
    this.seed = s;
    return (s % 10000) / 10000;
  };
  Motes.prototype.respawn = function (i, anywhere) {
    this.x[i] = anywhere ? this.rnd() : (this.rnd() < 0.5 ? -0.01 : 1.01);
    this.y[i] = this.rnd();
    this.hd[i] = this.rnd() * TAU;
    this.sz[i] = 0.18 + this.rnd() * 0.32;
    this.ph[i] = this.rnd() * TAU;
    for (var k = 0; k < 4; k++) { this.tx[i * 4 + k] = this.x[i]; this.ty[i * 4 + k] = this.y[i]; }
  };
  Motes.prototype.speed = function (mood) { return mood === 'calm' ? 0.003 : mood === 'busy' ? 0.022 : mood === 'attention' ? 0.03 : 0.009; };
  Motes.prototype.step = function (dt, mood, target, slow, aspect) {
    var pace = this.speed(mood) * slow * dt;
    for (var i = 0; i < this.count; i++) {
      var dx = Math.cos(this.hd[i]), dy = Math.sin(this.hd[i]);
      if (mood === 'busy') { dx += 1.4; dy -= 0.5; }
      if (target && (mood === 'attention' || mood === 'alarm')) {
        var toX = (target.x - this.x[i]) * aspect, toY = target.y - this.y[i];
        var dist = Math.max(0.001, Math.sqrt(toX * toX + toY * toY));
        if (dist < 0.035) { this.respawn(i, false); continue; }
        dx = dx * 0.35 + toX / dist; dy = dy * 0.35 + toY / dist;
      }
      for (var k = 3; k > 0; k--) { this.tx[i * 4 + k] = this.tx[i * 4 + k - 1]; this.ty[i * 4 + k] = this.ty[i * 4 + k - 1]; }
      this.tx[i * 4] = this.x[i]; this.ty[i * 4] = this.y[i];
      this.x[i] += dx * pace / aspect; this.y[i] += dy * pace;
      this.hd[i] += (this.rnd() - 0.5) * 0.4 * dt;
      if (this.x[i] < -0.02) { this.x[i] = 1.02; this.resetTrail(i); } else if (this.x[i] > 1.02) { this.x[i] = -0.02; this.resetTrail(i); }
      if (this.y[i] < -0.02) { this.y[i] = 1.02; this.resetTrail(i); } else if (this.y[i] > 1.02) { this.y[i] = -0.02; this.resetTrail(i); }
    }
  };
  Motes.prototype.resetTrail = function (i) { for (var k = 0; k < 4; k++) { this.tx[i * 4 + k] = this.x[i]; this.ty[i * 4 + k] = this.y[i]; } };

  var DEFAULT_STYLE = {
    effects: 'subtle', field: 'motes', light: true, reduced: false, dim: false, night: false,
    clock: true, ribbon: true, rails: true, squads: true, theme: 'rosepine',
    events: { steps: true, agents: true, finish: true, asks: true, failures: true, retries: true, compaction: true, joins: true }
  };

  function fmtAge(s) {
    s = Math.max(0, Math.floor(s));
    if (s < 60) return s + 's';
    var m = Math.floor(s / 60);
    if (m < 60) return m + 'm ' + (s % 60 < 10 ? '0' : '') + (s % 60) + 's';
    var h = Math.floor(m / 60);
    return h + 'h ' + (m % 60 < 10 ? '0' : '') + (m % 60) + 'm';
  }
  function fmtShort(s) {
    s = Math.max(0, Math.floor(s));
    if (s < 60) return s + 's';
    var m = Math.floor(s / 60);
    return m < 60 ? m + 'm' : Math.floor(m / 60) + 'h ' + (m % 60) + 'm';
  }

  function Engine(glCanvas, textCanvas, opts) {
    this.opts = opts || {};
    this.glc = glCanvas; this.txc = textCanvas;
    this.style = JSON.parse(JSON.stringify(DEFAULT_STYLE));
    this.setStyle(this.opts.style || {}, true);
    this.worlds = [];
    this.running = false;
    this.visible = true;
    this.t = performance.now() / 1000;
    this.lastDraw = 0;
    this.fpsCount = 0; this.fpsAt = this.t; this.fps = 0;
    this.onStats = this.opts.onStats || null;
    var gl = glCanvas.getContext('webgl2', { alpha: false, antialias: false, premultipliedAlpha: true, powerPreference: 'low-power' });
    this.gl = gl;
    this.ctx = textCanvas.getContext('2d');
    if (!gl) { this.failed = 'WebGL2 is not available here'; return; }
    try {
      this.pg = compile(gl, GROUND_VS, GROUND_FS);
      this.pp = compile(gl, PLATE_VS, PLATE_FS);
      this.pq = compile(gl, GLYPH_VS, GLYPH_FS);
      this.pt = compile(gl, POINT_VS, POINT_FS);
    } catch (e) { this.failed = String(e.message || e); return; }
    this.emptyVao = gl.createVertexArray();
    this.plates = new Batch(gl, 16, [[1, 4], [2, 4], [3, 4], [4, 4]], 96, true);
    this.glyphs = new Batch(gl, 16, [[1, 4], [2, 4], [3, 4], [4, 4]], 512, true);
    this.fx = new Batch(gl, 16, [[1, 4], [2, 4], [3, 4], [4, 4]], 256, true);
    this.points = new Batch(gl, 8, [[0, 4], [1, 4]], 2400, false);
    var self = this;
    this.ro = new ResizeObserver(function () { self.resize(); });
    this.ro.observe(glCanvas);
    if (window.IntersectionObserver) {
      this.io = new IntersectionObserver(function (es) { self.visible = es[0] ? es[0].isIntersecting : true; }, { threshold: 0 });
      this.io.observe(glCanvas);
    }
    this.onPointer = this.pointer.bind(this);
    textCanvas.addEventListener('pointerdown', this.onPointer);
    textCanvas.addEventListener('pointerup', this.onPointer);
    textCanvas.addEventListener('pointercancel', this.onPointer);
    textCanvas.addEventListener('pointermove', this.onPointer);
    this.resize();
  }

  Engine.prototype.setStyle = function (s, silent) {
    var st = this.style;
    Object.keys(s).forEach(function (k) {
      if (k === 'events') Object.assign(st.events, s.events);
      else st[k] = s[k];
    });
    this.P = palette(st.theme, st.night);
    if (!silent) this.worlds.forEach(function (w) { w.dirty = true; });
  };

  Engine.prototype.resize = function () {
    var dpr = Math.min(window.devicePixelRatio || 1, 2);
    var r = this.glc.getBoundingClientRect();
    var cw = Math.max(1, this.glc.clientWidth || r.width), ch = Math.max(1, this.glc.clientHeight || r.height);
    var W = Math.round(cw * dpr), H = Math.round(ch * dpr);
    if (this.glc.width !== W || this.glc.height !== H) { this.glc.width = W; this.glc.height = H; }
    if (this.txc.width !== W || this.txc.height !== H) { this.txc.width = W; this.txc.height = H; }
    this.dpr = dpr; this.cssW = cw; this.cssH = ch;
    if (this.opts.arrange) this.opts.arrange(this, cw, ch);
    var self = this;
    this.worlds.forEach(function (w) { self.fit(w); });
  };

  Engine.prototype.fit = function (w) {
    var box = w.box || { x: 0, y: 0, w: this.cssW, h: this.cssH };
    var s = Math.min(box.w / w.dev.w, box.h / w.dev.h);
    w.scale = s * this.dpr;
    w.ox = (box.x + (box.w - w.dev.w * s) / 2) * this.dpr;
    w.oy = (box.y + (box.h - w.dev.h * s) / 2) * this.dpr;
    w.dirty = true;
  };

  Engine.prototype.addWorld = function (dev, sceneName, o) {
    o = o || {};
    var area = dev.w * dev.h;
    var w = {
      dev: dev, box: o.box || null, model: null, L: null, fx: [], motes: new Motes(Math.round(clamp(area / 11000, 18, 96)), 1234567 + this.worlds.length * 7919),
      chrome: o.chrome !== false, autoplay: !!o.autoplay, script: o.script || null, scriptAt: 0, clockT: 0, moodInk: null, vig: 0,
      hold: null, peek: null, controlsUntil: 0, ticks: o.ticks !== false, quietEvery: o.quietEvery || 60, loop: o.loop || 0, hint: null, dimmed: 0, morph: null, dirty: true, label: o.label || '', alwaysSquads: o.alwaysSquads
    };
    this.worlds.push(w);
    this.fit(w);
    this.loadScene(w, sceneName || 'busy');
    return w;
  };

  Engine.prototype.loadScene = function (w, name) {
    var t = this.t;
    var m = scene(name);
    m.tiles.forEach(function (tl) { prepTile(tl, t); });
    m.recent.forEach(function (r) { r.at = t - r.ago; });
    w.model = m;
    w.sceneName = name;
    w.scriptAt = t;
    w.fx.length = 0;
    w.hold = null; w.peek = null;
    w.cursor = 0;
    w.L = null; w.dirty = true;
    w.ribbon = ribbonFor(m.seed, name);
  };

  function prepTile(tl, t) {
    tl.startedAt = t - (tl.started || 0);
    tl.sinceAt = t - (tl.since || 0);
    tl.beat = [];
    var seed = tl.id.length * 13 + tl.title.length;
    for (var i = 0; i < 60; i++) {
      seed = (seed * 1103515245 + 12345) & 0x7fffffff;
      var busy = tl.state === 'working' || tl.state === 'retrying' || tl.state === 'needs';
      tl.beat.push(busy && (seed % 100) < 46 ? 1 + (seed % 4) : 0);
    }
    if (tl.state === 'quiet' || tl.state === 'away' || tl.state === 'stuck' || tl.state === 'failed') for (var j = 30; j < 60; j++) tl.beat[j] = 0;
    tl.beatAt = Math.floor(t);
    tl.pulse = 0;
    tl.ctxShown = tl.ctx;
    tl.nextTick = t + 0.8 + Math.random() * 2.5;
    tl.phraseAt = 0;
    if (!tl.history) {
      tl.history = [];
      var ph = tl.phrases || [];
      for (var h = ph.length - 1; h >= 1 && tl.history.length < 3; h--) if (ph[h] !== tl.words) tl.history.push(past(ph[h]));
    }
    tl.workers.forEach(function (wk) { wk.startedAt = t - wk.started; wk.bornAt = t - 99; if (wk.quietFor) wk.quietAt = t - wk.quietFor; });
  }

  function ribbonFor(seed, name) {
    var out = [], s = seed * 7919 + name.length;
    for (var i = 0; i < 60; i++) {
      s = (s * 1103515245 + 12345) & 0x7fffffff;
      var v = s % 100;
      var st = v < 38 ? 'working' : v < 52 ? 'thinking' : v < 58 ? 'needs' : v < 62 ? 'done' : v < 64 ? 'failed' : 'idle';
      if (name === 'calm' && i > 40) st = 'idle';
      if (i >= 9 && i <= 15) st = 'unseen';
      out.push(st);
    }
    return out;
  }

  Engine.prototype.setDevice = function (w, dev, animate) {
    var old = w.L;
    var oldDev = w.dev;
    w.dev = dev;
    w.motes = new Motes(Math.round(clamp(dev.w * dev.h / 11000, 18, 96)), 99173);
    this.fit(w);
    w.L = null;
    if (animate && old) {
      var from = {};
      Object.keys(old.tiles).forEach(function (id) {
        var c = old.tiles[id].cell;
        from[id] = { x: c.x / oldDev.w, y: c.y / oldDev.h, w: c.w / oldDev.w, h: c.h / oldDev.h };
      });
      w.morph = { from: from, t0: this.t, dur: 0.6 };
    }
    w.dirty = true;
  };

  Engine.prototype.start = function () {
    if (this.running || this.failed) return;
    this.running = true;
    var self = this;
    var loop = function (now) {
      if (!self.running) return;
      self.raf = requestAnimationFrame(loop);
      self.frame(now / 1000);
    };
    this.raf = requestAnimationFrame(loop);
  };
  Engine.prototype.stop = function () { this.running = false; if (this.raf) cancelAnimationFrame(this.raf); };
  Engine.prototype.destroy = function () {
    this.stop();
    if (this.ro) this.ro.disconnect();
    if (this.io) this.io.disconnect();
    this.txc.removeEventListener('pointerdown', this.onPointer);
    this.txc.removeEventListener('pointerup', this.onPointer);
    this.txc.removeEventListener('pointercancel', this.onPointer);
    this.txc.removeEventListener('pointermove', this.onPointer);
  };

  Engine.prototype.amp = function () { return this.style.effects === 'off' ? 0 : this.style.effects === 'lively' ? 1.6 : 1; };
  Engine.prototype.animated = function () { return !this.style.reduced; };

  Engine.prototype.addFx = function (w, kind, o) {
    var a = this.amp();
    if (!a && kind !== 'drain' && kind !== 'appear') return;
    if (w.fx.length > 40) w.fx.shift();
    if (this.style.reduced && /^(spark|thread|dissolve|gather|scatter)$/.test(kind)) return;
    var e = Object.assign({ kind: kind, t0: this.t, dur: 1.2, amp: a }, o);
    if (this.style.reduced && kind !== 'drain') { e.kind = 'fade'; e.dur = 0.8; }
    if (!e.particles) e.particles = [];
    w.fx.push(e);
    return e;
  };

  function findTile(w, id) { for (var i = 0; i < w.model.tiles.length; i++) if (w.model.tiles[i].id === id) return w.model.tiles[i]; return null; }

  Engine.prototype.event = function (w, kind, id, extra) {
    var t = this.t, ev = this.style.events, self = this;
    var tl = id ? findTile(w, id) : null;
    extra = extra || {};
    switch (kind) {
      case 'tick':
        if (!tl) return;
        tl.beat[59] = Math.min(6, tl.beat[59] + 1);
        if (tl.phrases && tl.phrases.length && tl.state === 'working') {
          tl.phraseAt = (tl.phraseAt + 1) % tl.phrases.length;
          var nextWords = tl.phrases[tl.phraseAt];
          if (nextWords !== tl.words) {
            tl.history = tl.history || [];
            var was = past(tl.words);
            tl.history = tl.history.filter(function (x) { return x !== was; });
            tl.history.unshift(was);
            if (tl.history.length > 5) tl.history.pop();
          }
          tl.words = nextWords;
        }
        if (ev.steps && this.amp()) { tl.pulse = 1; this.addFx(w, 'spark', { tile: id, dur: 0.45 }); }
        tl.ctx = Math.min(0.97, tl.ctx + 0.004);
        break;
      case 'spawn':
        if (!tl) return;
        var names = ['Explore', 'Plan', 'Review', 'Docs sweep', 'Test runner', 'Lint sweep', 'Footer styles', 'Link check'];
        var used = tl.workers.map(function (x) { return x.name; });
        var name = extra.name || names.filter(function (n) { return used.indexOf(n) < 0; })[0] || 'Helper';
        var wk = worker(id + '-' + Math.floor(t * 10), name, 'working', extra.words || 'Getting its bearings', { todo: extra.todo || null });
        wk.startedAt = t; wk.bornAt = t;
        tl.workers.push(wk);
        if (ev.agents) this.addFx(w, 'thread', { tile: id, worker: wk.id, dur: 1.1 });
        w.dirty = true;
        break;
      case 'release':
        if (!tl) return;
        var wr = extra.worker ? tl.workers.filter(function (x) { return x.id === extra.worker; })[0] : tl.workers.filter(function (x) { return x.state === 'working' && !x.ended; })[0];
        if (!wr) return;
        wr.state = 'finished'; wr.ended = t; wr.words = 'Finished';
        if (ev.agents) this.addFx(w, 'dissolve', { tile: id, worker: wr.id, dur: 1.5 });
        break;
      case 'finish':
        if (!tl) return;
        tl.state = 'done'; tl.sinceAt = t; tl.words = 'Done in ' + fmtShort(t - tl.startedAt) + ' · ' + (14 + tl.title.length % 9) + ' steps';
        tl.workers.forEach(function (x) { x.gone = true; });
        if (ev.finish) { this.addFx(w, 'exhale', { tile: id, dur: 1.8 }); this.addFx(w, 'ripple', { tile: id, dur: 2.2, strength: 0.12 }); }
        w.dirty = true;
        break;
      case 'ask':
        if (!tl) return;
        tl.state = 'needs'; tl.sinceAt = t; tl.lead = 'Wants to run'; tl.cmd = extra.cmd || 'git push --force-with-lease origin release/1.80';
        tl.words = extra.words || 'Force-uploading the changes to release/1.80';
        if (ev.asks) { this.addFx(w, 'knock', { tile: id, dur: 1.3 }); this.addFx(w, 'knock', { tile: id, dur: 1.3, t0: t + 0.34 }); }
        w.dirty = true;
        break;
      case 'appearAll':
        w.model.tiles.forEach(function (x) { x.bornAt = t; if (ev.joins) self.addFx(w, 'gather', { tile: x.id, dur: 1.3 }); });
        break;
      case 'approve':
        if (!tl || (tl.state !== 'needs' && tl.state !== 'overdue')) return;
        tl.state = 'working'; tl.sinceAt = t; tl.cmd = ''; tl.lead = '';
        tl.words = extra.words || (tl.phrases && tl.phrases[0]) || 'Running it';
        this.addFx(w, 'approved', { tile: id, dur: 1.4 });
        w.dirty = true;
        break;
      case 'fail':
        if (!tl) return;
        tl.state = 'failed'; tl.sinceAt = t; tl.words = extra.words || 'The build failed'; tl.detail = extra.detail || 'swift build exited with status 1';
        tl.workers.forEach(function (x) { x.gone = true; });
        if (ev.failures) { this.addFx(w, 'fracture', { tile: id, dur: 1.6 }); this.addFx(w, 'ripple', { tile: id, dur: 2.4, strength: 0.1, ink: 'failed' }); }
        w.dirty = true;
        break;
      case 'retry':
        if (!tl) return;
        tl.state = 'retrying'; tl.attempt = (tl.attempt || 1) + 1; tl.sinceAt = t; tl.words = 'The AI service is busy, trying again';
        if (ev.retries) this.addFx(w, 'pulse', { tile: id, dur: 1.2, ink: 'needs' });
        break;
      case 'quiet':
        if (!tl) return;
        tl.state = 'quiet'; tl.sinceAt = t - 46; tl.words = 'Quiet for 46s';
        break;
      case 'resume':
        if (!tl) return;
        tl.state = 'working'; tl.sinceAt = t; tl.words = (tl.phrases && tl.phrases[0]) || 'Working';
        if (ev.retries) this.addFx(w, 'pulse', { tile: id, dur: 1.0, ink: 'working' });
        break;
      case 'compact':
        if (!tl) return;
        tl.ctxFrom = tl.ctx; tl.ctx = 0.19;
        if (ev.compaction) this.addFx(w, 'drain', { tile: id, dur: 2.6, from: tl.ctxFrom, to: 0.19 });
        else tl.ctxShown = tl.ctx;
        break;
      case 'away':
        if (!tl) return;
        if (tl.state === 'away') { tl.state = tl.prevState || 'working'; tl.words = tl.prevWords || tl.words; tl.detail = tl.prevDetail || ''; this.addFx(w, 'pulse', { tile: id, dur: 1.0, ink: 'working' }); }
        else { tl.prevState = tl.state; tl.prevWords = tl.words; tl.prevDetail = tl.detail; tl.state = 'away'; tl.sinceAt = t; tl.words = tl.machine + ' is not answering'; tl.detail = 'last seen just now'; }
        break;
      case 'join':
        if (w.model.tiles.length >= 6) return;
        var nt = tile(extra.id || ('n' + Math.floor(t * 10) % 100000), extra.title || 'Index rebuild', extra.state || 'working', Object.assign({ words: 'Getting its bearings', phrases: PHRASES.index, started: 0, ctx: 0.06 }, extra.o || {}));
        prepTile(nt, t);
        nt.beat = nt.beat.map(function () { return 0; });
        nt.bornAt = t;
        w.model.tiles.push(nt);
        if (ev.joins) this.addFx(w, 'gather', { tile: nt.id, dur: 1.3 });
        else this.addFx(w, 'appear', { tile: nt.id, dur: 0.6 });
        w.dirty = true;
        return nt;
      case 'leave':
        if (!tl) return;
        tl.leaving = t;
        if (ev.joins) this.addFx(w, 'scatter', { tile: id, dur: 1.2 });
        setTimeout(function () {
          var i = w.model.tiles.indexOf(tl);
          if (i >= 0) {
            w.model.tiles.splice(i, 1);
            w.model.recent.unshift({ outcome: tl.state === 'failed' ? 'failed' : tl.state === 'done' ? 'done' : 'stopped', title: tl.title, at: self.t });
            if (w.model.recent.length > 5) w.model.recent.pop();
            w.dirty = true;
          }
        }, this.amp() ? 900 : 10);
        break;
    }
  };

  Engine.prototype.fire = function (w, kind) {
    var tiles = w.model.tiles.filter(function (x) { return !x.leaving; });
    var pick = function (pred) { for (var i = 0; i < tiles.length; i++) if (pred(tiles[i])) return tiles[i]; return null; };
    var working = pick(function (x) { return x.state === 'working'; });
    var self = this;
    switch (kind) {
      case 'tick': tiles.forEach(function (x) { if (x.state === 'working') self.event(w, 'tick', x.id); }); break;
      case 'spawn': var host = pick(function (x) { return x.state === 'working' && x.workers.filter(function (k) { return !k.gone; }).length < 6; }); if (host) this.event(w, 'spawn', host.id); break;
      case 'release': var hw = pick(function (x) { return x.workers.some(function (k) { return k.state === 'working' && !k.ended && !k.gone; }); }); if (hw) this.event(w, 'release', hw.id); break;
      case 'finish': var f = pick(function (x) { return x.state === 'working' || x.state === 'thinking'; }); if (f) { this.event(w, 'finish', f.id); setTimeout(function () { self.event(w, 'leave', f.id); }, 9000); } break;
      case 'ask': var a = pick(function (x) { return x.state === 'working' && !x.workers.length; }) || working; if (a) this.event(w, 'ask', a.id); else this.event(w, 'join', null, { id: 'ask2', title: 'Release branch', state: 'needs', o: { lead: 'Wants to run', cmd: 'git push --force-with-lease origin release/1.80', words: 'Force-uploading the changes to release/1.80' } }); break;
      case 'approve': var n = pick(function (x) { return x.state === 'needs' || x.state === 'overdue'; }); if (n) this.event(w, 'approve', n.id); break;
      case 'fail': if (working) this.event(w, 'fail', working.id); break;
      case 'retry': var r = pick(function (x) { return x.state === 'working' && x !== working; }) || working; if (r) this.event(w, 'retry', r.id); break;
      case 'compact': var c = tiles.slice().sort(function (p, q) { return q.ctx - p.ctx; })[0]; if (c) this.event(w, 'compact', c.id); break;
      case 'join': this.event(w, 'join', null, { title: ['Index rebuild', 'Search tuning', 'Widget polish', 'Crash triage'][w.model.tiles.length % 4] }); break;
      case 'away': var aw = pick(function (x) { return x.state === 'away'; }) || pick(function (x) { return x.machine !== 'studio'; }) || working; if (aw) this.event(w, 'away', aw.id); break;
      case 'quiet': if (working) this.event(w, 'quiet', working.id); break;
    }
  };

  var LIVE_SCRIPT = [
    [3, function (e, w) { e.event(w, 'spawn', 'w', { name: 'Plan', words: 'Searching the code' }); }],
    [7, function (e, w) { e.event(w, 'join', null, { id: 'ask', title: 'CI migration', o: { phrases: PHRASES.ci, words: 'Looking at the build script' } }); }],
    [9.5, function (e, w) { e.event(w, 'ask', 'ask', { cmd: 'rm -rf build && swift build -c release', words: 'Clearing the build folder, then building the project' }); }],
    [14, function (e, w) { e.event(w, 'finish', 't'); }],
    [18, function (e, w) { e.event(w, 'release', 'w', {}); }],
    [21, function (e, w) { e.event(w, 'compact', 'l'); }],
    [24, function (e, w) { e.event(w, 'leave', 't'); }],
    [26, function (e, w) { e.event(w, 'approve', 'ask', { words: 'Building the project' }); }],
    [29, function (e, w) { e.event(w, 'join', null, { id: 'idx', title: 'Index rebuild' }); }],
    [33, function (e, w) { e.event(w, 'fail', 'idx', { words: 'The index tests failed', detail: '3 of 41 tests failed' }); }],
    [36, function (e, w) { e.event(w, 'retry', 'l'); }],
    [40, function (e, w) { e.event(w, 'resume', 'l'); }],
    [44, function (e, w) { e.event(w, 'spawn', 'ask', { name: 'Test runner', words: 'Running the tests', todo: [1, 4] }); }],
    [48, function (e, w) { e.event(w, 'leave', 'idx'); }],
    [52, function (e, w) { e.event(w, 'finish', 'ask'); }],
    [58, function (e, w) { e.loadScene(w, 'live'); e.event(w, 'appearAll'); }]
  ];
  Engine.LIVE_SCRIPT = LIVE_SCRIPT;

  Engine.prototype.runScript = function (w) {
    var script = w.script || (w.autoplay ? LIVE_SCRIPT : null);
    if (!script) return;
    var el = this.t - w.scriptAt;
    while (w.cursor < script.length && el >= script[w.cursor][0]) {
      var step = script[w.cursor];
      w.cursor++;
      step[1](this, w);
      if (w.cursor === 0) return;
    }
    if (w.loop && el >= w.loop) {
      if (w.resetOnLoop) {
        this.loadScene(w, w.sceneName);
        var t = this.t;
        w.model.tiles.forEach(function (x) { x.bornAt = t - 0.6; });
      } else { w.scriptAt = this.t; w.cursor = 0; }
    }
  };

  var CATALOG = [
    { key: 'steps', scene: 'c-working', loop: 3.2, script: [[0.4, 'tick'], [1.2, 'tick'], [1.7, 'tick'], [2.6, 'tick']] },
    { key: 'spawn', scene: 'c-working', loop: 4.8, reset: true, script: [[0.6, 'spawn', { name: 'Explore', words: 'Reading the retry paths', todo: [1, 6] }], [1.9, 'spawn', { name: 'Plan', words: 'Searching the code' }]] },
    { key: 'release', scene: 'c-squad', loop: 4.6, reset: true, script: [[0.9, 'release', { worker: 'k1' }]] },
    { key: 'finish', scene: 'c-working', loop: 4.8, reset: true, script: [[0.9, 'finish']] },
    { key: 'ask', scene: 'c-working', loop: 5.4, reset: true, script: [[0.8, 'ask', { cmd: 'rm -rf build && swift build -c release', words: 'Clearing the build folder, then building' }]] },
    { key: 'overdue', scene: 'c-overdue' },
    { key: 'approve', scene: 'c-needs', loop: 4.8, reset: true, script: [[1.0, 'hold']] },
    { key: 'fail', scene: 'c-working', loop: 4.8, reset: true, script: [[0.9, 'fail']] },
    { key: 'retry', scene: 'c-retry', loop: 3.2, reset: true, script: [[1.0, 'retry']] },
    { key: 'quiet', scene: 'c-quiet', quietEvery: 4 },
    { key: 'compact', scene: 'c-ctx', loop: 4.6, reset: true, script: [[1.0, 'compact']] },
    { key: 'join', scene: 'c-empty', loop: 4.8, reset: true, script: [[0.4, 'join', { id: 'a', title: 'Index rebuild' }], [3.3, 'leave', { id: 'a' }]] }
  ];

  Engine.prototype.addCatalog = function () {
    var self = this;
    CATALOG.forEach(function (c) {
      var dev = { name: 'cell', w: 380, h: 218, safe: [0, 0, 0, 0], corner: 14, seen: 'iPad', u: 6.5 };
      var script = (c.script || []).map(function (s) {
        return [s[0], function (e, w) {
          if (s[1] === 'hold') {
            var cut = e.cellOf(w, 'a');
            if (!cut) return;
            w.hold = { tile: 'a', x: cut.main.x + cut.main.w * 0.62, y: cut.main.y + cut.main.h * 0.62, t0: e.t };
          } else if (s[1] === 'join') e.event(w, 'join', null, s[2]);
          else if (s[1] === 'leave') e.event(w, 'leave', s[2].id);
          else e.event(w, s[1], 'a', s[2] || {});
        }];
      });
      var w = self.addWorld(dev, c.scene, { chrome: false, ticks: false, script: script, loop: c.loop, quietEvery: c.quietEvery, alwaysSquads: true });
      w.resetOnLoop = !!c.reset;
      w.key = c.key;
    });
    this.resize();
  };

  Engine.prototype.pointer = function (ev) {
    var rect = this.txc.getBoundingClientRect();
    var sx = this.txc.width / Math.max(1, rect.width), sy = this.txc.height / Math.max(1, rect.height);
    var px = (ev.clientX - rect.left) * sx, py = (ev.clientY - rect.top) * sy;
    var w = null;
    for (var i = 0; i < this.worlds.length; i++) {
      var c = this.worlds[i];
      if (px >= c.ox && py >= c.oy && px <= c.ox + c.dev.w * c.scale && py <= c.oy + c.dev.h * c.scale) { w = c; break; }
    }
    if (!w || !w.chrome || !w.L) return;
    var x = (px - w.ox) / w.scale, y = (py - w.oy) / w.scale;
    var t = this.t;
    if (ev.type === 'pointerdown') {
      if (w.peek) { w.peek = null; return; }
      var hit = this.hitTile(w, x, y);
      w.down = { x: x, y: y, t: t, tile: hit };
      if (hit && (hit.state === 'needs' || hit.state === 'overdue')) w.hold = { tile: hit.id, x: x, y: y, t0: t };
      try { this.txc.setPointerCapture(ev.pointerId); } catch (e) { }
    } else if (ev.type === 'pointermove') {
      if (w.hold && Math.hypot(x - w.hold.x, y - w.hold.y) > 14) { w.hold = null; }
    } else if (ev.type === 'pointerup' || ev.type === 'pointercancel') {
      var d = w.down; w.down = null;
      if (w.hold) {
        var held = t - w.hold.t0;
        if (held < 0.8) w.hint = { tile: w.hold.tile, until: t + 1.6 };
        w.hold = null;
        return;
      }
      if (!d || ev.type === 'pointercancel') return;
      if (d.tile && d.tile.state !== 'needs' && d.tile.state !== 'overdue') w.peek = { tile: d.tile.id, until: t + 9 };
      else if (!d.tile) {
        var cr = w.controlsRect;
        if (cr && t < w.controlsUntil && x >= cr.x && x <= cr.x + cr.w && y >= cr.y && y <= cr.y + cr.h) {
          var dimHit = cr.dim && x >= cr.dim.x && x <= cr.dim.x + cr.dim.w;
          if (dimHit) { w.manualDim = !w.manualDim; }
          w.controlsUntil = t + 3;
        } else w.controlsUntil = t + 3;
      }
    }
  };

  Engine.prototype.hitTile = function (w, x, y) {
    var L = w.L;
    for (var i = 0; i < w.model.tiles.length; i++) {
      var tl = w.model.tiles[i], cut = L.tiles[tl.id];
      if (!cut) continue;
      var r = cut.cell;
      if (x >= r.x && y >= r.y && x <= r.x + r.w && y <= r.y + r.h) return tl;
    }
    return null;
  };

  Engine.prototype.frame = function (now) {
    var dt = clamp(now - this.t, 0, 0.1);
    this.t = now;
    var hidden = document.hidden || !this.visible;
    var self = this;
    var active = false;
    this.worlds.forEach(function (w) { self.update(w, dt); if (w.fx.length || w.morph || w.hold) active = true; });
    var calmDim = this.worlds.every(function (w) { return w.dimmed > 0.9 && !w.fx.length; });
    var cap = hidden ? 0 : active ? 60 : calmDim ? 1 : 30;
    if (this.opts.maxFps && cap) cap = Math.min(cap, this.opts.maxFps);
    this.cap = cap;
    if (!cap) return;
    if (now - this.lastDraw < 1 / cap - 0.004) return;
    this.lastDraw = now;
    this.draw();
    this.fpsCount++;
    if (now - this.fpsAt >= 1) {
      this.fps = Math.round(this.fpsCount / (now - this.fpsAt));
      this.fpsCount = 0; this.fpsAt = now;
      if (this.onStats) {
        var fxn = 0, motes = 0;
        this.worlds.forEach(function (w) { fxn += w.fx.length; motes += self.style.field === 'none' ? 0 : w.motes.count; });
        this.onStats({ fps: this.fps, cap: cap, effects: fxn, motes: motes });
      }
    }
  };

  Engine.prototype.update = function (w, dt) {
    var t = this.t, self = this, st = this.style;
    this.runScript(w);
    if (w.dirty || !w.L) { w.L = layout(w.dev, w.model, { rails: st.rails && w.chrome, ribbon: st.ribbon && w.chrome, squads: w.alwaysSquads || st.squads, solo: !w.chrome }); w.dirty = false; }
    var m = moodOf(w.model.tiles);
    w.mood = m;
    var targetMood = (function () {
      if (m.mood === 'calm') return mix(self.P.text, self.P.dim, 0.35);
      if (m.mood === 'busy') return self.P.working;
      if (m.mood === 'attention') return self.P.needs;
      return m.failed && !m.overdue ? self.P.failed : self.P.overdue;
    })();
    var k = 1 - Math.exp(-dt / 1.2);
    w.moodInk = w.moodInk ? mix(w.moodInk, targetMood, k) : targetMood;
    var vigTarget = m.overdue ? 0.16 + 0.1 * Math.sin(TAU * t / 9) : 0;
    if (st.reduced && m.overdue) vigTarget = 0.18;
    w.vig = lerp(w.vig, vigTarget, 1 - Math.exp(-dt / 0.8));
    var wantDim = (st.dim || w.manualDim) ? 1 : 0;
    w.dimmed = lerp(w.dimmed, wantDim, 1 - Math.exp(-dt / 0.45));
    var sec = Math.floor(t);
    w.model.tiles.forEach(function (tl) {
      while (tl.beatAt < sec) {
        tl.beat.shift();
        tl.beat.push(0);
        tl.beatAt++;
      }
      if (w.ticks && (tl.state === 'working' || tl.state === 'needs') && t >= tl.nextTick) {
        if (tl.state === 'working') self.event(w, 'tick', tl.id);
        tl.nextTick = t + 0.9 + Math.random() * 2.6;
      }
      if (tl.state === 'needs' && t - tl.sinceAt > 300) tl.state = 'overdue';
      tl.pulse = Math.max(0, tl.pulse - dt * 2.5);
      var target = ink(self.P, tl.state);
      tl.inkShown = tl.inkShown ? mix(tl.inkShown, target, 1 - Math.exp(-dt / 0.3)) : target;
      if (!tl.draining) tl.ctxShown = lerp(tl.ctxShown == null ? tl.ctx : tl.ctxShown, tl.ctx, 1 - Math.exp(-dt / 0.4));
      tl.workers.forEach(function (wk) {
        if (wk.state === 'finished' && wk.ended && t - wk.ended > 12 && !wk.gone) { wk.gone = true; w.dirty = true; }
      });
    });
    var target = null;
    w.model.tiles.forEach(function (tl) {
      if ((tl.state === 'needs' || tl.state === 'overdue') && w.L.tiles[tl.id]) {
        var c = w.L.tiles[tl.id].cell;
        target = { x: (c.x + c.w / 2) / w.dev.w, y: (c.y + c.h / 2) / w.dev.h };
      }
    });
    var slow = st.reduced ? 0 : (1 - 0.6 * w.dimmed);
    if (st.field !== 'none') w.motes.step(dt, m.mood, target, slow, w.dev.w / w.dev.h);
    if (w.morph && t - w.morph.t0 > w.morph.dur) w.morph = null;
    if (w.peek && t > w.peek.until) w.peek = null;
    if (w.hold && t - w.hold.t0 >= 0.8) {
      var id = w.hold.tile;
      w.hold = null;
      w.down = null;
      this.event(w, 'approve', id);
    }
    w.fx = w.fx.filter(function (e) { return t - e.t0 < e.dur; });
  };

  Engine.prototype.cellOf = function (w, id) {
    var cut = w.L.tiles[id];
    if (!cut) return null;
    var tl = findTile(w, id);
    var res = { cell: cut.cell, main: cut.main, workers: cut.workers, plus: cut.plus, dots: cut.dots };
    if (w.morph && w.morph.from[id]) {
      var f = w.morph.from[id], p = easeOut((this.t - w.morph.t0) / w.morph.dur);
      var ox = f.x * w.dev.w, oy = f.y * w.dev.h, ow = f.w * w.dev.w, oh = f.h * w.dev.h;
      var c = cut.cell;
      var mr = rect(lerp(ox, c.x, p), lerp(oy, c.y, p), lerp(ow, c.w, p), lerp(oh, c.h, p));
      var sx = mr.w / Math.max(1, c.w), sy = mr.h / Math.max(1, c.h);
      var map = function (r) { return rect(mr.x + (r.x - c.x) * sx, mr.y + (r.y - c.y) * sy, r.w * sx, r.h * sy); };
      res = { cell: mr, main: map(cut.main), workers: cut.workers.map(function (x) { return { w: x.w, r: map(x.r) }; }), plus: cut.plus ? { r: map(cut.plus.r), n: cut.plus.n, look: cut.plus.look } : null, dots: cut.dots };
    }
    if (tl && tl.bornAt && this.t - tl.bornAt < 1.3) res.born = (this.t - tl.bornAt) / 1.3;
    return res;
  };

  function glyphSize(r, L) { return clamp(Math.min(r.w, r.h) * 0.3, 22, Math.max(28, L.u * 4.4)); }

  Engine.prototype.glyphCenter = function (w, r) {
    var L = w.L, S = glyphSize(r, L), p = Math.max(1.3 * L.u, 9);
    return { x: r.x + p + S / 2, y: r.y + p + S / 2, S: S };
  };

  Engine.prototype.pushGlyph = function (batch, cx, cy, S, extent, col, alpha, kind, p1, p2, p3, p4) {
    batch.push([cx, cy, S, extent, col[0], col[1], col[2], alpha, kind, p1 || 0, p2 || 0, p3 || 0, p4 || 0, 0, 0, 0]);
  };

  Engine.prototype.tileGlyph = function (w, tl, g, opacity, reduced) {
    var P = this.P, t = this.t, an = !reduced, gb = this.glyphs;
    var c = tl.inkShown || ink(P, tl.state);
    var share = tl.ctxShown == null ? tl.ctx : tl.ctxShown;
    var ringInk = share > 0.85 ? P.needs : c;
    var self = this;
    var ctxRing = function (scale, track) { self.pushGlyph(gb, g.x, g.y, g.S, 0.62, ringInk, opacity, 1, 0.455 * scale, 0.058, share, track === false ? 0 : 0.14); };
    switch (tl.state) {
      case 'working':
        ctxRing(1);
        var sw = breath(t, 3.4, an) + tl.pulse * 0.6;
        this.pushGlyph(gb, g.x, g.y, g.S, 0.75, c, opacity, 0, 0.29 * (0.93 + 0.07 * sw), 0.35 + 0.35 * sw);
        break;
      case 'thinking':
        ctxRing(1);
        var sw2 = breath(t, 7.5, an);
        this.pushGlyph(gb, g.x, g.y, g.S, 0.75, c, opacity, 0, 0.29 * (0.9 + 0.06 * sw2), 0.2 + 0.3 * sw2);
        break;
      case 'needs':
      case 'overdue':
        var over = tl.state === 'overdue', period = over ? 2.6 : 4.2, second = over ? 0.26 : 0.34;
        var hit = knock(t, period, second, an);
        ctxRing(1);
        if (an) {
          var ph = t % period, start = 0;
          for (var i = 0; i < 2; i++) {
            var q = (ph - start) / 1.1;
            if (q >= 0 && q < 1) this.pushGlyph(this.fx, g.x, g.y, g.S, 0.75, c, opacity * 0.6 * (1 - q) * (1 - q), 7, 0.29 + (0.51 - 0.29) * q, 0.03);
            start = second;
          }
        }
        this.pushGlyph(gb, g.x, g.y, g.S, 0.8, c, opacity, 0, 0.29 * (0.9 + 0.2 * hit), 0.45 + 0.5 * hit);
        break;
      case 'retrying':
        this.pushGlyph(gb, g.x, g.y, g.S, 0.62, ringInk, opacity, 1, 0.455 * 0.8, 0.058, share, 0);
        this.pushGlyph(gb, g.x, g.y, g.S, 0.62, c, opacity * 0.95, 2, 0.455, 0.067, an ? -t * 0.09 : 0);
        this.pushGlyph(gb, g.x, g.y, g.S, 0.6, c, opacity, 0, 0.13, 0.2);
        break;
      case 'quiet':
        ctxRing(1);
        if (an) {
          var rp = ((t - tl.sinceAt) % w.quietEvery) / 2.6;
          if (rp < 1) this.pushGlyph(this.fx, g.x, g.y, g.S, 0.9, c, opacity * 0.5 * (1 - rp), 7, 0.29 + 0.4 * rp, 0.04);
        }
        this.pushGlyph(gb, g.x, g.y, g.S, 0.5, c, opacity, 10, 0.267);
        break;
      case 'background':
      case 'stuck':
        var still = tl.state === 'stuck' || !an;
        this.pushGlyph(gb, g.x, g.y, g.S, 0.6, c, opacity, 3, 0.39, 0.072, still ? 0.9 : t * TAU / 6.5, 0.075);
        break;
      case 'done':
        this.pushGlyph(gb, g.x, g.y, g.S, 0.6, c, opacity, 4);
        break;
      case 'failed':
        this.pushGlyph(gb, g.x, g.y, g.S, 0.6, c, opacity, 5);
        break;
      case 'stopped':
        this.pushGlyph(gb, g.x, g.y, g.S, 0.6, P.dim, opacity, 6);
        break;
      case 'away':
        this.pushGlyph(gb, g.x, g.y, g.S, 0.6, P.dim, opacity, 9, 0.4);
        break;
    }
  };

  Engine.prototype.workerGlyph = function (w, wk, g, opacity, reduced) {
    var P = this.P, t = this.t, an = !reduced;
    var c = wk.state === 'quiet' ? P.quiet : wk.state === 'stuck' ? P.needs : wk.state === 'finished' ? P.dim : P.working;
    if (wk.state === 'working') {
      var sw = breath(t + wk.id.length, 3.4, an);
      this.pushGlyph(this.glyphs, g.x, g.y, g.S, 0.75, c, opacity, 0, 0.29 * (0.92 + 0.08 * sw), 0.3 + 0.3 * sw);
    } else if (wk.state === 'quiet') {
      this.pushGlyph(this.glyphs, g.x, g.y, g.S, 0.5, c, opacity, 10, 0.26);
    } else if (wk.state === 'background' || wk.state === 'stuck') {
      this.pushGlyph(this.glyphs, g.x, g.y, g.S, 0.6, c, opacity, 3, 0.36, 0.08, wk.state === 'stuck' || !an ? 0.9 : t * TAU / 6.5 + wk.id.length, 0.085);
    } else {
      var cool = clamp((t - (wk.ended || t)) / 30, 0, 1);
      this.pushGlyph(this.glyphs, g.x, g.y, g.S, 0.6, c, opacity * (1 - 0.5 * cool), 7, 0.36, 0.035);
    }
  };

  Engine.prototype.plate = function (r, c, opacity, o) {
    o = o || {};
    this.plates.push([r.x, r.y, r.w, r.h, c[0], c[1], c[2], opacity, o.radius || 12, o.wash || 0, o.borderA || 0.34, o.borderW || 1, o.hatch ? 1 : 0, o.flat || 0, o.sheen == null ? 1 : o.sheen, 0]);
  };

  function plateLook(state, swell, u) {
    var s = 0.06 + 0.06 * swell, ba = 0.34, bw = 1, flat = 0;
    switch (state) {
      case 'overdue': s = 0.15 + 0.1 * swell; ba = 0.8 + 0.2 * swell; bw = 0.34 * u; flat = s * 0.5; break;
      case 'needs': s = 0.1 + 0.08 * swell; ba = 0.55 + 0.4 * swell; bw = 0.26 * u; flat = s * 0.5; break;
      case 'retrying': ba = 0.5; bw = 0.2 * u; break;
      case 'quiet': s = 0.04; ba = 0.5; break;
      case 'failed': s = 0.14; ba = 0.85; bw = 0.26 * u; break;
      case 'done': s = 0.03; ba = 0.4; break;
      case 'stopped': case 'away': s = 0.03; ba = 0.3; break;
      case 'stuck': s = 0.07; ba = 0.5; break;
    }
    return { wash: s, borderA: ba, borderW: Math.max(1, bw), flat: flat };
  }

  function tileSwell(state, t, an) {
    switch (state) {
      case 'needs': return knock(t, 4.2, 0.34, an);
      case 'overdue': return knock(t, 2.6, 0.26, an);
      case 'working': return breath(t, 5.2, an);
      case 'thinking': return breath(t, 8, an);
      case 'background': return breath(t, 6.5, an);
      case 'retrying': return breath(t, 4, an);
      default: return 0.5;
    }
  }

  Engine.prototype.draw = function () {
    var gl = this.gl, self = this;
    var H = this.glc.height;
    gl.disable(gl.DEPTH_TEST);
    gl.enable(gl.SCISSOR_TEST);
    gl.viewport(0, 0, this.glc.width, H);
    gl.scissor(0, 0, this.glc.width, H);
    var bg = this.opts.clear || [0.03, 0.03, 0.045];
    gl.clearColor(bg[0], bg[1], bg[2], 1);
    gl.clear(gl.COLOR_BUFFER_BIT);
    var ctx = this.ctx;
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.clearRect(0, 0, this.txc.width, this.txc.height);
    this.worlds.forEach(function (w) { if (w.L) self.drawWorld(w); });
  };

  Engine.prototype.drawWorld = function (w) {
    var gl = this.gl, P = this.P, st = this.style, t = this.t, L = w.L, self = this;
    var reduced = st.reduced, an = !reduced;
    var vw = Math.round(w.dev.w * w.scale), vh = Math.round(w.dev.h * w.scale);
    var vx = Math.round(w.ox), vy = this.glc.height - Math.round(w.oy) - vh;
    gl.viewport(vx, vy, vw, vh);
    gl.scissor(vx, vy, vw, vh);
    var dim = (1 - 0.6 * w.dimmed) * (w.peek ? 0.45 : 1);
    var shift = w.chrome && an ? [Math.sin(TAU * t / 600) * 6, Math.cos(TAU * t / 600) * 6] : [0, 0];
    w.shift = shift;
    this.plates.reset(); this.glyphs.reset(); this.fx.reset(); this.points.reset();
    var lights = [], ripples = [];
    var tiles = w.model.tiles;
    tiles.forEach(function (tl) {
      var cut = self.cellOf(w, tl.id);
      if (!cut) return;
      var opacity = 1;
      if (tl.leaving) opacity = clamp(1 - (t - tl.leaving) / 0.9, 0, 1);
      if (cut.born != null) opacity = Math.min(opacity, smooth((cut.born - 0.35) / 0.65));
      if (tl.state === 'done') opacity *= 1 - 0.55 * clamp((t - tl.sinceAt) / 60, 0, 1);
      if (tl.state === 'away') opacity *= 0.7;
      var swell = tileSwell(tl.state, t, an);
      var look = plateLook(tl.state, swell, L.u);
      var c = tl.inkShown || ink(P, tl.state);
      var radius = Math.max(1.6 * L.u, 10);
      if (cut.workers.length || cut.plus) {
        self.plate(rect(cut.cell.x - 4, cut.cell.y - 4, cut.cell.w + 8, cut.cell.h + 8), c, opacity * 0.5, { radius: radius + 4, wash: 0.012, borderA: 0.1, sheen: 0 });
      }
      self.plate(cut.main, c, opacity, { radius: radius, wash: look.wash + tl.pulse * 0.03, borderA: look.borderA, borderW: look.borderW, flat: look.flat, hatch: tl.state === 'away' });
      if (st.light && lights.length < 8) {
        var strength = { working: 0.05, thinking: 0.04, needs: 0.09, overdue: 0.13, failed: 0.08, retrying: 0.06, background: 0.035, stuck: 0.05, quiet: 0.025, done: 0.035 }[tl.state] || 0.02;
        strength *= (0.75 + 0.5 * swell) * opacity;
        lights.push({ r: cut.main, c: c, a: strength });
      }
      var g = self.glyphCenter(w, cut.main);
      self.tileGlyph(w, tl, g, opacity, reduced);
      cut.workers.forEach(function (x) {
        var wk = x.w, born = clamp((t - wk.bornAt) / 1.1, 0, 1);
        var wo = opacity * smooth((born - 0.3) / 0.7);
        if (wk.state === 'finished') wo *= 1 - 0.45 * clamp((t - wk.ended) / 30, 0, 1);
        var wc = wk.state === 'quiet' ? P.quiet : wk.state === 'stuck' ? P.needs : wk.state === 'finished' ? P.dim : P.working;
        self.plate(x.r, wc, wo, { radius: Math.max(1.2 * L.u, 8), wash: wk.state === 'working' ? 0.05 : 0.025, borderA: wk.state === 'quiet' ? 0.45 : 0.26, sheen: 0.6 });
        var S = clamp(Math.min(x.r.h * 0.42, L.u * 3), 14, 30), pp = Math.max(0.9 * L.u, 7);
        self.workerGlyph(w, wk, { x: x.r.x + pp + S / 2, y: x.r.y + x.r.h / 2, S: S }, wo, reduced);
      });
      if (cut.plus) self.plate(cut.plus.r, cut.plus.look ? P.needs : P.dim, opacity, { radius: Math.max(1.2 * L.u, 8), wash: 0.02, borderA: cut.plus.look ? 0.5 : 0.25, sheen: 0.4 });
    });
    if (!tiles.length && w.chrome !== false && L.calm) {
      var cs = L.calm.R * 2;
      var sw = breath(t, 11, an);
      this.pushGlyph(this.glyphs, L.calm.cx, L.calm.cy, cs, 0.95, P.quiet, 0.9, 0, 0.29 * (0.94 + 0.06 * sw), 0.35 + 0.25 * sw);
      this.pushGlyph(this.glyphs, L.calm.cx, L.calm.cy, cs, 0.62, P.quiet, 0.5, 1, 0.455, 0.012, 1, 0);
    }
    w.fx.forEach(function (e) { self.drawFx(w, e, ripples); });
    if (w.hold) {
      var hp = clamp((t - w.hold.t0) / 0.8, 0, 1);
      var hs = Math.max(L.u * 7, 56);
      this.pushGlyph(this.fx, w.hold.x, w.hold.y, hs, 0.6, P.needs, 0.25, 8, 0.45);
      this.pushGlyph(this.glyphs, w.hold.x, w.hold.y, hs, 0.6, P.needs, 0.95, 1, 0.42, 0.07, hp, 0.25);
    }
    if (st.field !== 'none') {
      var mo = w.motes, mi = w.moodInk || P.text;
      var area = Math.min(w.dev.w, w.dev.h);
      for (var i = 0; i < mo.count; i++) {
        var tw = an ? 0.5 + 0.5 * Math.sin(mo.ph[i] + t * 0.45) : 0.55;
        var al = (0.05 + 0.13 * tw) * (st.night ? 0.5 : 1);
        var rad = Math.max(0.8, mo.sz[i] * L.u * 0.8);
        var mx = mo.x[i] * w.dev.w, my = mo.y[i] * w.dev.h;
        var col = mix(P.text, mi, 0.55);
        this.points.push([mx, my, rad * 4.4, 0.45, col[0], col[1], col[2], al * 1.6]);
        if (st.field === 'currents') {
          for (var k = 1; k < 4; k++) {
            var tx = mo.tx[i * 4 + k] * w.dev.w, ty = mo.ty[i * 4 + k] * w.dev.h;
            var dx = mx - tx, dy = my - ty, dl = Math.hypot(dx, dy);
            var steps = Math.min(6, Math.ceil(dl / Math.max(1, rad)));
            for (var s = 1; s <= steps; s++) {
              var f = s / (steps + 1);
              this.points.push([lerp(mx, tx, f), lerp(my, ty, f), rad * 2.6, 0.5, col[0], col[1], col[2], al * (1 - (k - 1 + f) / 3.4) * 0.9]);
            }
          }
        }
      }
      void area;
    }
    var gp = this.pg, gu = gp.u;
    gl.useProgram(gp.p);
    gl.disable(gl.BLEND);
    gl.uniform4f(gu.uVP, vx, vy, vw, vh);
    gl.uniform2f(gu.uSize, w.dev.w, w.dev.h);
    gl.uniform1f(gu.uScale, w.scale);
    gl.uniform1f(gu.uU, L.u);
    gl.uniform2f(gu.uShift, shift[0], shift[1]);
    gl.uniform3fv(gu.uGround, P.ground);
    gl.uniform3fv(gu.uDeep, P.deep);
    gl.uniform3fv(gu.uText, P.text);
    gl.uniform3fv(gu.uTint, w.moodInk || P.text);
    gl.uniform3fv(gu.uVig, P.overdue);
    gl.uniform1f(gu.uTintA, 0.085);
    gl.uniform1f(gu.uVigA, w.vig);
    gl.uniform1f(gu.uDim, dim);
    gl.uniform1f(gu.uTime, an ? t : 0);
    gl.uniform1f(gu.uAurora, st.field === 'aurora' ? 1 : 0);
    gl.uniform1f(gu.uGridA, 0.032);
    var lr = new Float32Array(32), li = new Float32Array(32);
    lights.forEach(function (l, i) { lr.set([l.r.x, l.r.y, l.r.w, l.r.h], i * 4); li.set([l.c[0], l.c[1], l.c[2], l.a], i * 4); });
    gl.uniform1i(gu.uNL, lights.length);
    gl.uniform4fv(gu.uLR, lr);
    gl.uniform4fv(gu.uLI, li);
    var rr = new Float32Array(48), ri = new Float32Array(48), rp = new Float32Array(48);
    ripples.slice(0, 12).forEach(function (r, i) { rr.set([r.r.x, r.r.y, r.r.w, r.r.h], i * 4); ri.set([r.c[0], r.c[1], r.c[2], r.a], i * 4); rp.set([r.grow, r.width, r.radius, 0], i * 4); });
    gl.uniform1i(gu.uNR, Math.min(12, ripples.length));
    gl.uniform4fv(gu.uRR, rr);
    gl.uniform4fv(gu.uRI, ri);
    gl.uniform4fv(gu.uRP, rp);
    gl.bindVertexArray(this.emptyVao);
    gl.drawArrays(gl.TRIANGLES, 0, 3);
    gl.bindVertexArray(null);
    gl.enable(gl.BLEND);
    var cw = this.glc.width, chh = this.glc.height;
    var setQuad = function (prog) {
      gl.useProgram(prog.p);
      gl.uniform4f(prog.u.uWorld, w.ox, w.oy, w.scale, 0);
      gl.uniform2f(prog.u.uCanvas, cw, chh);
      gl.uniform2f(prog.u.uShift, shift[0], shift[1]);
      if (prog.u.uDim) gl.uniform1f(prog.u.uDim, dim);
      if (prog.u.uScale) gl.uniform1f(prog.u.uScale, w.scale);
      if (prog.u.uText) gl.uniform3fv(prog.u.uText, P.text);
      if (prog.u.uU) gl.uniform1f(prog.u.uU, L.u);
      if (prog.u.uDimInk) gl.uniform3fv(prog.u.uDimInk, P.dim);
    };
    gl.viewport(0, 0, cw, chh);
    gl.blendFunc(gl.ONE, gl.ONE);
    setQuad(this.pt);
    this.points.draw();
    gl.blendFunc(gl.ONE, gl.ONE_MINUS_SRC_ALPHA);
    setQuad(this.pp);
    this.plates.draw();
    setQuad(this.pq);
    this.glyphs.draw();
    gl.blendFunc(gl.ONE, gl.ONE);
    this.fx.draw();
    this.drawText(w, dim);
  };

  Engine.prototype.drawFx = function (w, e, ripples) {
    var t = this.t, P = this.P, L = w.L, self = this;
    var p = (t - e.t0) / e.dur;
    if (p < 0) return;
    var tl = findTile(w, e.tile);
    var cut = e.tile ? this.cellOf(w, e.tile) : null;
    if (e.tile && !cut) return;
    var a = e.amp || 1;
    var main = cut ? cut.main : null;
    var g = main ? this.glyphCenter(w, main) : null;
    var c = e.ink ? P[e.ink] : tl ? (tl.inkShown || ink(P, tl.state)) : P.text;
    var rnd = function (i, k) { var x = Math.sin((i + 1) * 12.9898 + k * 78.233 + e.t0 * 3.7) * 43758.5453; return x - Math.floor(x); };
    switch (e.kind) {
      case 'spark':
        var bx = main.x + Math.max(1.3 * L.u, 9), bw = main.w - 2 * Math.max(1.3 * L.u, 9);
        var by = main.y + main.h - Math.max(1.3 * L.u, 9) - 2;
        var sx = lerp(bx + bw * 0.58, bx + bw * 0.62, easeOut(p));
        var alpha = Math.sin(Math.PI * clamp(p, 0, 1)) * 0.7 * Math.min(a, 1.3);
        this.points.push([sx, by, Math.max(10, L.u * 1.6), 0.25, c[0], c[1], c[2], alpha]);
        break;
      case 'thread':
        var wkr = cut.workers.filter(function (x) { return x.w.id === e.worker; })[0];
        if (!wkr) return;
        var to = { x: wkr.r.x + wkr.r.w * 0.3, y: wkr.r.y + wkr.r.h / 2 };
        var ctl = { x: (g.x + to.x) / 2 + (to.y - g.y) * 0.25, y: (g.y + to.y) / 2 - (to.x - g.x) * 0.25 };
        var count = Math.round(16 * Math.min(a, 1.4));
        for (var i = 0; i < count; i++) {
          var q = clamp((p * 1.4 - i * 0.025), 0, 1);
          if (q <= 0 || q >= 1) continue;
          var ix = (1 - q) * (1 - q) * g.x + 2 * (1 - q) * q * ctl.x + q * q * to.x;
          var iy = (1 - q) * (1 - q) * g.y + 2 * (1 - q) * q * ctl.y + q * q * to.y;
          this.points.push([ix, iy, Math.max(5, L.u * 0.9) * (1 - i / count * 0.5), 0.35, c[0], c[1], c[2], Math.sin(Math.PI * q) * 0.5 * Math.min(a, 1.2)]);
        }
        break;
      case 'dissolve':
        var wd = cut.workers.filter(function (x) { return x.w.id === e.worker; })[0];
        if (!wd) return;
        var n = Math.round(20 * Math.min(a, 1.4));
        for (var j = 0; j < n; j++) {
          var sx0 = wd.r.x + rnd(j, 1) * wd.r.w, sy0 = wd.r.y + rnd(j, 2) * wd.r.h;
          var qq = easeOut(clamp(p - rnd(j, 3) * 0.2, 0, 1));
          var px = lerp(sx0, g.x, qq * 0.85) + Math.sin(qq * 6 + j) * L.u * 0.6;
          var py = lerp(sy0, g.y, qq * 0.85) + Math.cos(qq * 5 + j) * L.u * 0.6;
          this.points.push([px, py, Math.max(4, L.u * 0.75), 0.35, P.dim[0], P.dim[1], P.dim[2], (1 - qq) * 0.45 * Math.min(a, 1.2)]);
        }
        break;
      case 'exhale':
        var maxR = Math.hypot(main.w, main.h) / g.S;
        this.pushGlyph(this.fx, g.x, g.y, g.S, maxR + 0.2, c, 0.5 * Math.pow(1 - p, 1.6) * Math.min(a, 1.3), 7, lerp(0.3, maxR * 0.9, easeOut(p)), 0.06 + 0.1 * p);
        this.pushGlyph(this.fx, g.x, g.y, g.S, 1.2, c, 0.35 * Math.sin(Math.PI * clamp(p * 1.6, 0, 1)) * Math.min(a, 1.3), 8, 0.55);
        break;
      case 'ripple':
        var rc = e.ink ? P[e.ink] : c;
        ripples.push({ r: main, c: rc, a: (e.strength || 0.12) * Math.pow(1 - p, 2) * Math.min(a, 1.4), grow: easeOut(p) * L.u * 16, width: L.u * (1.2 + 3 * p), radius: Math.max(1.6 * L.u, 10) });
        break;
      case 'knock':
        ripples.push({ r: main, c: c, a: 0.2 * Math.pow(1 - p, 2) * Math.min(a, 1.4), grow: easeOut(p) * L.u * 9, width: L.u * (0.8 + 1.6 * p), radius: Math.max(1.6 * L.u, 10) });
        break;
      case 'fracture':
        this.pushGlyph(this.fx, g.x, g.y, g.S, 2.2, P.failed, 0.45 * Math.pow(1 - p, 2) * Math.min(a, 1.3), 8, 0.9);
        var shards = Math.round(10 * Math.min(a, 1.4));
        for (var s = 0; s < shards; s++) {
          var ang = rnd(s, 4) * TAU, dist = easeOut(p) * g.S * (0.6 + rnd(s, 5) * 0.8);
          this.points.push([g.x + Math.cos(ang) * dist, g.y + Math.sin(ang) * dist, Math.max(4, L.u * 0.6), 0.4, P.failed[0], P.failed[1], P.failed[2], (1 - p) * 0.5]);
        }
        break;
      case 'pulse':
        this.pushGlyph(this.fx, g.x, g.y, g.S, 1.4, c, 0.4 * Math.pow(1 - p, 2) * Math.min(a, 1.3), 7, lerp(0.35, 1.1, easeOut(p)), 0.05);
        break;
      case 'approved':
        var wc = P.working;
        this.pushGlyph(this.fx, g.x, g.y, g.S, 2.8, wc, 0.45 * Math.pow(1 - p, 1.5), 7, lerp(1.6, 0.3, easeOut(p)), 0.08);
        this.pushGlyph(this.fx, g.x, g.y, g.S, 1.4, wc, 0.3 * Math.sin(Math.PI * p), 8, 0.6);
        break;
      case 'drain':
        tl.draining = p < 1;
        tl.ctxShown = lerp(e.from, e.to, smooth(p));
        if (p >= 0.98) { tl.draining = false; tl.ctxShown = e.to; }
        var sw = Math.round(12 * Math.min(a || 1, 1.4));
        if (a) for (var k = 0; k < sw; k++) {
          var aa = rnd(k, 6) * TAU + p * 5, rr = g.S * 0.455 * (1 - easeOut(clamp(p * 1.2 - rnd(k, 7) * 0.3, 0, 1)) * 0.9);
          this.points.push([g.x + Math.cos(aa) * rr, g.y + Math.sin(aa) * rr, Math.max(4, L.u * 0.55), 0.4, c[0], c[1], c[2], 0.5 * Math.sin(Math.PI * clamp(p, 0, 1))]);
        }
        break;
      case 'gather':
        var pts = Math.round(36 * Math.min(a, 1.4));
        for (var m = 0; m < pts; m++) {
          var per = rnd(m, 8), side = Math.floor(per * 4), f = (per * 4) % 1;
          var tx = side === 0 ? main.x + f * main.w : side === 1 ? main.x + main.w : side === 2 ? main.x + (1 - f) * main.w : main.x;
          var ty = side === 0 ? main.y : side === 1 ? main.y + f * main.h : side === 2 ? main.y + main.h : main.y + (1 - f) * main.h;
          var fx0 = rnd(m, 9) * w.dev.w, fy0 = rnd(m, 10) * w.dev.h;
          var qg = easeOut(clamp(p * 1.25 - rnd(m, 11) * 0.25, 0, 1));
          this.points.push([lerp(fx0, tx, qg), lerp(fy0, ty, qg), Math.max(5, L.u * 0.8), 0.35, c[0], c[1], c[2], Math.sin(Math.PI * qg) * 0.55 * Math.min(a, 1.2)]);
        }
        break;
      case 'scatter':
        var sp = Math.round(28 * Math.min(a, 1.4));
        for (var z = 0; z < sp; z++) {
          var zx = main.x + rnd(z, 12) * main.w, zy = main.y + rnd(z, 13) * main.h;
          var zq = easeOut(p);
          this.points.push([zx + (rnd(z, 14) - 0.5) * L.u * 10 * zq, zy - L.u * 6 * zq * rnd(z, 15), Math.max(4, L.u * 0.7), 0.35, c[0], c[1], c[2], (1 - zq) * 0.45]);
        }
        break;
      case 'fade':
        this.pushGlyph(this.fx, g.x, g.y, g.S, 1.2, c, 0.25 * Math.sin(Math.PI * p), 8, 0.6);
        break;
    }
  };

  Engine.prototype.font = function (size, weight, mono) {
    return (weight || 400) + ' ' + size.toFixed(1) + 'px ' + (mono ? '"JetBrains Mono", "IBM Plex Mono", ui-monospace, monospace' : 'Inter, "SF Pro Text", system-ui, sans-serif');
  };

  function ellipsize(ctx, s, max) {
    if (ctx.measureText(s).width <= max) return s;
    var lo = 0, hi = s.length;
    while (lo < hi) { var mid = (lo + hi + 1) >> 1; if (ctx.measureText(s.slice(0, mid) + '…').width <= max) lo = mid; else hi = mid - 1; }
    return lo > 0 ? s.slice(0, lo).replace(/\s+$/, '') + '…' : '';
  }
  function wrap(ctx, s, max, lines, breakAny) {
    var words = breakAny ? s.split(/(?<=[\s/&|.-])/) : s.split(' ');
    var out = [], cur = '';
    for (var i = 0; i < words.length; i++) {
      var next = cur ? (breakAny ? cur + words[i] : cur + ' ' + words[i]) : words[i];
      if (ctx.measureText(next).width <= max || !cur) cur = next;
      else { out.push(cur); cur = words[i]; }
      if (out.length === lines) break;
    }
    if (out.length < lines && cur) out.push(cur);
    var used = out.join(breakAny ? '' : ' ').length;
    if (used < s.replace(/\s+$/, '').length - 1 && out.length) out[out.length - 1] = ellipsize(ctx, out[out.length - 1] + '…', max);
    for (var j = 0; j < out.length; j++) if (ctx.measureText(out[j]).width > max) out[j] = ellipsize(ctx, out[j], max);
    return { lines: out, cut: used < s.length - 1 };
  }

  Engine.prototype.drawText = function (w, dim) {
    var ctx = this.ctx, P = this.P, L = w.L, t = this.t, st = this.style, self = this;
    ctx.save();
    var sx = w.ox + w.shift[0] * w.scale, sy = w.oy + w.shift[1] * w.scale;
    ctx.beginPath();
    ctx.rect(w.ox, w.oy, w.dev.w * w.scale, w.dev.h * w.scale);
    ctx.clip();
    ctx.setTransform(w.scale, 0, 0, w.scale, sx, sy);
    ctx.globalAlpha = dim;
    ctx.textBaseline = 'alphabetic';
    var fs = L.fs;
    var mood = w.mood;
    if (w.chrome) this.drawChrome(w, ctx, mood);
    w.model.tiles.forEach(function (tl) {
      var cut = self.cellOf(w, tl.id);
      if (!cut) return;
      var op = 1;
      if (tl.leaving) op = clamp(1 - (t - tl.leaving) / 0.9, 0, 1);
      if (cut.born != null) op = Math.min(op, smooth((cut.born - 0.45) / 0.55));
      if (tl.state === 'done') op *= 1 - 0.45 * clamp((t - tl.sinceAt) / 60, 0, 1);
      ctx.globalAlpha = dim * op;
      self.drawTile(w, ctx, tl, cut);
      cut.workers.forEach(function (x) {
        var born = clamp((t - x.w.bornAt) / 1.1, 0, 1);
        ctx.globalAlpha = dim * op * smooth((born - 0.4) / 0.6) * (x.w.state === 'finished' ? 0.75 : 1);
        self.drawWorker(w, ctx, x.w, x.r);
      });
      if (cut.plus) {
        ctx.globalAlpha = dim * op;
        var pr = cut.plus.r;
        ctx.fillStyle = rgba(P.text, 0.9);
        ctx.font = self.font(Math.max(fs.title * 1.1, 14), 600);
        ctx.textAlign = 'left';
        ctx.fillText('+' + cut.plus.n, pr.x + Math.max(1 * L.u, 8), pr.y + pr.h / 2 + fs.title * 0.18);
        ctx.font = self.font(fs.small, 400);
        ctx.fillStyle = rgba(cut.plus.look ? P.needs : P.dim, 0.95);
        var lw = ctx.measureText('+' + cut.plus.n).width;
        ctx.fillText(ellipsize(ctx, cut.plus.look ? 'some need a look' : 'more agents', pr.w - lw - 3 * L.u), pr.x + Math.max(1 * L.u, 8) + lw * 1.45 + L.u, pr.y + pr.h / 2 + fs.small * 0.35);
      }
    });
    ctx.globalAlpha = dim;
    if (!w.model.tiles.length && w.chrome && L.calm) {
      ctx.textAlign = 'center';
      ctx.fillStyle = rgba(P.text, 0.92);
      ctx.font = this.font(Math.max(fs.head * 0.8, 20), 500);
      var cy = L.calm.ty || (L.calm.cy + L.calm.R * 1.6);
      ctx.fillText('All quiet', L.calm.tx + L.calm.tw / 2, cy);
      ctx.fillStyle = rgba(P.dim, 0.95);
      ctx.font = this.font(fs.watch, 400);
      ctx.fillText(ellipsize(ctx, '6 done · 1 failed · 2 stopped in the last hour, seen by this ' + w.dev.seen, L.calm.tw), L.calm.tx + L.calm.tw / 2, cy + fs.watch * 2);
    }
    if (w.hint && t < w.hint.until) {
      var hc = this.cellOf(w, w.hint.tile);
      if (hc) {
        var m = hc.main;
        ctx.globalAlpha = dim * clamp((w.hint.until - t) / 0.4, 0, 1);
        this.pill(ctx, m.x + m.w / 2, m.y + m.h / 2, 'Hold to approve', P.needs, Math.max(fs.small * 1.1, 13), true);
      }
    }
    ctx.setTransform(w.scale, 0, 0, w.scale, w.ox, w.oy);
    ctx.globalAlpha = 1;
    if (w.peek) this.drawPeek(w, ctx);
    if (w.chrome && t < w.controlsUntil) this.drawControls(w, ctx);
    else w.controlsRect = null;
    ctx.restore();
  };

  Engine.prototype.pill = function (ctx, cx, cy, text, c, size, filled) {
    ctx.font = this.font(size, 600);
    var tw = ctx.measureText(text).width, h = size * 2.1, wdt = tw + size * 2;
    ctx.beginPath();
    ctx.roundRect(cx - wdt / 2, cy - h / 2, wdt, h, h / 2);
    ctx.fillStyle = filled ? rgba(sink(c, 0.78), 0.92) : 'rgba(0,0,0,0)';
    ctx.fill();
    ctx.lineWidth = 1.2;
    ctx.strokeStyle = rgba(c, 0.85);
    ctx.stroke();
    ctx.fillStyle = rgba(c, 1);
    ctx.textAlign = 'center';
    ctx.fillText(text, cx, cy + size * 0.36);
    return wdt;
  };

  Engine.prototype.drawChrome = function (w, ctx, mood) {
    var P = this.P, L = w.L, fs = L.fs, st = this.style, t = this.t, self = this;
    var tiles = w.model.tiles.filter(function (x) { return !x.leaving; });
    var parts = [];
    var waiting = tiles.filter(function (x) { return x.state === 'needs' || x.state === 'overdue'; });
    var over = tiles.filter(function (x) { return x.state === 'overdue'; });
    if (mood.mood === 'alarm') {
      if (over.length) parts.push(over.length + ' waiting ' + fmtShort(t - over[0].sinceAt).split(' ')[0]);
      if (mood.failed) parts.push(mood.failed + ' failed');
      if (mood.working) parts.push(mood.working + ' working');
    } else if (mood.mood === 'attention') {
      if (mood.working) parts.push(mood.working + ' working');
      parts.push(waiting.length + (waiting.length === 1 ? ' needs you' : ' need you'));
    } else if (mood.mood === 'busy') {
      if (mood.working) parts.push(mood.working + ' working');
      if (mood.background) parts.push(mood.background + ' in the background');
      if (mood.quiet) parts.push(mood.quiet + ' quiet');
    }
    var headline = parts.length ? parts.join(' · ') : 'All quiet';
    var hc = mood.mood === 'calm' ? mix(P.text, P.dim, 0.25) : mood.mood === 'busy' ? lift(P.working, 0.12) : mood.mood === 'attention' ? P.needs : (mood.failed && !mood.overdue ? P.failed : P.overdue);
    var H = L.headline;
    ctx.textAlign = 'left';
    var size = H.size;
    ctx.font = this.font(size, 600);
    if (H.lines === 1) {
      while (size > 14 && ctx.measureText(headline).width > H.w) { size *= 0.94; ctx.font = this.font(size, 600); }
      ctx.fillStyle = rgba(hc, 1);
      ctx.fillText(headline, H.x, H.y + size * 0.92);
    } else {
      var wr = wrap(ctx, parts.length ? parts.map(function (x) { return x.replace(/ /g, '\u00a0'); }).join('\u00a0· ') : headline, H.w, H.lines);
      ctx.fillStyle = rgba(hc, 1);
      wr.lines.forEach(function (ln, i) { ctx.fillText(ln, H.x, H.y + size * 0.92 + i * size * 1.12); });
    }
    var subs = 0;
    tiles.forEach(function (x) { subs += x.workers.filter(function (k) { return !k.gone; }).length; });
    var listed = w.model.listed.length;
    var watch = (tiles.length || listed ? 'Watching ' + tiles.length + ' of ' + (tiles.length + listed) : 'Nothing running') + (subs ? ' · ' + subs + ' sub-agents' : '') + ' · seen by this ' + w.dev.seen;
    ctx.font = this.font(fs.watch, 400);
    ctx.fillStyle = rgba(P.dim, 1);
    if (L.mode === 'side' || L.mode === 'book' || L.mode === 'laptop') {
      var wl = wrap(ctx, watch, L.watch.w, 2);
      wl.lines.forEach(function (ln, i) { ctx.fillText(ln, L.watch.x, L.watch.y + fs.watch * (1 + i * 1.35)); });
    } else ctx.fillText(ellipsize(ctx, watch, L.watch.w), L.watch.x, L.watch.y + fs.watch);
    if (st.clock && L.clock) {
      var d = new Date();
      var hh = d.getHours(), mm = d.getMinutes();
      var time = (hh < 10 ? '0' : '') + hh + ':' + (mm < 10 ? '0' : '') + mm;
      var date = d.toLocaleDateString('en-GB', { weekday: 'short', day: 'numeric', month: 'short' });
      var C = L.clock;
      ctx.textAlign = C.align;
      ctx.font = this.font(C.size, 300);
      ctx.fillStyle = rgba(P.text, 0.94);
      ctx.fillText(time, C.x, C.y + C.size * 0.9);
      ctx.font = this.font(fs.date, 500);
      ctx.fillStyle = rgba(P.dim, 1);
      ctx.fillText(date, C.x + (C.align === 'right' ? -C.size * 0.04 : C.size * 0.04), C.y + C.size * 1.05 + fs.date * 1.1);
      ctx.textAlign = 'left';
    }
    if (L.ribbon) this.drawRibbon(w, ctx, L.ribbon);
    if (L.rails) this.drawRails(w, ctx, L.rails);
    if (L.mode === 'laptop' && L.controls) {
      var ask = tiles.filter(function (x) { return x.state === 'needs' || x.state === 'overdue'; })[0];
      var cr = L.controls;
      ctx.font = this.font(fs.small, 500);
      var ps = Math.max(fs.small * 1.15, 13);
      var first = ask ? 'Hold to approve · ' + ask.title : 'Look closer';
      ctx.font = this.font(ps, 600);
      var w1 = ctx.measureText(first).width + ps * 2, w2 = ctx.measureText('Dim').width + ps * 2, w3 = ctx.measureText('Style').width + ps * 2;
      var px0 = cr.x + (cr.w - (w1 + w2 + w3 + 20)) / 2, pcy = cr.y + cr.h / 2;
      this.pill(ctx, px0 + w1 / 2, pcy, first, ask ? P.needs : P.text, ps, !!ask);
      this.pill(ctx, px0 + w1 + 10 + w2 / 2, pcy, 'Dim', P.dim, ps, false);
      this.pill(ctx, px0 + w1 + w2 + 20 + w3 / 2, pcy, 'Style', P.dim, ps, false);
    }
    void self;
  };

  Engine.prototype.drawRibbon = function (w, ctx, r) {
    var P = this.P, seg = w.ribbon, n = seg.length, pitch = r.w / n;
    var map = { working: [P.working, 0.55], thinking: [P.thinking, 0.45], needs: [P.needs, 0.8], done: [P.finished, 0.6], failed: [P.failed, 0.85], idle: [P.dim, 0.12] };
    ctx.save();
    ctx.beginPath();
    ctx.roundRect(r.x, r.y, r.w, r.h, r.h / 2);
    ctx.clip();
    ctx.fillStyle = rgba(P.text, 0.05);
    ctx.fillRect(r.x, r.y, r.w, r.h);
    for (var i = 0; i < n; i++) {
      var x = r.x + i * pitch;
      if (seg[i] === 'unseen') {
        ctx.strokeStyle = rgba(P.dim, 0.32);
        ctx.lineWidth = 1;
        for (var s = -r.h; s < pitch; s += 4) { ctx.beginPath(); ctx.moveTo(x + s, r.y + r.h); ctx.lineTo(x + s + r.h, r.y); ctx.stroke(); }
        continue;
      }
      var m = map[seg[i]];
      ctx.fillStyle = rgba(m[0], m[1]);
      ctx.fillRect(x + 0.4, r.y, pitch - 0.8, r.h);
    }
    ctx.restore();
    ctx.fillStyle = rgba(P.text, 0.95);
    ctx.fillRect(r.x + r.w - 2, r.y - r.h * 0.6, 2, r.h * 2.2);
    if (w.L.u > 5.5) {
      ctx.font = this.font(w.L.fs.small * 0.92, 500);
      ctx.fillStyle = rgba(P.dim, 0.85);
      ctx.textAlign = 'left';
      ctx.fillText('last hour', r.x, r.y - w.L.fs.small * 0.55);
      ctx.textAlign = 'right';
      ctx.fillText('now', r.x + r.w - 6, r.y - w.L.fs.small * 0.55);
      ctx.textAlign = 'left';
    }
  };

  Engine.prototype.outcomeMark = function (ctx, x, y, s, outcome) {
    var P = this.P;
    ctx.lineWidth = Math.max(1.4, s * 0.16);
    ctx.lineCap = 'round';
    ctx.lineJoin = 'round';
    if (outcome === 'done') {
      ctx.strokeStyle = rgba(P.finished, 1);
      ctx.beginPath(); ctx.moveTo(x - s * 0.36, y); ctx.lineTo(x - s * 0.1, y + s * 0.26); ctx.lineTo(x + s * 0.38, y - s * 0.28); ctx.stroke();
    } else if (outcome === 'failed') {
      ctx.strokeStyle = rgba(P.failed, 1);
      ctx.beginPath(); ctx.moveTo(x - s * 0.26, y - s * 0.26); ctx.lineTo(x + s * 0.26, y + s * 0.26); ctx.moveTo(x - s * 0.26, y + s * 0.26); ctx.lineTo(x + s * 0.26, y - s * 0.26); ctx.stroke();
    } else {
      ctx.fillStyle = rgba(P.dim, 0.9);
      ctx.fillRect(x - s * 0.22, y - s * 0.22, s * 0.44, s * 0.44);
    }
  };

  Engine.prototype.drawRails = function (w, ctx, r) {
    var P = this.P, L = w.L, fs = L.fs, t = this.t, self = this;
    var h = r.h, x = r.x, y = r.y, size = fs.small;
    ctx.font = this.font(size * 0.86, 600);
    ctx.fillStyle = rgba(P.dim, 0.85);
    ctx.textAlign = 'left';
    var label = 'RECENT';
    ctx.fillText(label, x, y + h / 2 + size * 0.3);
    x += ctx.measureText(label).width + size;
    var limit = r.x + r.w;
    var listed = w.model.listed;
    var listedW = 0;
    if (r.w < 640 && listed.length) {
      ctx.font = this.font(size, 500);
      var more = '+' + listed.length + ' also running';
      listedW = ctx.measureText(more).width + size * 2.6;
      var mx = r.x + r.w - listedW;
      this.chip(ctx, mx, y + (h - size * 2.1) / 2, listedW, size * 2.1);
      ctx.fillStyle = rgba(P.dim, 1);
      ctx.fillText(more, mx + size * 1.3, y + h / 2 + size * 0.36);
      limit = mx - 8;
      listed = [];
    }
    if (listed.length) {
      ctx.font = this.font(size, 500);
      listed.forEach(function (c) { listedW += ctx.measureText(c.title + ' · ' + c.machine + (c.agents ? ' · ' + c.agents + ' sub-agents' : '')).width + size * 2.6 + 8; });
      ctx.font = this.font(size * 0.86, 600);
      listedW += ctx.measureText('ALSO RUNNING').width + size * 1.2;
      limit = r.x + r.w - listedW - size;
    }
    w.model.recent.forEach(function (c) {
      ctx.font = self.font(size, 500);
      var text = c.title + ' · ' + fmtShort(t - c.at) + ' ago';
      var cw = ctx.measureText(text).width + size * 3;
      if (x + cw > limit) return;
      self.chip(ctx, x, y + (h - size * 2.1) / 2, cw, size * 2.1);
      self.outcomeMark(ctx, x + size * 1.1, y + h / 2, size * 0.9, c.outcome);
      ctx.fillStyle = rgba(P.text, 0.86);
      ctx.textAlign = 'left';
      ctx.fillText(text, x + size * 2, y + h / 2 + size * 0.36);
      x += cw + 8;
    });
    if (listed.length && listedW) {
      x = r.x + r.w - listedW;
      ctx.font = this.font(size * 0.86, 600);
      ctx.fillStyle = rgba(P.dim, 0.85);
      ctx.fillText('ALSO RUNNING', x, y + h / 2 + size * 0.3);
      x += ctx.measureText('ALSO RUNNING').width + size * 1.2;
      listed.forEach(function (c) {
        ctx.font = self.font(size, 500);
        var text = c.title + ' · ' + c.machine + (c.agents ? ' · ' + c.agents + ' sub-agents' : '');
        var cw = ctx.measureText(text).width + size * 2.6;
        self.chip(ctx, x, y + (h - size * 2.1) / 2, cw, size * 2.1);
        ctx.fillStyle = rgba(P.text, 0.8);
        ctx.fillText(text, x + size * 1.3, y + h / 2 + size * 0.36);
        x += cw + 8;
      });
    }
  };

  Engine.prototype.chip = function (ctx, x, y, w, h) {
    var P = this.P;
    ctx.beginPath();
    ctx.roundRect(x, y, w, h, h / 2);
    ctx.fillStyle = rgba(P.text, 0.06);
    ctx.fill();
    ctx.lineWidth = 1;
    ctx.strokeStyle = rgba(P.text, 0.15);
    ctx.stroke();
  };

  Engine.prototype.drawBeat = function (ctx, x, y, w, h, beat, c, slide) {
    var P = this.P, n = beat.length, pitch = w / n, bar = Math.max(1.4, pitch * 0.62);
    var any = false;
    for (var k = 0; k < n; k++) if (beat[k]) { any = true; break; }
    if (!any) { ctx.fillStyle = rgba(P.dim, 0.5); ctx.fillRect(x, y + h - 2, w, 2); return; }
    ctx.save();
    ctx.beginPath(); ctx.rect(x, y - 2, w, h + 4); ctx.clip();
    for (var i = 0; i < n; i++) {
      var bx = x + (i - slide) * pitch, v = beat[i];
      if (!v) { ctx.fillStyle = rgba(P.dim, 0.35); ctx.fillRect(bx, y + h - 2, bar, 2); continue; }
      var lift2 = Math.max(h * 0.34, h * Math.min(v, 4) / 4);
      ctx.fillStyle = rgba(c, 0.6 + 0.4 * Math.min(v, 4) / 4);
      ctx.beginPath(); ctx.roundRect(bx, y + h - lift2, bar, lift2, bar / 2); ctx.fill();
    }
    ctx.restore();
  };

  Engine.prototype.drawTile = function (w, ctx, tl, cut) {
    var P = this.P, L = w.L, fs = L.fs, t = this.t, an = !this.style.reduced;
    var r = cut.main;
    var g = this.glyphCenter(w, r);
    var p = Math.max(1.3 * L.u, 9);
    var tx = g.x + g.S / 2 + Math.max(1.0 * L.u, 8);
    var tw = r.x + r.w - p - tx;
    var c = tl.inkShown || ink(P, tl.state);
    var needs = tl.state === 'needs' || tl.state === 'overdue';
    var titleSize = clamp(Math.min(fs.title, r.h * 0.16), 11.5, 40);
    var wordsSize = clamp(Math.min(fs.words * 1.22, r.h * 0.14, r.w * 0.07), 12, 46);
    var small = clamp(Math.min(fs.small, r.h * 0.12), 10.5, 30);
    var detailSize = clamp(Math.min(fs.detail, r.h * 0.12), 10.5, 30);
    ctx.textAlign = 'left';
    var meta = tl.machine + ' · ' + tl.model;
    ctx.font = this.font(small, 500);
    var metaW = ctx.measureText(meta).width;
    var showMeta = tw > metaW + titleSize * 6 && r.h > 70;
    ctx.font = this.font(titleSize, 600);
    ctx.fillStyle = rgba(P.text, 0.97);
    var titleY = g.y - g.S * 0.04;
    ctx.fillText(ellipsize(ctx, tl.title, tw - (showMeta ? metaW + small : 0)), tx, titleY);
    if (showMeta) {
      ctx.font = this.font(small, 500);
      ctx.fillStyle = rgba(P.dim, 0.95);
      ctx.textAlign = 'right';
      ctx.fillText(meta, r.x + r.w - p, titleY);
      ctx.textAlign = 'left';
    }
    var stateWord = {
      working: null, thinking: null, needs: null, overdue: null,
      retrying: 'try ' + (tl.attempt || 2), quiet: 'quiet for ' + fmtShort(t - tl.sinceAt), background: 'in the background', stuck: 'stuck',
      done: null, failed: 'failed', stopped: 'stopped', away: 'away'
    }[tl.state];
    ctx.font = this.font(small, 500);
    var age = needs ? 'waiting ' + fmtShort(t - tl.sinceAt) : tl.state === 'done' || tl.state === 'failed' ? fmtShort(t - tl.sinceAt) + ' ago' : fmtAge(t - tl.startedAt);
    ctx.fillStyle = rgba(needs ? c : P.dim, needs ? 1 : 0.92);
    var subY = titleY + small * 1.45;
    ctx.fillText(ellipsize(ctx, (stateWord ? stateWord + ' · ' : '') + age, tw), tx, subY);
    var bodyTop = Math.max(g.y + g.S / 2, subY) + Math.max(1.2 * L.u, 8);
    var bodyX = r.x + p, bodyW = r.w - 2 * p;
    var bottom = r.y + r.h - p;
    var beatH = clamp(2.4 * L.u, 12, 30);
    var hasBeat = !needs && r.h > 110 && tl.state !== 'done' && tl.state !== 'stopped';
    var footer = hasBeat ? beatH + Math.max(0.8 * L.u, 6) : 0;
    if (needs) {
      ctx.font = this.font(small, 600);
      ctx.fillStyle = rgba(c, 0.95);
      var leadY = bodyTop + small;
      if (leadY < bottom - small * 2) ctx.fillText((tl.lead || 'Wants to run').toUpperCase(), bodyX, leadY);
      var mono = clamp(Math.min(fs.words * 0.9, r.h * 0.15), 11, 40);
      ctx.font = this.font(mono, 500, true);
      var btnH = Math.max(small * 2.2, 28);
      var avail = bottom - btnH - Math.max(0.8 * L.u, 6) - (leadY + mono * 0.4);
      var maxLines = Math.max(1, Math.floor(avail / (mono * 1.3)));
      var cw = wrap(ctx, tl.cmd, bodyW, maxLines, true);
      ctx.fillStyle = rgba(P.text, 1);
      cw.lines.forEach(function (ln, i) { ctx.fillText(ln, bodyX, leadY + mono * 1.35 * (i + 1)); });
      var by = bottom - btnH;
      var hold = w.hold && w.hold.tile === tl.id ? clamp((t - w.hold.t0) / 0.8, 0, 1) : 0;
      ctx.font = this.font(small, 600);
      var label = 'Hold to approve';
      var bw = ctx.measureText(label).width + small * 2.4;
      ctx.beginPath(); ctx.roundRect(bodyX, by, bw, btnH, btnH / 2);
      ctx.fillStyle = rgba(sink(c, 0.7), 0.85); ctx.fill();
      if (hold) { ctx.save(); ctx.clip(); ctx.fillStyle = rgba(c, 0.55); ctx.fillRect(bodyX, by, bw * hold, btnH); ctx.restore(); }
      ctx.lineWidth = 1.2; ctx.strokeStyle = rgba(c, 0.9); ctx.stroke();
      ctx.fillStyle = rgba(lift(c, 0.3), 1); ctx.textAlign = 'center';
      ctx.fillText(label, bodyX + bw / 2, by + btnH / 2 + small * 0.36);
      var dw = ctx.measureText('Deny').width + small * 2.2;
      if (bodyX + bw + dw + 12 < bodyX + bodyW) {
        ctx.beginPath(); ctx.roundRect(bodyX + bw + 10, by, dw, btnH, btnH / 2);
        ctx.strokeStyle = rgba(P.text, 0.25); ctx.stroke();
        ctx.fillStyle = rgba(P.text, 0.85);
        ctx.fillText('Deny', bodyX + bw + 10 + dw / 2, by + btnH / 2 + small * 0.36);
      }
      if (cw.cut && bodyX + bw + dw + 24 + small * 6 < bodyX + bodyW) {
        ctx.textAlign = 'right'; ctx.fillStyle = rgba(P.dim, 0.9); ctx.font = this.font(small, 500);
        ctx.fillText('more in peek', bodyX + bodyW, by + btnH / 2 + small * 0.36);
      }
      ctx.textAlign = 'left';
      return;
    }
    var wordsAvail = bottom - footer - bodyTop;
    ctx.font = this.font(wordsSize, 500);
    var wordLines = Math.max(1, Math.min(3, Math.floor(wordsAvail * 0.6 / (wordsSize * 1.22))));
    if (wordsAvail < wordsSize * 0.9) wordLines = 0;
    var wcol = tl.state === 'failed' ? lift(P.failed, 0.15) : tl.state === 'away' || tl.state === 'stopped' ? P.dim : P.text;
    ctx.fillStyle = rgba(wcol, 0.96);
    var y = bodyTop + wordsSize * 0.92;
    if (wordLines) {
      var ww = wrap(ctx, tl.words, bodyW, wordLines);
      ww.lines.forEach(function (ln, i) { ctx.fillText(ln, bodyX, y + i * wordsSize * 1.2); });
      y += (ww.lines.length - 1) * wordsSize * 1.2;
    }
    if (tl.detail && y + detailSize * 1.8 < bottom - footer) {
      ctx.font = this.font(detailSize, 400, true);
      ctx.fillStyle = rgba(P.dim, 0.9);
      y += detailSize * 1.8;
      ctx.fillText(ellipsize(ctx, tl.detail, bodyW), bodyX, y);
    }
    var showHistory = /^(working|thinking|quiet|retrying|background|stuck)$/.test(tl.state) && tl.history && tl.history.length;
    if (showHistory) {
      var hs = clamp(small * 1.04, 11, 26), lh = hs * 1.7;
      var hy = y + wordsSize * 0.5 + lh;
      ctx.font = this.font(hs, 400);
      for (var hi = 0; hi < tl.history.length && hy < bottom - footer - hs * 0.4; hi++) {
        var fade = 0.85 - hi * 0.16;
        ctx.strokeStyle = rgba(P.dim, fade);
        ctx.lineWidth = Math.max(1.2, hs * 0.1);
        ctx.lineCap = 'round';
        ctx.beginPath();
        ctx.moveTo(bodyX + hs * 0.05, hy - hs * 0.32); ctx.lineTo(bodyX + hs * 0.28, hy - hs * 0.1); ctx.lineTo(bodyX + hs * 0.68, hy - hs * 0.6);
        ctx.stroke();
        ctx.fillStyle = rgba(P.dim, fade);
        ctx.fillText(ellipsize(ctx, tl.history[hi], bodyW - hs * 1.3), bodyX + hs * 1.15, hy);
        hy += lh;
      }
    }
    if (cut.dots) {
      var dy = bottom - footer - small * 0.3;
      ctx.font = this.font(small, 500);
      ctx.fillStyle = rgba(P.dim, 0.95);
      for (var i = 0; i < Math.min(cut.dots, 6); i++) { ctx.beginPath(); ctx.arc(bodyX + 4 + i * 10, dy - small * 0.35, 3, 0, TAU); ctx.fillStyle = rgba(P.working, 0.85); ctx.fill(); }
      ctx.fillStyle = rgba(P.dim, 0.95);
      ctx.fillText(cut.dots + ' sub-agents', bodyX + Math.min(cut.dots, 6) * 10 + 8, dy);
    }
    if (hasBeat) {
      var bwid = bodyW * 0.62;
      var slide = an ? (t % 1) : 0;
      this.drawBeat(ctx, bodyX, bottom - beatH, bwid, beatH, tl.beat, c, slide);
      if (tl.ctxShown != null && r.w > 260) {
        ctx.font = this.font(small, 500);
        ctx.fillStyle = rgba(tl.ctxShown > 0.85 ? P.needs : P.dim, 0.9);
        ctx.textAlign = 'right';
        ctx.fillText(Math.round(tl.ctxShown * 100) + '% context', bodyX + bodyW, bottom - 1);
        ctx.textAlign = 'left';
      }
    }
  };

  Engine.prototype.drawWorker = function (w, ctx, wk, r) {
    var P = this.P, L = w.L, fs = L.fs, t = this.t;
    var S = clamp(Math.min(r.h * 0.42, L.u * 3), 14, 30), pp = Math.max(0.9 * L.u, 7);
    var tx = r.x + pp + S + Math.max(0.7 * L.u, 6), tw = r.x + r.w - pp - tx;
    var size = clamp(Math.min(fs.worker * 1.3, r.h * 0.2), 10.5, 30);
    var twoLine = r.h > size * 3.1;
    ctx.textAlign = 'left';
    ctx.font = this.font(size, 600);
    ctx.fillStyle = rgba(P.text, 0.95);
    var age = wk.state === 'finished' ? 'done' : wk.state === 'quiet' ? 'quiet ' + fmtShort(t - (wk.quietAt || t)) : fmtShort(t - wk.startedAt);
    var cy = r.y + r.h / 2;
    ctx.font = this.font(size * 0.9, 500);
    var aw = ctx.measureText(age).width;
    ctx.font = this.font(size, 600);
    var roomy = ctx.measureText(wk.name).width + aw + 8 <= tw;
    ctx.fillText(ellipsize(ctx, wk.name, roomy ? tw - aw - 6 : tw), tx, twoLine ? cy - size * 0.25 : cy + size * 0.35);
    ctx.font = this.font(size * 0.9, 500);
    ctx.fillStyle = rgba(wk.state === 'quiet' ? P.quiet : wk.state === 'stuck' ? P.needs : P.dim, 1);
    ctx.textAlign = 'right';
    if (roomy) ctx.fillText(age, r.x + r.w - pp, twoLine ? cy - size * 0.25 : cy + size * 0.35);
    ctx.textAlign = 'left';
    if (twoLine) {
      ctx.font = this.font(size * 0.92, 400);
      ctx.fillStyle = rgba(P.dim, 1);
      var words = wk.words;
      var todoW = 0;
      if (wk.todo && tw > 120) {
        var label = wk.todo[0] + '/' + wk.todo[1];
        todoW = ctx.measureText(label).width + 30;
        var bx = r.x + r.w - pp - todoW + 4, by = cy + size * 0.68;
        ctx.fillStyle = rgba(P.text, 0.12); ctx.fillRect(bx, by - 3, 20, 3);
        ctx.fillStyle = rgba(P.working, 0.9); ctx.fillRect(bx, by - 3, 20 * wk.todo[0] / wk.todo[1], 3);
        ctx.fillStyle = rgba(P.dim, 1); ctx.textAlign = 'right';
        ctx.fillText(label, r.x + r.w - pp, cy + size * 0.95);
        ctx.textAlign = 'left';
      }
      ctx.fillText(ellipsize(ctx, words, tw - todoW), tx, cy + size * 0.95);
    }
  };

  Engine.prototype.drawPeek = function (w, ctx) {
    var P = this.P, L = w.L, fs = L.fs, t = this.t;
    var tl = findTile(w, w.peek.tile);
    if (!tl) { w.peek = null; return; }
    var pw = Math.min(w.dev.w * 0.86, 640), ph = Math.min(w.dev.h * 0.78, 520);
    var x = (w.dev.w - pw) / 2, y = (w.dev.h - ph) / 2;
    ctx.save();
    ctx.globalAlpha = 1;
    ctx.beginPath(); ctx.roundRect(x, y, pw, ph, 24);
    ctx.fillStyle = rgba(sink(P.ground, 0.25), 0.94); ctx.fill();
    ctx.lineWidth = 1; ctx.strokeStyle = rgba(P.text, 0.18); ctx.stroke();
    var pad = 24, s = Math.max(13, Math.min(fs.small * 1.05, 17));
    ctx.textAlign = 'left';
    ctx.font = this.font(s * 1.6, 600); ctx.fillStyle = rgba(P.text, 1);
    ctx.fillText(ellipsize(ctx, tl.title, pw - pad * 2), x + pad, y + pad + s * 1.3);
    ctx.font = this.font(s, 500); ctx.fillStyle = rgba(P.dim, 1);
    ctx.fillText(tl.machine + ' · ' + tl.model + ' · ' + fmtAge(t - tl.startedAt) + ' · ' + Math.round((tl.ctxShown || tl.ctx) * 100) + '% context', x + pad, y + pad + s * 3);
    var yy = y + pad + s * 5.2;
    var section = function (label) { ctx.font = this.font(s * 0.85, 600); ctx.fillStyle = rgba(P.dim, 0.9); ctx.fillText(label, x + pad, yy); yy += s * 1.7; }.bind(this);
    section('DOING NOW');
    ctx.font = this.font(s * 1.15, 500); ctx.fillStyle = rgba(P.text, 1);
    ctx.fillText(ellipsize(ctx, tl.words, pw - pad * 2), x + pad, yy); yy += s * 2.4;
    section('LAST STEPS');
    var steps = (tl.phrases && tl.phrases.length ? tl.phrases : [tl.words]).slice(0, 4);
    ctx.font = this.font(s, 400);
    for (var i = 0; i < steps.length; i++) {
      ctx.fillStyle = rgba(P.working, 0.8);
      ctx.beginPath(); ctx.arc(x + pad + 4, yy - s * 0.35, 3, 0, TAU); ctx.fill();
      ctx.fillStyle = rgba(P.text, 0.85);
      ctx.fillText(ellipsize(ctx, steps[i].replace(/^(\w+)ing/, function (m) { return m; }), pw - pad * 3), x + pad + 16, yy);
      yy += s * 1.6;
      if (yy > y + ph - 110) break;
    }
    var live = tl.workers.filter(function (k) { return !k.gone; });
    if (live.length && yy < y + ph - 120) {
      yy += s * 0.6;
      section('AGENTS');
      ctx.font = this.font(s, 400); ctx.fillStyle = rgba(P.text, 0.85);
      ctx.fillText(ellipsize(ctx, live.map(function (k) { return k.name; }).join(' · '), pw - pad * 2), x + pad, yy);
    }
    var by = y + ph - pad - 40, bx = x + pad;
    var self = this;
    ['Open chat', 'Nudge', 'Stop'].forEach(function (lbl, i) {
      ctx.font = self.font(s, 600);
      var bw = ctx.measureText(lbl).width + s * 2.4;
      ctx.beginPath(); ctx.roundRect(bx, by, bw, 40, 20);
      ctx.fillStyle = i === 0 ? rgba(P.working, 0.22) : rgba(P.text, 0.07); ctx.fill();
      ctx.strokeStyle = i === 0 ? rgba(P.working, 0.7) : rgba(P.text, 0.2); ctx.stroke();
      ctx.fillStyle = rgba(P.text, 1); ctx.textAlign = 'center';
      ctx.fillText(lbl, bx + bw / 2, by + 20 + s * 0.36);
      ctx.textAlign = 'left';
      bx += bw + 10;
    });
    ctx.font = this.font(s * 0.9, 500); ctx.fillStyle = rgba(P.dim, 0.9); ctx.textAlign = 'right';
    ctx.fillText('back to the wall in ' + Math.max(0, Math.ceil(w.peek.until - t)) + 's', x + pw - pad, by + 20 + s * 0.36);
    ctx.restore();
  };

  Engine.prototype.drawControls = function (w, ctx) {
    var P = this.P, t = this.t;
    var a = clamp((w.controlsUntil - t) / 0.4, 0, 1);
    var s = 14, h = 48;
    var items = ['Done', 'Watch', 'Now', 'Hour', w.manualDim ? 'Undim' : 'Dim', 'Style'];
    ctx.font = this.font(s, 600);
    var widths = items.map(function (x) { return ctx.measureText(x).width + s * 2; });
    var total = widths.reduce(function (p, q) { return p + q; }, 0) + 16;
    var x = (w.dev.w - total) / 2, y = w.dev.h - w.dev.safe[2] - h - 24;
    ctx.save();
    ctx.globalAlpha = a;
    ctx.beginPath(); ctx.roundRect(x, y, total, h, h / 2);
    ctx.fillStyle = rgba(sink(P.ground, 0.2), 0.86); ctx.fill();
    ctx.strokeStyle = rgba(P.text, 0.2); ctx.lineWidth = 1; ctx.stroke();
    var cx = x + 8, dimRect = null;
    for (var i = 0; i < items.length; i++) {
      var sel = items[i] === 'Watch';
      if (sel) { ctx.beginPath(); ctx.roundRect(cx, y + 7, widths[i], h - 14, (h - 14) / 2); ctx.fillStyle = rgba(P.working, 0.24); ctx.fill(); }
      ctx.fillStyle = rgba(sel ? P.text : P.text, sel ? 1 : 0.8);
      ctx.textAlign = 'center';
      ctx.fillText(items[i], cx + widths[i] / 2, y + h / 2 + s * 0.36);
      if (i === 4) dimRect = { x: cx, w: widths[i] };
      cx += widths[i];
    }
    ctx.restore();
    w.controlsRect = { x: x, y: y, w: total, h: h, dim: dimRect };
  };

  window.TailscodeWatch = { Engine: Engine, DEVICES: DEVICES, THEMES: THEMES, palette: palette, layout: layout, scene: scene };
})();
