// Artboards of the board page. Each is built from the shared library; window.__ready flips when all are laid out.
function ASSET(key, kind) {
  const m = kind === 'card' ? CARDS : STAGE;
  if (m[key]) return m[key];
  const alt = Object.keys(m).find(k => k.endsWith(key.replace(/^[a-z]+-/, '-'))) || Object.keys(m)[0];
  return m[alt];
}
const TH = ['rose', 'dawn', 'tokyo', 'phosphor'];

function el(html) { const t = document.createElement('template'); t.innerHTML = html.trim(); return t.content.firstChild; }
const SUP = new Set(['L', 'L2', 'L3', 'L4', 'L5', 'L6', 'L7', 'M', 'M2', 'N', 'O', 'O2', 'O3', 'P', 'Q', 'R', 'S', 'S2']);
const SUPNOTE = ' <em style="color:#c9a25c;font-style:normal">Superseded in layout by the third pass (O, P, Q, R, S; section 7): the head is now a small map with the step list under it. The readout content shown here still stands.</em>';
function artboard(id, title, note, builder, opt) {
  opt = opt || {};
  if (SUP.has(id)) note = (note || '') + SUPNOTE;
  if (['O', 'O2', 'O3', 'P', 'Q', 'R', 'S', 'S2'].includes(id)) note = (note || '') + ' <em style="color:#c9a25c;font-style:normal">The right side shown here (the step readout) is superseded by the account (T, section 8).</em>';
  const wrap = el(`<section class="ab-wrap" id="ab-${id}"><div class="ab-cap"><b>${id}</b> · ${title}</div><div class="ab-body" style="display:flex;gap:${opt.gap || 24}px;align-items:flex-start"></div>${note ? `<p class="ab-note">${note}</p>` : ''}</section>`);
  document.getElementById('board').appendChild(wrap);
  builder(wrap.querySelector('.ab-body'));
  return wrap;
}
function win(theme, width, title, extraStyle) {
  return el(`<div class="win" data-theme="${theme}" data-light="${PAL[theme].dark === '0' ? 1 : 0}" style="width:${width}px;${extraStyle || ''}"><div class="win-bar"><span class="dot"></span><span>${title || 'Tailscode'}</span><span class="sp"></span><span>${PAL[theme].name}</span></div><div class="col"></div></div>`);
}

function promptHtml(t) { return `<div class="prompt">${RO.esc(t.prompt)}</div>`; }
function answerHtml(t, n) {
  if (!t.answer) return '';
  return `<div class="answer">${t.answer.slice(0, n || 1).map(p => '<p>' + RO.esc(p).replace(/`([^`]+)`/g, '<code>$1</code>').replace(/(out\/demo\/[\w.\-]+|TranscriptRows\.swift|parity\.sh)/g, '<span class="prov">$1</span>') + '</p>').join('')}</div>`;
}

function fillWin(w, W, items) {
  const col = w.querySelector('.col');
  col.style.width = W + 'px';
  items(col);
}

/* ───── K: the cards ───── */
function artK() {
  const turns = [TURNS.calm, TURNS.fix, TURNS.big];
  artboard('K', 'The card · three turns · Comfortable and Compact · Rosé Pine and Dawn',
    'Left edge is the turn’s tone. The picture is the head at rest with one light per zone sized by what the turn did there; a dashed danger ring marks a failure that was repaired, a full one a failure that was not. The third card in the first column shows the pointer over it.',
    host => {
      ['rose', 'dawn'].forEach(theme => {
        const w = win(theme, 776, 'Tailscode — conversation');
        host.appendChild(w);
        fillWin(w, 720, col => {
          ['comfortable', 'compact'].forEach((den, di) => {
            col.insertAdjacentHTML('beforeend', `<div class="lbl" style="color:var(--ink2);margin:${di ? 28 : 0}px 0 12px;display:flex;gap:12px"><span>${den}</span><span style="font:11px/16px var(--mono);letter-spacing:0;text-transform:none">${den === 'compact' ? 'card 84 px · picture 112×73' : 'card 112 px · picture 148×97'}</span></div>`);
            turns.forEach((t, i) => {
              const hov = theme === 'rose' && den === 'comfortable' && t.id === 'big';
              col.insertAdjacentHTML('beforeend', `<div style="margin:${den === 'compact' ? 12 : 16}px 0 0">${promptHtml(t)}${RO.cardHtml(t, { theme, density: den, hover: hov })}<div class="answer dim" style="margin:${den === 'compact' ? 10 : 14}px 0 0;font-size:14px;line-height:22px;max-height:44px;overflow:hidden">${RO.esc(t.answer[0].replace(/`/g, ''))}</div></div>`);
            });
          });
        });
      });
    });
}

function artK2() {
  artboard('K2', 'Card edge tones · repaired · failed · waiting · stopped',
    'The edge and the ring say what became of the turn before a number is read. Only a failure that was not repaired wears the danger edge; a repaired one keeps the settled edge and a dashed ring, so a column of cards still reads as mostly fine.',
    host => {
      const w = win('rose', 776, 'Tailscode — conversation');
      host.appendChild(w);
      const failed = JSON.parse(JSON.stringify({ id: 'failed', family: 'haiku', effort: 2, dur: '0m 41s', prompt: 'Install the Mac build on the macbook.', steps: [
        { fam: 'think', tool: 'Thinking', status: 'ok', msg: 1, at: '09:12:02', text: 'The Mac client builds on the macbook over the tailnet.' },
        { fam: 'shell', tool: 'Bash', status: 'ok', msg: 2, at: '09:12:09', arg: 'rsync -a --delete ./ macbook:~/Tailscode/', out: ['sent 41.2M bytes'] },
        { fam: 'shell', tool: 'Bash', status: 'fail', msg: 3, at: '09:12:43', arg: 'ssh macbook ./scripts/install-macapp.sh', out: ['ssh: connect to host macbook port 22: Operation timed out'] }
      ] }));
      TURNS.failed = failed;
      const faceOf = { haiku: 'sonnet3' };
      fillWin(w, 720, col => {
        const rows = [[failed, 'failed', 'Install the Mac build on the macbook.'], [TURNS.wait, 'wait', 'Make a product demonstration using mock data.'], [TURNS.fix, 'settled', 'Fix the Linux build: it stops in TranscriptRows.'], [Object.assign({}, TURNS.calm, { id: 'stopped', steps: TURNS.calm.steps.slice(0, 4).map(s => Object.assign({}, s)), dur: '12s' }), 'stopped', 'Where does the quota strip decide which window is tightest?']];
        rows.forEach(([t, st, p]) => {
          t.family = t.family === 'haiku' ? 'sonnet' : t.family;
          const tt = t === TURNS.wait ? Object.assign({}, t, { steps: t.steps.slice(0, 23) }) : t;
          col.insertAdjacentHTML('beforeend', `<div style="margin:0 0 20px"><div class="prompt">${RO.esc(p)}</div>${RO.cardHtml(tt, { theme: 'rose', density: 'comfortable', state: st })}</div>`);
        });
      });
    });
}

/* ───── the open row, used by L, L2, L3, L4, L5, N ───── */
function buildOpen(host, turn, o) {
  const b = ST.build(host, turn, o);
  OPT.outMax = b.M.R < 480 ? 5 : 8;
  const M = b.M, H = M.layout === 'stacked' ? null : Math.max(M.H, 300);
  let model;
  const s = o.hot != null && o.hot >= 0 ? turn.steps[o.hot] : null;
  if (o.mode === 'now' || o.mode === 'ask') model = RO.nowReadout(turn, s || turn.steps[turn.steps.length - 1], o.mode === 'ask');
  else if (o.mode === 'zone') model = RO.zoneReadout(turn, o.zone, o.sel);
  else if (s) model = RO.stepReadout(turn, s, { pinned: o.pinned });
  else model = RO.digestReadout(turn);
  b.wrap.insertAdjacentHTML('beforeend', RO.readoutHtml(model, { style: H ? `height:${H}px` : '' }));
  b.info = ST.mountNodes(b.stage, turn, Object.assign({ S: M.S }, o, { gutter: M.gutter }));
  if (o.diveZone) applyDive(b.stage, b.info, o.diveZone);
  if (!o.noFooter) host.insertAdjacentHTML('beforeend', ST.footerHtml(turn, o.W, o.footer));
  return b;
}
function applyDive(stage, info, zone) {
  const c = Neural.ZONES[zone], s = 2.2;
  info.svg.style.transformOrigin = (c[0] / 640 * 100) + '% ' + (c[1] / 420 * 100) + '%';
  info.svg.style.transform = 'scale(' + s + ')';
}

function openWin(theme, W, turn, o, title) {
  const w = win(theme, W + 56, title || 'Tailscode — conversation');
  document.querySelector('#board .ab-wrap:last-child .ab-body').appendChild(w);
  const col = w.querySelector('.col');
  col.style.width = W + 'px';
  col.insertAdjacentHTML('beforeend', promptHtml(turn));
  const host = el('<div class="open"></div>');
  col.appendChild(host);
  const b = buildOpen(host, turn, Object.assign({ W, theme }, o));
  if (o.answer !== false) col.insertAdjacentHTML('beforeend', answerHtml(turn, 1));
  return { w, b };
}
function artL() {
  artboard('L', 'The open brain · readout on a shell step · 1280 and 1000 px chat columns',
    'Step 6 of 14, a failed swift build. Stage 696 px and readout 560 px at 1280; stage 540 and readout 436 at 1000. The leader leaves the node on the wires’ 45-degree routing and ends in a dot on the readout’s edge.',
    host => {
      const fix = TURNS.fix;
      const wrapH = document.getElementById('board');
      const r1 = el('<div style="display:flex;flex-direction:column;gap:24px"></div>');
      host.appendChild(r1);
      [1280, 1000].forEach(W => {
        const holder = el('<div></div>');
        r1.appendChild(holder);
        const w = win('rose', W + 56, 'Tailscode — conversation');
        holder.appendChild(w);
        const col = w.querySelector('.col'); col.style.width = W + 'px';
        col.insertAdjacentHTML('beforeend', promptHtml(fix));
        const h = el('<div class="open"></div>'); col.appendChild(h);
        buildOpen(h, fix, { W, theme: 'rose', hot: 5, pinned: false, mode: 'step', headKey: 'rose-sonnet3-hover-shell', anchor: OPT.anchor });
        col.insertAdjacentHTML('beforeend', answerHtml(fix, 1));
      });
    }, { gap: 0 });
}

function openIn(host, theme, W, turn, o, extra) {
  const w = win(theme, W + 56, (extra && extra.title) || 'Tailscode — conversation');
  if (extra && extra.zoom) w.style.zoom = extra.zoom;
  host.appendChild(w);
  const col = w.querySelector('.col'); col.style.width = W + 'px';
  if (!(extra && extra.noPrompt)) col.insertAdjacentHTML('beforeend', promptHtml(turn));
  const h = el('<div class="open"></div>'); col.appendChild(h);
  const b = buildOpen(h, turn, Object.assign({ W, theme }, o));
  if (!(extra && extra.noAnswer) && turn.answer) col.insertAdjacentHTML('beforeend', answerHtml(turn, 1));
  return { w, b, col };
}

function artL2() {
  artboard('L2', 'Hover on an edit · the mini diff',
    'Step 8 of 14: the second edit to TranscriptRows.swift. Removed lines sit on the danger wash, added on the accent wash, both at 14 percent on the canvas; the relation chip names the other two steps that touched the same file.',
    host => { openIn(host, 'rose', 1280, TURNS.fix, { hot: 7, mode: 'step', headKey: 'rose-sonnet3-hover-act', anchor: OPT.anchor }); });
}
function artL3() {
  artboard('L3', 'The Digest · nothing hovered, the turn settled',
    'Headline, where the work went, the timeline map with failures taller, what changed, what failed, and the answer with its provenance chips. Every row is a way to a step.',
    host => { openIn(host, 'rose', 1280, TURNS.fix, { mode: 'digest' }); });
}
function artL4() {
  artboard('L4', 'A live turn · Now mode, and the same turn waiting for an approval',
    'Now follows the step that is happening and keeps its leader line; the output streams with a caret and the So far block keeps the shape of the turn. When the step waits on the person the panel becomes the ask in the attention tone; the approval itself stays in the transcript.',
    host => {
      const col = el('<div style="display:flex;flex-direction:column;gap:32px"></div>'); host.appendChild(col);
      const live = TURNS.live, wait = TURNS.wait;
      openIn(col, 'rose', 1280, live, { hot: live.steps.length - 1, noDim: true, mode: 'now', headKey: 'rose-sonnet3-working', footer: { scrub: 0.96 }, anchor: OPT.anchor }, { noAnswer: true, title: 'Tailscode — working' });
      openIn(col, 'rose', 1280, wait, { hot: wait.steps.length - 1, noDim: true, mode: 'ask', headKey: 'rose-sonnet3-approval', footer: { scrub: 0.96 }, anchor: OPT.anchor }, { noAnswer: true, title: 'Tailscode — waiting for you' });
    }, { gap: 0 });
}
function withOpt(o, fn) { const old = Object.assign({}, OPT); Object.assign(OPT, o); try { return fn(); } finally { Object.assign(OPT, old); } }
function artL5() {
  artboard('L5', 'Zone list \u00b7 the dive moved into the panel',
    'SHELL of the 29-step turn: eighteen steps as a list, one pinned on the stage. The head dives into the zone on the left, the list is the dive\u2019s overlay moved into the readout, esc surfaces. The dive keeps the full frame (no trim) because the zone fills it.',
    host => {
      const t = TURNS.big; RO.prep(t);
      const sel = t.steps.findIndex(s => s.arg && s.arg.startsWith('python3 scripts/beats.py --grid'));
      withOpt({ trim: false }, () => openIn(host, 'rose', 1280, t, { mode: 'zone', zone: 'shell', sel, hot: null, leaderFor: sel, dive: { zone: 'shell', s: 2.2 }, headKey: 'rose-fable4-dive-shell', pinned: true, anchor: 'row' }, { noAnswer: true }));
    });
}
function artL6() {
  artboard('L6', 'Four themes · the same step at 1000 px',
    'Rosé Pine, Rosé Pine Dawn, Tokyo Night and Phosphor, each from its corrected palette. The head is a dark object on any canvas; the readout takes the palette.',
    host => {
      const g = el('<div style="display:grid;grid-template-columns:1fr 1fr;gap:20px"></div>'); host.appendChild(g);
      TH.forEach(th => { const cell = el('<div></div>'); g.appendChild(cell); openIn(cell, th, 1000, TURNS.fix, { hot: 5, mode: 'step', headKey: th + '-sonnet3-hover-shell', anchor: OPT.anchor }, { noAnswer: true, noPrompt: true, zoom: .62 }); });
    }, { gap: 0 });
}

function artN() {
  artboard('N', 'Narrow · stacked at 520 px with the readout strip and its pinned expansion · the 380 px card',
    'Under 560 px the stage takes the full width and the readout is a two-line strip below it that wears the zone’s tone on its left edge; pinning grows it in place into the full readout. There is no leader line when the readout is directly under the node. The card at 380 drops its zone strip and digest and keeps the picture, the headline, Replay and Rows.',
    host => {
      const fix = TURNS.fix;
      [false, true].forEach(pinned => {
        const w = win('rose', 520 + 40, pinned ? 'pinned' : 'hovering');
        host.appendChild(w);
        const col = w.querySelector('.col'); col.style.width = '520px'; col.style.padding = '16px 0';
        col.insertAdjacentHTML('beforeend', promptHtml(fix).replace('class="prompt"', 'class="prompt" style="font-size:13.5px"'));
        const h = el('<div class="open"></div>'); col.appendChild(h);
        const b = ST.build(h, fix, { W: 520, theme: 'rose', headKey: 'rose-sonnet3-hover-shell' });
        const s = fix.steps[5];
        if (pinned) b.wrap.insertAdjacentHTML('beforeend', RO.readoutHtml(RO.stepReadout(fix, s, { pinned: true }), { cls: 'stacked' }));
        else b.wrap.insertAdjacentHTML('beforeend', RO.stripHtml(fix, s));
        b.wrap.querySelector('.tab-mark').style.display = 'none';
        ST.mountNodes(b.stage, fix, { S: b.M.S, hot: 5, leader: false });
        h.insertAdjacentHTML('beforeend', ST.footerHtml(fix, 520, {}).replace('Rows</button><button class="pb" type="button">Share</button><button class="pb" type="button" title="Esc">Close', 'Rows</button><button class="pb" type="button">Share'));
      });
      const w3 = win('rose', 380 + 40, '380 px');
      host.appendChild(w3);
      const c3 = w3.querySelector('.col'); c3.style.width = '380px'; c3.style.padding = '16px 0';
      [TURNS.fix, TURNS.calm, TURNS.big].forEach(t => {
        c3.insertAdjacentHTML('beforeend', `<div style="margin-bottom:16px"><div class="prompt" style="font-size:13.5px">${RO.esc(t.prompt).slice(0, 70)}</div>${RO.cardHtml(t, { theme: 'rose', narrow: true })}</div>`);
      });
    }, { gap: 24 });
}

function artL7() {
  artboard('L7', 'Review \u00b7 the spec as written (left) against the revised row (right) \u00b7 1280 px',
    'Left: stage untrimmed, leader ending at the readout header, relations below the output, readout the height of the stage. Right: stage trimmed to the head\u2019s own bounds, leader ending on the node\u2019s own row with a tab on the hairline, relations under the subject, readout at least 420 px.',
    host => {
      const g = el('<div style="display:flex;flex-direction:column;gap:24px"></div>'); host.appendChild(g);
      withOpt({ trim: false, anchor: 'header', relationsUp: false, minH: 300, digestOrder: 'spec' }, () => openIn(g, 'rose', 1280, TURNS.fix, { hot: 5, mode: 'step', headKey: 'rose-sonnet3-hover-shell', anchor: 'header' }, { noAnswer: true, title: 'as written' }));
      withOpt({}, () => openIn(g, 'rose', 1280, TURNS.fix, { hot: 5, mode: 'step', headKey: 'rose-sonnet3-hover-shell', anchor: 'row' }, { noAnswer: true, title: 'revised' }));
    }, { gap: 0 });
}

/* ───── M: the transition ───── */
const M_TIMES = [[0, 'open'], [60, 'open'], [120, 'open'], [180, 'open'], [240, 'open'], [280, 'open'], [320, 'open'], [140, 'close']];
function artM() {
  artboard('M', 'The transition \u00b7 eight frames of one real choreography \u00b7 card to stage and back',
    'The same function the live page runs, sampled at p = 0, 60, 120, 180, 240, 280 and 320 ms of the opening and at 140 ms of the reverse (220 ms, ease-in). Row 860 px wide, drawn at 60 percent. The picture is one surface from the first frame to the last; the sweep crosses it once between 40 and 200 ms; nodes arrive in step order across 150 ms with a 6 percent overshoot; the readout slides 24 px; the row\u2019s height eases with the head.',
    host => {
      const grid = el('<div style="display:grid;grid-template-columns:repeat(4,max-content);gap:20px 20px"></div>'); host.appendChild(grid);
      const Z = .6, W = 860;
      M_TIMES.forEach(([t, dir]) => {
        const cell = el(`<div style="width:${Math.round((W + 56) * Z)}px"><div class="lbl" style="color:#8f8f9a;margin:0 0 8px;font-family:var(--mono)">${dir === 'close' ? 'closing' : 'opening'} \u00b7 ${t} ms</div><div class="mf" data-theme="rose" style="width:${Math.round((W + 56) * Z)}px;height:${Math.round(520 * Z)}px;overflow:hidden;border:1px solid var(--rule);border-radius:10px;background:var(--bg)"><div class="mfi" style="width:${W + 56}px;padding:28px;transform:scale(${Z});transform-origin:0 0"></div></div><div class="mnum" style="font:11px/16px var(--mono);color:#8f8f9a;margin-top:6px"></div></div>`);
        grid.appendChild(cell);
        const inner = cell.querySelector('.mfi');
        const h = el('<div></div>'); inner.appendChild(h);
        const m = TR.mount(h, TURNS.fix, { W, theme: 'rose' });
        const fr = dir === 'close' ? m.apply(t, 'close') : m.apply(t, 'open');
        cell.querySelector('.mnum').textContent = `g ${fr.g.toFixed(2)} \u00b7 row ${Math.round(m.row.offsetHeight)} px \u00b7 readout \u03b1 ${fr.readoutAlpha.toFixed(2)} \u00b7 sweep ${fr.sweepAmt.toFixed(2)}`;
        cell.querySelector('.mf').style.height = Math.round((m.full + 56) * Z) + 'px';
      });
    }, { gap: 0 });
}
function liveWidget(host, theme, W, mountFn) {
  mountFn = mountFn || TR.mount;
  const box = el(`<div data-theme="${theme}" data-light="${PAL[theme].dark === '0' ? 1 : 0}" style="border:1px solid var(--rule);border-radius:12px;padding:20px 28px 28px;width:${W + 56}px"><div style="display:flex;align-items:center;gap:12px;flex-wrap:wrap;margin-bottom:16px;font:12px/16px var(--mono);color:var(--ink2)"><button class="pb" id="lv-open" type="button">\u25b6 Open</button><button class="pb" id="lv-close" type="button">\u25c0 Close</button><button class="pb" id="lv-slow" type="button">\u00bc speed</button><span class="sp" style="width:8px"></span><span>scrub</span><input id="lv-scrub" type="range" min="0" max="320" value="0" step="1" style="width:320px;accent-color:var(--accent)"><span id="lv-num" style="min-width:300px">t 0 ms</span></div><div id="lv-host"></div></div>`);
  host.appendChild(box);
  const m = mountFn(box.querySelector('#lv-host'), TURNS.fix, { W, theme });
  const num = box.querySelector('#lv-num'), sc = box.querySelector('#lv-scrub');
  let dir = 'open', raf = 0, speed = 1, t0 = 0, from = 0, state = { dir: 'open', t: 0 };
  function paint(t, d) { state = { dir: d, t }; const f = m.apply(t, d); sc.max = f.duration; sc.value = t; num.textContent = `${d} \u00b7 t ${Math.round(t)} / ${f.duration} ms \u00b7 g ${f.g.toFixed(2)} \u00b7 row ${Math.round(m.row.offsetHeight)} px`; }
  function run(d) {
    cancelAnimationFrame(raf);
    const dur = d === 'open' ? TR.OPEN : TR.CLOSE;
    const startFrac = state.dir === d ? state.t / dur : (1 - state.t / (state.dir === 'open' ? TR.OPEN : TR.CLOSE));
    const tFrom = clamp01(startFrac) * dur;
    t0 = performance.now() - tFrom / speed;
    (function step(now) {
      const t = Math.min(dur, (now - t0) * speed);
      paint(t, d);
      if (t < dur) raf = requestAnimationFrame(step);
    })(performance.now());
  }
  const clamp01 = v => Math.max(0, Math.min(1, v));
  box.querySelector('#lv-open').onclick = () => { if (state.dir === 'open' && state.t >= TR.OPEN) paint(0, 'open'); run('open'); };
  box.querySelector('#lv-close').onclick = () => { if (state.dir === 'close') paint(0, 'close'); else paint(0, 'close'); run('close'); };
  box.querySelector('#lv-slow').onclick = e => { speed = speed === 1 ? .25 : 1; e.target.textContent = speed === 1 ? '\u00bc speed' : 'full speed'; };
  sc.oninput = () => { cancelAnimationFrame(raf); paint(+sc.value, state.dir); };
  paint(0, 'open');
  return { m, paint, run };
}
function artMLive() {
  artboard('M2', 'The transition, live \u00b7 run it on a button or scrub it',
    'Open and Close run the real choreography at display rate; the slider scrubs the current direction; \u00bc speed shows what each part does. A press during a move reverses from where it is.',
    host => { liveWidget(host, 'rose', 1000); });
}
