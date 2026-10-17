// Third pass: the step list, a small head as a map, one selection. One controller renders the static artboards and the live page.
const BR = (function () {
  const ZN = ZONE_LABEL, MINUS = '−';
  const esc = RO.esc, clamp = RO.clamp;
  const ZSEQ = () => OPT.said4 ? ['say', 'think', 'sense', 'act', 'shell', 'delegate'] : ZORDER;
  const ROW = 28, ZKEYS = { think: '1', sense: '2', act: '3', shell: '4', delegate: '5', say: '6' };

  function rowsOf(turn) {
    RO.prep(turn);
    const an = turn.an;
    return turn.steps.map((s, i) => {
      const g = an.groups[s.g], pos = g.ids.indexOf(i);
      return { i, s, fam: s.fam, num: i + 1, kind: s.fam === 'think' ? 'thought' : s.fam === 'say' ? 'note' : 'tool', fan: g.ids.length > 1 ? g.ids : null, msg: s.msg };
    });
  }
  function matches(row, q) {
    if (!q) return null;
    const s = row.s, ql = q.toLowerCase();
    const hay = [s.tool, s.arg, s.text].filter(Boolean).map(x => x.toLowerCase());
    if (hay.some(h => h.includes(ql))) return 'text';
    if ((s.out || []).some(l => l.toLowerCase().includes(ql))) return 'out';
    return null;
  }
  function visible(turn, st) {
    return rowsOf(turn).filter(r => {
      if (st.zones && st.zones.size && !st.zones.has(r.fam)) return false;
      if (st.failed && r.s.status !== 'fail') return false;
      if (st.query && !matches(r, st.query)) return false;
      return true;
    });
  }
  const filtered = st => (st.zones && st.zones.size) || st.failed || st.query;

  function mark(re, text) {
    return re ? text.replace(re, m => '\u0001' + m + '\u0002') : text;
  }
  function hl(text, q) {
    if (!q) return esc(text);
    const i = text.toLowerCase().indexOf(q.toLowerCase());
    if (i < 0) return esc(text);
    return esc(text.slice(0, i)) + '<mark>' + esc(text.slice(i, i + q.length)) + '</mark>' + esc(text.slice(i + q.length));
  }
  function statusMark(s) {
    const re = s.retriedAt;
    if (s.status === 'fail' && re && OPT.compactStatus) return `<span class="stt retried"><svg width="14" height="14" viewBox="0 0 14 14"><circle cx="7" cy="7" r="5" fill="none" stroke="var(--danger)" stroke-width="1.6" stroke-dasharray="3 2.2"/></svg><span>\u2192${re}</span></span>`;
    if (s.status === 'fail' && re) return `<span class="stt retried"><svg width="14" height="14" viewBox="0 0 14 14"><circle cx="7" cy="7" r="5" fill="none" stroke="var(--danger)" stroke-width="1.6" stroke-dasharray="3 2.2"/></svg><span>retried at ${re}</span></span>`;
    if (s.status === 'fail') return OPT.compactStatus ? `<span class="stt failed"><svg width="14" height="14" viewBox="0 0 14 14"><path d="M3.5 3.5l7 7M10.5 3.5l-7 7" stroke="var(--danger)" stroke-width="1.8" stroke-linecap="round"/></svg></span>` : `<span class="stt failed"><svg width="14" height="14" viewBox="0 0 14 14"><path d="M3.5 3.5l7 7M10.5 3.5l-7 7" stroke="var(--danger)" stroke-width="1.8" stroke-linecap="round"/></svg><span>failed</span></span>`;
    if (s.status === 'wait') return `<span class="stt wait"><i class="pulse attn"></i><span>waiting</span></span>`;
    if (s.status === 'run') return `<span class="stt run"><i class="pulse"></i><span>running</span></span>`;
    if (s.status === 'stopped') return `<span class="stt stopped"><svg width="14" height="14" viewBox="0 0 14 14"><rect x="3.5" y="3.5" width="7" height="7" rx="1.5" fill="none" stroke="var(--ink2)" stroke-width="1.4" stroke-dasharray="2.5 2"/></svg><span>stopped</span></span>`;
    return '<span class="stt"></span>';
  }
  function rowHtml(turn, row, st, vis, k) {
    const s = row.s, i = row.i;
    const prev = vis[k - 1], next = vis[k + 1];
    let br = '';
    if (row.fan) {
      const up = prev && prev.msg === row.msg, dn = next && next.msg === row.msg;
      br = up && dn ? 'mid' : dn ? 'first' : up ? 'last' : '';
    }
    let cls2 = '';
    const cls = ['lr', 'f-' + row.fam, row.kind, s.status === 'fail' ? 'failed' : '', s.status === 'wait' ? 'wait' : '', s.status === 'run' ? 'run' : '', s.status === 'stopped' ? 'stopped' : '',
      st.cursor === i ? 'cursor' : '', st.hover === i ? 'hover' : '', br ? 'fan ' + br : '', (OPT.said4 && row.kind === 'note') ? 'm2' : ''].filter(Boolean).join(' ');
    const q = st.query;
    let body;
    const m2 = OPT.said4 && row.kind === 'note';
    if (m2) { cls2 = 'm2'; }
    if (row.kind === 'tool') {
      const arg = s.arg || '';
      body = `<span class="tt">${hl(s.tool, q)}</span><span class="ar" data-arg="${esc(arg)}" data-q="${esc(q || '')}">${hl(arg, q)}</span>`;
    } else {
      body = `<span class="tx" data-text="${esc(s.text)}">${hl(row.kind === 'note' && OPT.said4 ? s.text.replace(/`/g, '') : s.text, q)}</span>`;
    }
    const inOut = q && matches(row, q) === 'out' ? '<em class="inout">in output</em>' : '';
    const copy = st.hover === i && row.kind === 'tool' ? '<button class="cp" type="button">Copy</button>' : '';
    return `<div class="${cls}" role="option" aria-selected="${st.cursor === i}" data-i="${i}"><span class="br"></span><span class="gl">${m2 ? '<svg width="18" height="18" viewBox="0 0 18 18"><path d="M4 12.5c0-3 1.2-4.8 3.4-5.6l.5.9c-1.3.7-1.8 1.6-1.9 2.6h1.9v3.3H4zm6.3 0c0-3 1.2-4.8 3.4-5.6l.5.9c-1.3.7-1.8 1.6-1.9 2.6h1.9v3.3h-3.9z" fill="var(--accent)"/></svg>' : Neural.shapeSvg(row.fam, 18)}</span><span class="no">${row.num}</span>${body}${inOut}${statusMark(s)}${copy}</div>`;
  }

  function zonePanel(turn, st, o) {
    const cnt = turn.count, max = Math.max(...ZORDER.map(z => cnt[z]));
    const fails = turn.fails.length;
    const on = z => st.zones && st.zones.has(z);
    let h = `<div class="fp${o && o.tight ? ' tight' : ''}"><div class="fp-h"><span class="lbl">Filter</span><span class="k">keys 1–6</span></div>`;
    ZSEQ().filter(z => cnt[z]).forEach(z => {
      h += `<button class="fz f-${z}${on(z) ? ' on' : ''}" type="button" aria-pressed="${!!on(z)}" data-z="${z}"><span class="gl">${Neural.shapeSvg(z, 18)}</span><span class="zn">${ZN[z]}</span><span class="zb"><i style="width:${Math.round(cnt[z] / max * 100)}%"></i></span><b>${cnt[z]}</b><kbd>${ZKEYS[z]}</kbd></button>`;
    });
    if (fails) h += `<button class="fz failedtog${st.failed ? ' on' : ''}" type="button" aria-pressed="${!!st.failed}" data-failed="1"><span class="gl"><svg width="16" height="16" viewBox="0 0 14 14"><path d="M3.5 3.5l7 7M10.5 3.5l-7 7" stroke="var(--danger)" stroke-width="1.8" stroke-linecap="round"/></svg></span><span class="zn">FAILED</span><span class="zb"></span><b>${fails}</b><kbd>!</kbd></button>`;
    return h + '</div>';
  }
  function zoneChips(turn, st) {
    const cnt = turn.count, on = z => st.zones && st.zones.has(z);
    return `<div class="zchips2">${ZSEQ().filter(z => cnt[z]).map(z => z === 'say' && OPT.said4 ? `<button class="zf saidchip f-say${on(z) ? ' on' : ''}" type="button" data-z="${z}">${Neural.shapeSvg(z, 18)}<span class="zl">SAID</span><b>${cnt[z]}</b></button>` : `<button class="zf f-${z}${on(z) ? ' on' : ''}" type="button" data-z="${z}">${Neural.shapeSvg(z, 18)}<b>${cnt[z]}</b></button>`).join('')}${turn.fails.length && !OPT.said4 ? `<button class="zf failedtog${st.failed ? ' on' : ''}" type="button" data-failed="1"><svg width="16" height="16" viewBox="0 0 14 14"><path d="M3.5 3.5l7 7M10.5 3.5l-7 7" stroke="var(--danger)" stroke-width="1.8" stroke-linecap="round"/></svg><b>${turn.fails.length}</b></button>` : ''}</div>`;
  }
  function listHeader(turn, st, vis) {
    const total = turn.steps.length;
    const count = filtered(st) ? `<span class="cnt on"><b>${vis.length}</b> of ${total}</span>` : `<span class="cnt">${total} steps</span>`;
    const search = st.searchOpen || st.query
      ? `<span class="srch open"><svg width="14" height="14" viewBox="0 0 14 14"><circle cx="6" cy="6" r="4" fill="none" stroke="currentColor" stroke-width="1.5"/><path d="M9 9l3.5 3.5" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/></svg><span class="q">${esc(st.query || '')}<i class="caret"></i></span><kbd>esc</kbd></span>`
      : `<button class="srch" type="button"><svg width="14" height="14" viewBox="0 0 14 14"><circle cx="6" cy="6" r="4" fill="none" stroke="currentColor" stroke-width="1.5"/><path d="M9 9l3.5 3.5" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/></svg><span>Search</span><kbd>/</kbd></button>`;
    const ft = OPT.said4 && turn.fails.length ? `<button class="zf failedtog${st.failed ? ' on' : ''}" type="button" data-failed="1" style="height:24px"><svg width="14" height="14" viewBox="0 0 14 14"><path d="M3.5 3.5l7 7M10.5 3.5l-7 7" stroke="var(--danger)" stroke-width="1.8" stroke-linecap="round"/></svg><b>${turn.fails.length}</b><span style="font:500 11px/16px var(--sans);color:var(--ink2)">failed</span></button>` : '';
    return `<div class="lh">${search}${ft}<span class="sp"></span>${count}</div>`;
  }
  function emptyHtml(turn, st) {
    const parts = [];
    if (st.zones && st.zones.size) parts.push([...st.zones].map(z => ZN[z]).join(' + '));
    if (st.failed) parts.push('failed');
    if (st.query) parts.push('“' + st.query + '”');
    return `<div class="lempty"><div class="e1">No steps match ${esc(parts.join(' + '))}.</div><div class="e2"><button class="pb" type="button">Clear filters</button><span>or press <kbd>esc</kbd></span></div></div>`;
  }
  function listBlock(turn, st, o) {
    const vis = visible(turn, st);
    const rows = vis.length ? vis.map((r, k) => rowHtml(turn, r, st, vis, k)).join('') : emptyHtml(turn, st);
    const pill = st.live && st.following === false ? '<button class="follow" type="button">Following paused · jump to latest <kbd>End</kbd></button>' : '';
    const hint = o.hint === false ? '' : `<div class="lhint"><span><kbd>↑</kbd><kbd>↓</kbd> browse</span><span><kbd>/</kbd> filter</span><span><kbd>c</kbd> copy</span><span><kbd>?</kbd> keys</span></div>`;
    return { vis, html: `${listHeader(turn, st, vis)}<div class="lrows${o.focus ? ' focus' : ''}" role="listbox" tabindex="0" style="height:${o.rowsH}px" data-n="${vis.length}">${rows}</div>${pill}${hint}` };
  }

  /* middle-ellipsis for paths, end-ellipsis for commands, measured */
  let cv;
  function fitArgs(root) {
    cv = cv || document.createElement('canvas').getContext('2d');
    root.querySelectorAll('.ar').forEach(el => {
      const full = el.dataset.arg || '', q = el.dataset.q || '';
      const cs = getComputedStyle(el); cv.font = `${cs.fontWeight} ${cs.fontSize} ${cs.fontFamily}`;
      const w = el.clientWidth;
      if (!w || cv.measureText(full).width <= w) return;
      const isPath = /^[\w.\-\/~]+$/.test(full) && full.includes('/');
      let out;
      if (isPath) {
        const i = full.lastIndexOf('/'), fn = full.slice(i), dir = full.slice(0, i);
        let lo = 0, hi = dir.length;
        const build = n => { const a = Math.ceil(n / 2), b = Math.floor(n / 2); return dir.slice(0, a) + '…' + (b ? dir.slice(dir.length - b) : '') + fn; };
        while (lo < hi) { const mid = Math.ceil((lo + hi) / 2); if (cv.measureText(build(mid)).width <= w) lo = mid; else hi = mid - 1; }
        out = build(lo);
        if (cv.measureText(out).width > w) { let k = full.length; while (k > 6 && cv.measureText('\u2026' + full.slice(full.length - k)).width > w) k--; out = '\u2026' + full.slice(full.length - k); }
      } else {
        let n = full.length; while (n > 4 && cv.measureText(full.slice(0, n) + '…').width > w) n--;
        out = full.slice(0, n) + '…';
      }
      el.innerHTML = hl(out, q);
    });
    root.querySelectorAll('.tx').forEach(el => { el.title = el.dataset.text; });
  }

  /* ───── metrics ───── */
  function metrics(W, o) {
    o = o || {};
    const rows = o.listRows || 9;
    if (W >= 860) {
      const R = clamp(Math.round(.5 * W), 360, 640), Lw = W - 24 - R;
      const Hs = clamp(Math.round(OPT2.headK * W), 280, OPT2.headMax), Hh = Math.round(Hs * 420 / 576);
      const panelW = Lw - Hs - 16;
      const chips = panelW < 150;
      const block = 36 + rows * ROW + 4 + 24 + (chips ? 36 : 0);
      const rowH = Math.max(460, Hh + 8 + block);
      return { layout: 'split', W, R, Lw, Hs, Hh, panelW, chips, rowsH: rows * ROW, rowH, gutter: 24 };
    }
    const Hs = Math.min(W, 280), Hh = Math.round(Hs * 420 / 576);
    return { layout: 'stacked', W, R: W, Lw: W, Hs, Hh, rowsH: Math.min(rows, 10) * ROW, gutter: 0 };
  }

  /* ───── the controller ───── */
  function mount(host, turn, o) {
    RO.prep(turn);
    const M = metrics(o.W, o);
    const st = Object.assign({ cursor: -1, hover: -1, zones: null, failed: false, query: '', searchOpen: false, following: true, live: false, menu: false, legend: false, expanded: -1 }, o.state || {});
    if (st.zones && !(st.zones instanceof Set)) st.zones = new Set(st.zones);
    const theme = o.theme;
    host.innerHTML = '';
    const row = document.createElement('div');
    row.className = 'row2 ' + M.layout;
    host.appendChild(row);
    const headKey = o.headKey || (theme + '-' + RO.faceKey(turn) + '-settled');
    const ctl = { st, M, turn, row, host };

    if (M.layout === 'split') {
      row.style.cssText = `position:relative;width:${M.W}px;height:${M.rowH}px`;
      const stageLeft = M.Lw - M.Hs;
      row.innerHTML = `<div class="lcol" style="position:absolute;left:0;top:0;width:${M.Lw}px;height:${M.rowH}px">
        <div class="stage" style="position:absolute;left:${stageLeft}px;top:0;width:${M.Hs}px;height:${M.Hh}px;overflow:visible">${RO.headImgHtml(ASSET(headKey, 'stage'), M.Hs, M.Hh)}<div class="nodes"></div></div>
        ${M.chips ? '' : `<div class="fpanel" style="position:absolute;left:0;top:0;width:${M.panelW}px;height:${M.Hh}px"></div>`}
        <div class="lwrap" style="position:absolute;left:0;top:${M.Hh + 8}px;width:${M.Lw}px;height:${M.rowH - M.Hh - 8}px">${M.chips ? '<div class="chiprow"></div>' : ''}<div class="lbody"></div></div>
      </div><div class="ro-wrap" style="position:absolute;left:${M.Lw + 24}px;top:0;width:${M.R}px;height:${M.rowH}px"><i class="tab-mark" style="position:absolute;left:-1px;width:3px;height:24px;background:var(--t,var(--accent));display:none;z-index:2;border-radius:1px"></i><div class="roslot" style="height:100%"></div></div>`;
      ctl.stageEl = row.querySelector('.stage');
    } else {
      row.style.cssText = `position:relative;width:${M.W}px`;
      row.innerHTML = `<div class="stage" style="position:relative;margin:0 auto;width:${M.Hs}px;height:${M.Hh}px;overflow:visible">${RO.headImgHtml(ASSET(headKey, 'stage'), M.Hs, M.Hh)}<div class="nodes"></div></div><div class="chiprow" style="margin-top:8px"></div><div class="lbody" style="margin-top:4px"></div>`;
      ctl.stageEl = row.querySelector('.stage');
    }
    ctl.info = ST.mountNodes(ctl.stageEl, turn, { S: M.Hs, hot: null, leader: false });
    ctl.nodes = [...ctl.info.svg.querySelectorAll('.n')];
    ctl.render = () => render(ctl, o);
    render(ctl, o);
    if (!o.noFooter) host.insertAdjacentHTML('beforeend', ST.footerHtml(turn, o.W, o.footer || {}));
    return ctl;
  }

  function shown(ctl) { return ctl.st.hover >= 0 ? ctl.st.hover : ctl.st.cursor; }

  function render(ctl, o) {
    const { st, M, turn, row } = ctl;
    const lbody = row.querySelector('.lbody');
    const lb = listBlock(turn, st, { rowsH: M.rowsH, focus: st.focus === 'list', hint: M.layout === 'split' || M.W > 400 });
    ctl.vis = lb.vis;
    if (M.layout === 'split') {
      lbody.innerHTML = lb.html;
      if (M.chips) row.querySelector('.chiprow').innerHTML = zoneChips(turn, st); else row.querySelector('.fpanel').innerHTML = zonePanel(turn, st, Object.assign({}, o, { tight: M.panelW < 230 }));
    } else {
      row.querySelector('.chiprow').innerHTML = zoneChips(turn, st);
      lbody.innerHTML = lb.html;
      if (st.expanded >= 0) accordion(ctl);
    }
    const rows = lbody.querySelector('.lrows');
    if (rows) {
      const cur = st.expanded >= 0 ? st.expanded : st.cursor;
      const k = ctl.vis.findIndex(r => r.i === cur);
      const maxTop = Math.max(0, rows.scrollHeight - rows.clientHeight);
      const el = k >= 0 ? rows.querySelector(`.lr[data-i="${cur}"]`) : null;
      if (o.scrollTo != null) rows.scrollTop = o.scrollTo;
      else if (ctl.lastCur === undefined || ctl.lastCur !== cur) {
        const prev = ctl.lastTop || 0;
        if (el && (ctl.lastCur === undefined || el.offsetTop < prev || el.offsetTop + el.offsetHeight > prev + M.rowsH)) rows.scrollTop = clamp(el.offsetTop - (M.rowsH - el.offsetHeight) / 2, 0, maxTop);
        else rows.scrollTop = prev;
      } else rows.scrollTop = ctl.lastTop || 0;
      if (st.live && st.following) rows.scrollTop = rows.scrollHeight;
      ctl.lastCur = cur;
      ctl.lastTop = rows.scrollTop;
      rows.addEventListener('scroll', () => { ctl.lastTop = rows.scrollTop; });
    }
    fitArgs(lbody);
    head(ctl);
    if (M.layout === 'split') readout(ctl, o);
    if (st.menu) menu(ctl);
    if (st.legend) legend(ctl);
  }

  function head(ctl) {
    const { st, turn, info, nodes } = ctl;
    const svg = info.svg;
    svg.querySelectorAll('.leader,.hring').forEach(n => n.remove());
    const fz = filtered(st) ? new Set(ctl.vis.map(r => r.i)) : null;
    nodes.forEach((n, i) => { n.style.opacity = fz && !fz.has(i) ? .28 : ''; });
    svg.querySelectorAll('path.e').forEach(p => { p.style.opacity = fz ? .08 : ''; });
    const idx = shown(ctl);
    if (st.hover >= 0 && st.hover !== st.cursor) {
      const P = info.pos[st.hover], s = turn.steps[st.hover];
      const g = document.createElementNS('http://www.w3.org/2000/svg', 'circle');
      g.setAttribute('class', 'hring'); g.setAttribute('cx', P.x); g.setAttribute('cy', P.y); g.setAttribute('r', info.r + 7);
      g.setAttribute('style', 'fill:none;stroke:var(--accent);stroke-width:2.2px;stroke-opacity:1;stroke-dasharray:4 2.5;vector-effect:non-scaling-stroke;filter:drop-shadow(0 0 3px var(--accent))');
      svg.insertBefore(g, svg.querySelector('.n'));
    }
    const tab = ctl.row.querySelector('.tab-mark');
    if (tab) tab.style.display = 'none';
    if (idx >= 0 && ctl.M.layout === 'split') {
      ST.drawLeader(ctl.stageEl, turn, info, { hot: idx, gutter: 24, anchor: OPT.anchor, tab, rowH: ctl.M.rowH, S: ctl.M.Hs });
      if (tab) tab.style.setProperty('--t', 'var(--lead-' + turn.steps[idx].fam + ')');
    } else if (idx >= 0) {
      const P = info.pos[idx];
      const g = document.createElementNS('http://www.w3.org/2000/svg', 'circle');
      g.setAttribute('class', 'hring'); g.setAttribute('cx', P.x); g.setAttribute('cy', P.y); g.setAttribute('r', info.r + 7);
      g.setAttribute('style', 'fill:none;stroke:var(--accent);stroke-width:2.2px;vector-effect:non-scaling-stroke;filter:drop-shadow(0 0 3px var(--accent))');
      svg.insertBefore(g, svg.querySelector('.n'));
    }
  }

  function readout(ctl, o) {
    const { st, turn, M } = ctl;
    const slot = ctl.row.querySelector('.roslot');
    const idx = shown(ctl);
    let model;
    const lastIdx = turn.steps.length - 1;
    if (o.mode === 'now' && idx < 0) model = RO.nowReadout(turn, turn.steps[lastIdx], false);
    else if (idx >= 0) model = RO.stepReadout(turn, turn.steps[idx], { pinned: st.cursor === idx });
    else model = RO.digestReadout(turn);
    OPT.outMax = M.R < 480 ? 5 : 8;
    if (idx >= 0) model = RO.stepReadout(turn, turn.steps[idx], { pinned: st.cursor === idx });
    slot.innerHTML = RO.readoutHtml(model, { style: 'height:100%' });
    const bd = slot.querySelector('.ro-bd');
    if (o.mode === 'now' && idx < 0) { /* digest of nothing: Now */ }
    if (st.focus === 'readout') slot.querySelector('.ro').classList.add('focus');
  }

  function accordion(ctl) {
    const { st, turn } = ctl;
    const rows = ctl.row.querySelector('.lrows');
    const r = rows.querySelector(`.lr[data-i="${st.expanded}"]`);
    if (!r) return;
    const s = turn.steps[st.expanded];
    const m = RO.stepReadout(turn, s, { pinned: true });
    const acc = document.createElement('div');
    acc.className = 'acc f-' + s.fam;
    acc.innerHTML = `<div class="acc-h">${RO.stepReadout(turn, s).hd.replace('class="ro-hd', 'class="ro-hd2')}</div><div class="acc-b">${m.bd}</div><div class="acc-f">${m.ft.replace('class="ro-ft"', 'class="ro-ft2"')}</div>`;
    r.after(acc);
    r.classList.add('open');
    rows.style.height = 'auto'; rows.style.maxHeight = (ctl.M.rowsH + 300) + 'px';
  }

  function menu(ctl) {
    const items = ['Copy command', 'Copy output', 'Copy step as Markdown', null, 'Show only this zone', 'Go to related', 'Show in Rows'];
    const keys = { 'Copy command': 'c', 'Copy output': 'C', 'Show only this zone': '', 'Go to related': 'r' };
    const el = document.createElement('div');
    el.className = 'cmenu';
    el.innerHTML = items.map(t => t ? `<div class="mi"><span>${t}</span><kbd>${keys[t] || ''}</kbd></div>` : '<hr>').join('');
    const r = ctl.row.querySelector('.lr.cursor') || ctl.row.querySelector('.lr');
    const rb = r.getBoundingClientRect(), hb = ctl.row.getBoundingClientRect();
    el.style.left = (rb.left - hb.left + 120) + 'px'; el.style.top = (rb.top - hb.top + 20) + 'px';
    ctl.row.appendChild(el);
  }
  function legend(ctl) {
    const T = [['\u2191 \u2193  k j', 'previous, next step'], ['PgUp PgDn', '8 steps'], ['Home End  g G', 'first, last (End follows)'], ['\u2190 \u2192  h l', 'previous, next in this zone'], ['[ ]  p n', 'previous, next failed'], ['r', 'go to the related step'], ['1\u20136  0', 'zone filters, clear'], ['! x', 'failed only'], ['/', 'search steps'], ['Enter', 'into the readout, and back'], ['Space', 'expand output or diff'], ['c  C', 'copy command, output'], ['Esc', 'search, filters, cursor, close']];
    const el = document.createElement('div');
    el.className = 'legend';
    const cell = ([k, d]) => `<div class="lg-r"><span class="kk">${k.split('  ').map(g => g.split(' ').map(x => `<kbd>${x}</kbd>`).join('')).join('<i>or</i>')}</span><span class="dd">${d}</span></div>`;
    el.innerHTML = `<div class="lg-h"><span class="lbl">Keys</span><kbd>?</kbd></div><div class="lg-g">${T.map(cell).join('')}</div>`;
    el.style.left = Math.round((ctl.M.W - 760) / 2) + 'px'; el.style.top = (ctl.M.Hh + 40) + 'px';
    ctl.row.appendChild(el);
  }

  return { head, ZSEQ, mount, metrics, rowsOf, visible, listBlock, rowHtml, fitArgs, zonePanel, zoneChips, hl, ROW, filtered, statusMark, render };
})();
const OPT2 = window.OPT2 = window.OPT2 || { headK: .27, headMax: 340 };
