// Third pass artboards: O the open brain, P the list anatomy, Q the narrow accordion, R the keyboard, S the transition, and a live browse page.
function brainWin(host, theme, W, turn, o, title, noPrompt) {
  const w = win(theme, W + 56, title || 'Tailscode — conversation');
  host.appendChild(w);
  const col = w.querySelector('.col'); col.style.width = W + 'px';
  if (!noPrompt) col.insertAdjacentHTML('beforeend', promptHtml(turn));
  const h = el('<div class="open"></div>'); col.appendChild(h);
  const ctl = BR.mount(h, turn, Object.assign({ W, theme }, o));
  if (!noPrompt && turn.answer && !(o && o.noAnswer)) col.insertAdjacentHTML('beforeend', answerHtml(turn, 1));
  return { w, ctl };
}
const SUPERSEDED = ' <em style="color:#c9a25c;font-style:normal">Superseded in layout by O (section 7): the head is a small map and the step list sits under it; the readout content shown here still stands.</em>';

function artO() {
  artboard('O', 'The open brain, third pass · a small head as the map, the step list under it, the readout on the right · 1280 and 1000 px',
    '1280: a 29-step turn, the cursor on the failed ffmpeg mux (step 25, inside the SHELL ganglion: the head rings the “+7” and the leader runs from it). 1000: the 14-step build turn with the cursor on the failed swift build. The list is scrolled so the cursor row is visible; the zone panel left of the head is the filter and the digest’s zone bars in one; count, search and hint sit around the list.',
    host => {
      const col = el('<div style="display:flex;flex-direction:column;gap:28px"></div>'); host.appendChild(col);
      const big = TURNS.big; RO.prep(big);
      const fail = big.steps.findIndex(s => s.status === 'fail');
      brainWin(col, 'rose', 1280, big, { state: { cursor: fail, focus: 'list' }, listRows: 9, noAnswer: false });
      brainWin(col, 'rose', 1000, TURNS.fix, { state: { cursor: 5, focus: 'list' }, listRows: 8 });
    }, { gap: 0 });
}
function artO2() {
  artboard('O2', 'A 174-step turn, browsed · SHELL filtered, the cursor on a failure · 1280 and 1000 px',
    'Six repeats of the demo turn: 174 steps, 108 of them shell. Filtering to SHELL and failed leaves a list of 3 that is read at a glance; with SHELL only it is 108 rows (9 on screen, kinetic wheel, PageUp/Down 8, g/G, [ and ] jump between the failures). The head dims everything else to 28 percent.',
    host => {
      const col = el('<div style="display:flex;flex-direction:column;gap:28px"></div>'); host.appendChild(col);
      const t = TURNS.huge; RO.prep(t);
      const fails = t.steps.map((s, i) => s.status === 'fail' ? i : -1).filter(i => i >= 0);
      brainWin(col, 'tokyo', 1280, t, { state: { cursor: fails[1], zones: ['shell'], focus: 'list' }, listRows: 9, headKey: 'tokyo-sonnet3-settled' }, 'Tailscode — SHELL only', true);
      brainWin(col, 'tokyo', 1000, t, { state: { cursor: fails[1], zones: ['shell'], failed: true, focus: 'list' }, listRows: 8, headKey: 'tokyo-sonnet3-settled' }, 'Tailscode — SHELL and failed', true);
    }, { gap: 0 });
}

function listOnly(host, theme, turn, st, W, rowsN, extra) {
  const w = el(`<div class="pbox" data-theme="${theme}" data-light="${PAL[theme].dark === '0' ? 1 : 0}" style="width:${W + 24}px;position:relative"><div class="lbody" style="width:${W}px"></div></div>`);
  host.appendChild(w);
  const st2 = Object.assign({ cursor: -1, hover: -1, zones: null, failed: false, query: '', following: true }, st); if (st2.zones && !(st2.zones instanceof Set)) st2.zones = new Set(st2.zones);
  const lb = BR.listBlock(turn, st2, { rowsH: rowsN * 28, hint: extra && extra.hint === false ? false : true, focus: !!(st && st.focus) });
  w.querySelector('.lbody').innerHTML = lb.html;
  BR.fitArgs(w);
  return w;
}
function artP() {
  artboard('P', 'The list anatomy · every row state, hover, cursor, filter, search, follow, empty, menu',
    'Rows are 28 px: a 3 px zone edge, 18 px glyph, tabular number, heading-weight title, the argument in mono (a path middle-ellipsised so the file name survives, a command cut at the end), and the status on the right. The cursor is an accent wash with a 1 px accent ring and a 2 px accent bar inside the zone edge; the failed wash is 8 percent danger and loses to the cursor wash while keeping its mark.',
    host => {
      const g = el('<div class="ab-sheet" style="grid-template-columns:640px 640px;align-items:start"></div>'); host.appendChild(g);
      const st = TURNS.states; RO.prep(st);
      const caps = ['thought', 'done', 'done · fan-out bracket (three calls of one message)', 'done · fan-out', 'failed and retried: dashed ring, “retried at 7”', 'note (the agent speaking)', 'done: the retry', 'failed: danger wash, mark', 'stopped: quiet dashed mark', 'waiting on approval: attention pulse', 'running: the live pulse'];
      const p1 = el('<div class="pp" style="grid-column:1/-1"><div class="pt">Every row state</div></div>'); g.appendChild(p1);
      const box = el('<div style="display:grid;grid-template-columns:620px 600px;gap:12px"></div>'); p1.appendChild(box);
      const lh = el('<div></div>'); box.appendChild(lh);
      const w = listOnly(lh, 'rose', st, { cursor: -1, hover: -1 }, 600, 11, { hint: false });
      w.querySelector('.lh').remove();
      box.insertAdjacentHTML('beforeend', `<div class="cap" style="display:flex;flex-direction:column;padding-top:12px;width:600px">${caps.map(c => `<div style="height:28px;display:flex;align-items:center;font:11.5px/14px var(--sans);color:#8f8f9a">${c}</div>`).join('')}</div>`);
      p1.querySelector('.pbox').style.width = '624px';

      const p2 = el('<div class="pp"><div class="pt">Hover with its copy button · the cursor · a failed row under the cursor</div><div class="pn">Row 3 is hovered (6 percent wash, Copy at the right edge, the status steps aside), row 5 holds the cursor, row 8 is a failed row that is also the cursor in the second list: the cursor wash wins, the mark stays.</div></div>'); g.appendChild(p2);
      listOnly(p2, 'rose', st, { cursor: 4, hover: 2 }, 600, 6, { hint: false });
      const p2a = listOnly(p2, 'rose', st, { cursor: 7, hover: -1 }, 600, 4, { hint: false }); p2a.querySelector('.lh').remove();
      const p2b = listOnly(p2, 'dawn', st, { cursor: 7, hover: 2 }, 600, 6, { hint: false }); p2b.querySelector('.lh').remove();

      const big = TURNS.big; RO.prep(big);
      const p3 = el('<div class="pp"><div class="pt">A hovered row rings its node · the readout previews it</div><div class="pn">Hover never moves the cursor. The dashed accent ring is the preview; the solid ring and leader belong to the cursor.</div></div>'); g.appendChild(p3);
      const h3 = el('<div class="pbox" data-theme="rose"></div>'); p3.appendChild(h3);
      BR.mount(h3, TURNS.fix, { W: 600, theme: 'rose', state: { cursor: 5, hover: 7 }, listRows: 5, noFooter: true, headKey: 'rose-sonnet3-hover-act' });

      const p4 = el('<div class="pp"><div class="pt">A filter applied · “5 of 29” · the head dims the rest to 28 percent</div><div class="pn">SENSE and ACT are on. The chips carry the count; the list and the head show the same five steps.</div></div>'); g.appendChild(p4);
      const h4 = el('<div class="pbox" data-theme="rose"></div>'); p4.appendChild(h4);
      BR.mount(h4, big, { W: 600, theme: 'rose', state: { zones: ['sense', 'act'] }, listRows: 5, noFooter: true });

      const p5 = el('<div class="pp"><div class="pt">Search open · matches highlighted · Enter takes the first</div><div class="pn">The field filters by title, argument and output; a row that matches only in its output says so.</div></div>'); g.appendChild(p5);
      listOnly(p5, 'rose', big, { query: 'cut-list', searchOpen: true, cursor: -1, focus: false }, 600, 6, {});

      const p6 = el('<div class="pp"><div class="pt">A live turn · following paused</div><div class="pn">The list follows the newest step until the person scrolls up or sets a cursor; the pill brings it back (End).</div></div>'); g.appendChild(p6);
      const lv = TURNS.live;
      const w6 = listOnly(p6, 'rose', lv, { live: true, following: false, cursor: 6 }, 600, 7, {});
      const rows6 = w6.querySelector('.lrows'); rows6.scrollTop = 40;

      const p7 = el('<div class="pp"><div class="pt">Empty filter · the way out is named</div></div>'); g.appendChild(p7);
      listOnly(p7, 'rose', big, { zones: ['delegate'], failed: true }, 600, 4, {});

      const p8 = el('<div class="pp"><div class="pt">Right-click · the row menu</div><div class="pn">Copy command or path, Copy output, Copy step as Markdown, Show only this zone, Go to related, Show in Rows. The same menu opens from a node.</div></div>'); g.appendChild(p8);
      const w8 = listOnly(p8, 'rose', st, { cursor: 7 }, 600, 8, { hint: false });
      BR.fitArgs(w8);
      const m = BR.mountMenu ? null : null;
      const menuEl = el('<div class="cmenu" style="left:150px;top:150px"><div class="mi"><span>Copy command</span><kbd>c</kbd></div><div class="mi" style="background:transparent"><span>Copy output</span><kbd>C</kbd></div><div class="mi" style="background:transparent"><span>Copy step as Markdown</span><kbd></kbd></div><hr><div class="mi" style="background:transparent"><span>Show only this zone</span><kbd>4</kbd></div><div class="mi" style="background:transparent"><span>Go to related</span><kbd>r</kbd></div><div class="mi" style="background:transparent"><span>Show in Rows</span><kbd></kbd></div></div>');
      w8.appendChild(menuEl);
    }, { gap: 0 });
}

function artQ() {
  artboard('Q', 'Narrow · the accordion at 520 and 380 px',
    'Under 860 px the head stays on top (320 wide at most, centred), the zone chips follow, then the list full width: the cursor row expands in place into the readout’s content, one at a time, so a phone, a split pane and the desktop browse the same list the same way. The ringed node is the cursor.',
    host => {
      [[520, 5, TURNS.fix], [380, 5, TURNS.fix]].forEach(([W, cur, t]) => {
        const w = win('rose', W + 40, W + ' px');
        host.appendChild(w);
        const col = w.querySelector('.col'); col.style.width = W + 'px'; col.style.padding = '16px 0';
        col.insertAdjacentHTML('beforeend', promptHtml(t).replace('class="prompt"', 'class="prompt" style="font-size:13.5px"'));
        const h = el('<div class="open"></div>'); col.appendChild(h);
        BR.mount(h, t, { W, theme: 'rose', state: { cursor: cur, expanded: cur }, listRows: 7, headKey: 'rose-sonnet3-hover-shell' });
      });
      const w = win('dawn', 560, 'Dawn · 520');
      host.appendChild(w);
      const col = w.querySelector('.col'); col.style.width = '520px'; col.style.padding = '16px 0';
      const h = el('<div class="open"></div>'); col.appendChild(h);
      BR.mount(h, TURNS.big, { W: 520, theme: 'dawn', state: { zones: ['shell'], cursor: 7 }, listRows: 8 });
    }, { gap: 24 });
}

function artR() {
  artboard('R', 'The keyboard · the focus ring on the list, the legend, the one-line hint',
    'Tab enters the brain and lands on the list, which wears a 2 px accent ring; every key also works from the stage. ? opens the key legend as a popover over the head (Esc or ? closes it). The hint under the list is one line of four verbs and disappears when the column is narrower than 340 px.',
    host => {
      const col = el('<div style="display:flex;flex-direction:column;gap:28px"></div>'); host.appendChild(col);
      brainWin(col, 'rose', 1000, TURNS.fix, { state: { cursor: 5, focus: 'list', legend: true }, listRows: 8 });
      brainWin(col, 'phosphor', 1000, TURNS.fix, { state: { cursor: 7, focus: 'readout' }, listRows: 8, headKey: 'phosphor-sonnet3-hover-shell' }, 'Phosphor — focus in the readout (Enter)');
    }, { gap: 0 });
}

/* ───── a live, working browse page ───── */
function artLive() {
  artboard('O3', 'Live · browse it with the mouse and the keyboard',
    'Everything in the key table works here: click rows and nodes, hover to preview, the zone panel toggles, 1 to 6, !, /, [ ], r, j k, PageUp/Down, Home/End, c, ?, Esc in its four steps.',
    host => {
      const w = win('rose', 1336, 'Tailscode — live browse');
      host.appendChild(w);
      const col = w.querySelector('.col'); col.style.width = '1280px';
      const h = el('<div class="open"></div>'); col.appendChild(h);
      const ctl = BR.mount(h, TURNS.big, { W: 1280, theme: 'rose', state: { cursor: -1 }, listRows: 9 });
      liveBrowse(ctl, w);
    });
}
function liveBrowse(ctl, root) {
  const st = ctl.st, turn = ctl.turn;
  const toast = el('<div style="position:absolute;right:24px;top:48px;z-index:30;padding:6px 12px;border-radius:14px;background:var(--raised);border:1px solid var(--accent);font:12px/16px var(--sans);color:var(--ink);display:none"></div>');
  root.style.position = 'relative'; root.appendChild(toast);
  const say = t => { toast.textContent = t; toast.style.display = 'block'; clearTimeout(say.t); say.t = setTimeout(() => toast.style.display = 'none', 1100); };
  const vis = () => BR.visible(turn, st);
  const re = () => { ctl.render(); };
  const setCursor = i => { st.cursor = i; st.hover = -1; re(); };
  const move = d => {
    const v = vis(); if (!v.length) return;
    const k = v.findIndex(r => r.i === st.cursor);
    const n = clamp(k < 0 ? (d > 0 ? 0 : v.length - 1) : k + d, 0, v.length - 1);
    setCursor(v[n].i);
  };
  const clamp = (v, a, b) => Math.max(a, Math.min(b, v));
  const zoneStep = d => {
    if (st.cursor < 0) return;
    const fam = turn.steps[st.cursor].fam;
    const same = vis().filter(r => r.fam === fam);
    const k = same.findIndex(r => r.i === st.cursor);
    const n = same[clamp(k + d, 0, same.length - 1)];
    if (n) setCursor(n.i);
  };
  const failedStep = d => {
    const f = turn.steps.map((s, i) => s.status === 'fail' ? i : -1).filter(i => i >= 0);
    if (!f.length) return;
    const nx = d > 0 ? f.find(i => i > st.cursor) : [...f].reverse().find(i => i < st.cursor);
    setCursor(nx != null ? nx : (d > 0 ? f[0] : f[f.length - 1]));
  };
  const toggleZone = z => { if (!st.zones) st.zones = new Set(); st.zones.has(z) ? st.zones.delete(z) : st.zones.add(z); re(); };
  function key(e) {
    if (st.searchOpen) {
      if (e.key === 'Escape') { st.query = ''; st.searchOpen = false; re(); e.preventDefault(); return; }
      if (e.key === 'Enter') { const v = vis(); st.searchOpen = false; if (v.length) st.cursor = v[0].i; re(); e.preventDefault(); return; }
      if (e.key === 'Backspace') { st.query = st.query.slice(0, -1); re(); e.preventDefault(); return; }
      if (e.key.length === 1 && !e.ctrlKey && !e.metaKey) { st.query += e.key; re(); e.preventDefault(); return; }
      return;
    }
    const k = e.key;
    const ZK = { 1: 'think', 2: 'sense', 3: 'act', 4: 'shell', 5: 'delegate', 6: 'say' };
    let used = true;
    if (k === 'ArrowDown' || k === 'j') move(1);
    else if (k === 'ArrowUp' || k === 'k') move(-1);
    else if (k === 'PageDown') move(8); else if (k === 'PageUp') move(-8);
    else if (k === 'Home' || k === 'g') { const v = vis(); if (v.length) setCursor(v[0].i); }
    else if (k === 'End' || k === 'G') { const v = vis(); if (v.length) setCursor(v[v.length - 1].i); }
    else if (k === 'ArrowRight' || k === 'l') zoneStep(1);
    else if (k === 'ArrowLeft' || k === 'h') zoneStep(-1);
    else if (k === ']' || k === 'n') failedStep(1);
    else if (k === '[' || k === 'p') failedStep(-1);
    else if (ZK[k]) toggleZone(ZK[k]);
    else if (k === '0') { st.zones = null; re(); }
    else if (k === '!' || k === 'x') { st.failed = !st.failed; re(); }
    else if (k === '/') { st.searchOpen = true; re(); }
    else if (k === 'r') { const s = turn.steps[st.cursor]; if (s) { const rel = RO.relations(turn, s)[0]; if (rel) setCursor(rel.ids[0]); } }
    else if (k === 'c') say('Copied command'); else if (k === 'C') say('Copied output');
    else if (k === '?') { st.legend = !st.legend; re(); }
    else if (k === 'Enter') { st.focus = st.focus === 'readout' ? 'list' : 'readout'; re(); }
    else if (k === 'Escape') {
      if (st.legend) st.legend = false; else if (st.query) st.query = ''; else if (st.zones && st.zones.size || st.failed) { st.zones = null; st.failed = false; } else if (st.cursor >= 0) st.cursor = -1; else say('Esc four: the brain would collapse');
      re();
    } else used = false;
    if (used) e.preventDefault();
  }
  document.addEventListener('keydown', key);
  root.addEventListener('click', e => {
    const r = e.target.closest('.lr'), z = e.target.closest('[data-z]'), f = e.target.closest('[data-failed]');
    if (z) { if (e.shiftKey) st.zones = new Set([z.dataset.z]); else toggleZone(z.dataset.z); re(); return; }
    if (f) { st.failed = !st.failed; re(); return; }
    if (e.target.closest('.srch')) { st.searchOpen = true; re(); return; }
    if (e.target.closest('.cp')) { say('Copied'); return; }
    if (e.target.closest('.follow')) { st.following = true; re(); return; }
    if (r) { setCursor(+r.dataset.i); return; }
    const n = e.target.closest('.n');
    if (n) { const i = ctl.nodes.indexOf(n); if (i >= 0) setCursor(i); }
  });
  root.addEventListener('mouseover', e => {
    const r = e.target.closest('.lr'), n = e.target.closest('.n');
    const i = r ? +r.dataset.i : n ? ctl.nodes.indexOf(n) : -1;
    if (i !== st.hover) { st.hover = i; if (!ctl.lock) { const sc = root.querySelector('.lrows'); const top = sc && sc.scrollTop; re(); const sc2 = root.querySelector('.lrows'); if (sc2 && top != null) sc2.scrollTop = top; } }
  });
  root.addEventListener('mouseleave', () => { st.hover = -1; re(); });
  root.addEventListener('contextmenu', e => { const r = e.target.closest('.lr'); if (r) { e.preventDefault(); st.cursor = +r.dataset.i; st.menu = true; re(); st.menu = false; } });
  ctl.opts = ctl.opts || {};
}

function artS() {
  artboard('S', 'The transition, third pass · card to the small head, the list and the readout · eight frames',
    'Same curves as section 3. The card’s picture travels to the head’s small rect (left column, next to the readout), the nodes arrive in step order, the filter panel and header fade in at 150 ms and the list rows slide in one after another from 130 ms (12 ms apart, 6 px), the readout slides 24 px, the footer arrives last. Row 1000 px wide at 60 percent.',
    host => {
      const grid = el('<div style="display:grid;grid-template-columns:repeat(4,max-content);gap:20px"></div>'); host.appendChild(grid);
      const Z = .6, W = 1000;
      M_TIMES.forEach(([t, dir]) => {
        const cw = Math.round((W + 56) * Z);
        const cell = el(`<div style="width:${cw}px"><div class="lbl" style="color:#8f8f9a;margin:0 0 8px;font-family:var(--mono)">${dir === 'close' ? 'closing' : 'opening'} · ${t} ms</div><div class="mf" data-theme="rose" style="width:${cw}px;overflow:hidden;border:1px solid var(--rule);border-radius:10px;background:var(--bg)"><div class="mfi" style="width:${W + 56}px;padding:28px;transform:scale(${Z});transform-origin:0 0"></div></div><div class="mnum" style="font:11px/16px var(--mono);color:#8f8f9a;margin-top:6px"></div></div>`);
        grid.appendChild(cell);
        const h = el('<div></div>'); cell.querySelector('.mfi').appendChild(h);
        const m = TR2.mount(h, TURNS.big, { W, theme: 'rose' });
        const fr = m.apply(t, dir);
        cell.querySelector('.mnum').textContent = `g ${fr.g.toFixed(2)} · row ${Math.round(m.row.offsetHeight)} px · readout α ${fr.readoutAlpha.toFixed(2)} · sweep ${fr.sweepAmt.toFixed(2)}`;
        cell.querySelector('.mf').style.height = Math.round((m.full + 56) * Z) + 'px';
      });
    }, { gap: 0 });
}
function artSLive() {
  artboard('S2', 'The transition, live · third pass · run it or scrub it',
    'Open and Close run the real choreography at display rate; the slider scrubs; ¼ speed shows each part. A press during a move reverses from where it is.',
    host => { liveWidget(host, 'rose', 1280, TR2.mount); });
}
