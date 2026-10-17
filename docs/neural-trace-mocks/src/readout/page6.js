// Sixth pass artboards: V live cards and settle, W the move both ways, W2 live page.
function cardStack(host, theme, density, narrow, keys) {
  const w = win(theme, narrow ? 440 : 776, 'Tailscode — conversation'); host.appendChild(w);
  const col = w.querySelector('.col'); col.style.width = (narrow ? 380 : 720) + 'px';
  with5(() => keys.forEach(k => { const d = LC.DESC[k]; col.insertAdjacentHTML('beforeend', `<div style="margin:0 0 12px"><div class="lbl" style="color:var(--ink2);margin:0 0 6px">${k === 'note' ? 'a note arrives (holds 4 s)' : d.verdict + (k === 'shell' ? ' · a shell step' : k === 'sense' ? ' · a read' : k === 'act' ? ' · an edit' : '')}</div>${LC.cardHtml(k, { theme, density, narrow })}</div>`); }));
  return w;
}
function artV() {
  artboard('V', 'The live card · the robot, observed from the transcript · both densities and 380 px',
    'The card keeps its size and says what is happening in the reader’s words: the head breathes in the active zone (two real compositor frames, low and high, cross-faded at the activity swell, 1.9 s), the headline is the verdict with tabular counts, the edge pulses at the same swell, and the third line is NOW: the plain title, the mono argument and the last output line sliding in at the right. A waiting turn knocks twice in amber; a silent one says so in attention; an error says it is trying again and keeps its output in amber, never red; a note from the agent replaces the line as a quote and holds for 4 s.',
    host => {
      const wrap = el('<div style="display:flex;gap:24px;align-items:flex-start"></div>'); host.appendChild(wrap);
      const a = el('<div style="display:flex;flex-direction:column;gap:20px"></div>'); wrap.appendChild(a);
      cardStack(a, 'rose', 'comfortable', false, ['shell', 'sense', 'act', 'wait', 'stuck', 'retry', 'note']);
      const b = el('<div style="display:flex;flex-direction:column;gap:20px"></div>'); wrap.appendChild(b);
      cardStack(b, 'rose', 'compact', false, ['shell', 'wait', 'stuck', 'retry', 'note']);
      cardStack(b, 'dawn', 'comfortable', false, ['shell', 'retry']);
      const c = el('<div style="display:flex;flex-direction:column;gap:20px"></div>'); wrap.appendChild(c);
      cardStack(c, 'tokyo', 'comfortable', true, ['shell', 'wait', 'stuck', 'retry']);
      cardStack(c, 'phosphor', 'comfortable', true, ['act', 'note']);
      setTimeout(() => RO.fitQuotes(document.body), 0);
    });
}
function artV2() {
  artboard('V2', 'The settle · 400 ms, eight frames · the robot finishes its sentence',
    'Lights ease to their final strengths and the head cross-fades from the live frame to the settled one (the eye takes the model’s colour); the verdict text slides out 6 px up while “Done, fixed 1 error” slides in 6 px; the output line goes out first and the agent’s first words come in under it; the edge stops pulsing and holds. Comfortable above, Compact below.',
    host => {
      const w = win('rose', 1500, 'Tailscode — settle'); host.appendChild(w);
      const col = w.querySelector('.col'); col.style.width = '1444px';
      ['comfortable', 'compact'].forEach(den => {
        const grid = el('<div class="fsheet" style="grid-template-columns:repeat(4,max-content);margin-bottom:24px"></div>'); col.appendChild(grid);
        [0, 50, 100, 150, 200, 260, 330, 400].forEach(t => {
          const cell = el(`<div class="fc"><div class="lbl">${den} · ${t} ms</div><div class="mf" style="padding:12px;zoom:.56"></div></div>`); grid.appendChild(cell);
          const m = LC.settleMount(cell.querySelector('.mf'), 'rose', den); m.apply(t);
        });
      });
    });
}
const W_OPEN = [0, 35, 70, 105, 140, 180, 220, 260, 290, 320];
const W_CLOSE = [0, 24, 49, 73, 98, 122, 147, 171, 196, 220];
function frameSheet(host, title, theme, W, turn, mk, frames, fn, Z) {
  Z = Z || .42;
  const cw = Math.round((W + 24) * Z);
  const grid = el(`<div class="fsheet" style="grid-template-columns:repeat(5,${cw}px)"></div>`); host.appendChild(grid);
  frames.forEach((fr, k) => {
    const cell = el(`<div class="fc" style="width:${cw}px"><div class="lbl">${fr.label}</div><div class="mf" data-theme="${theme}" style="width:${cw}px;border-radius:8px"><div class="mfi" style="width:${W + 24}px;padding:12px;transform:scale(${Z});transform-origin:0 0"></div></div><div class="mnum"></div></div>`); grid.appendChild(cell);
    const h = el('<div></div>'); cell.querySelector('.mfi').appendChild(h);
    const m = mk(h);
    const r = fn(m, fr);
    cell.querySelector('.mnum').textContent = LC.strip(r);
    cell.querySelector('.mf').style.height = Math.round((m.outer.offsetHeight + 24) * Z) + 'px';
  });
}
function artW() {
  artboard('W', 'The move, both ways, from both card states · ten frames each',
    'Open: easeOutCubic on geometry over 320 ms, nodes in step order with the 6 percent overshoot, the traveller 1.5 percent over at 80 percent of the move and then home, the tone edge riding the picture’s left edge for 90 ms, the account sliding 24 px in. From a live card the head keeps breathing through the move and the NOW line becomes the account’s Now item by cross-fade. Close: easeInOutCubic over 220 ms, content out first. The reversal re-enters from the frame it was on. Each row clips its own drawing and the row height eases with the head, so the transcript below moves with it. Row 1280 px at 42 percent.',
    host => {
      const col = el('<div style="display:flex;flex-direction:column;gap:28px"></div>'); host.appendChild(col);
      const w = win('rose', 2860, 'Tailscode — the move'); col.appendChild(w);
      const c = w.querySelector('.col'); c.style.width = '2804px';
      const sec = (t) => c.insertAdjacentHTML('beforeend', `<div class="lbl" style="color:var(--ink);margin:24px 0 8px">${t}</div>`);
      const settled = TURNS.u, liveT = variantTurn(TURNS.ulive, t => { delete t.silentFor; t.planAt = 15; });
      with5(() => {
        sec('1 · Open from a settled card (320 ms)');
        frameSheet(c, '', 'rose', 1280, settled, h => LC.moveMount(h, settled, { W: 1280, theme: 'rose' }), W_OPEN.map(t => ({ label: t + ' ms', t })), (m, f) => m.open(f.t));
        sec('2 · Open from a live card (the head keeps breathing; the NOW line becomes the Now item)');
        frameSheet(c, '', 'rose', 1280, liveT, h => LC.moveMount(h, liveT, { W: 1280, theme: 'rose', live: true, desc: LC.DESC.shell }), W_OPEN.map(t => ({ label: t + ' ms', t })), (m, f) => m.open(f.t));
        sec('3 · Close back to a settled card (220 ms, easeInOutCubic)');
        frameSheet(c, '', 'rose', 1280, settled, h => LC.moveMount(h, settled, { W: 1280, theme: 'rose' }), W_CLOSE.map(t => ({ label: t + ' ms', t })), (m, f) => m.close(f.t));
        sec('4 · Close back to a live card');
        frameSheet(c, '', 'rose', 1280, liveT, h => LC.moveMount(h, liveT, { W: 1280, theme: 'rose', live: true, desc: LC.DESC.shell }), W_CLOSE.map(t => ({ label: t + ' ms', t })), (m, f) => m.close(f.t));
        sec('5 · A reversal: opened for 140 ms, then pressed again (it turns round from where it was)');
        const g140 = LC.gOpen(140);
        const rev = [0, 35, 70, 105, 140].map(t => ({ label: 'open ' + t + ' ms', t, o: 1 })).concat([24, 49, 73, 98, 122].map(t => ({ label: 'reverse +' + t + ' ms', t, o: 0 })));
        frameSheet(c, '', 'rose', 1280, settled, h => LC.moveMount(h, settled, { W: 1280, theme: 'rose' }), rev, (m, f) => f.o ? m.open(f.t) : m.close(f.t, g140));
        sec('6 · Two cards crossing: one closes while the next opens (each row keeps its own clip; the rows below ride both heights)');
        const cross = [0, 35, 70, 105, 140, 180, 220, 260, 290, 320];
        const grid = el('<div class="fsheet" style="grid-template-columns:repeat(5,max-content)"></div>'); c.appendChild(grid);
        const Z = .42, cw = Math.round((1280 + 24) * Z);
        cross.forEach(t => {
          const cell = el(`<div class="fc" style="width:${cw}px"><div class="lbl">${t} ms</div><div class="mf" data-theme="rose" style="width:${cw}px;border-radius:8px"><div class="mfi" style="width:${1304}px;padding:12px;transform:scale(${Z});transform-origin:0 0"></div></div><div class="mnum"></div></div>`); grid.appendChild(cell);
          const inner = cell.querySelector('.mfi');
          const hA = el('<div></div>'), hB = el('<div style="margin-top:12px"></div>'); inner.appendChild(hA); inner.appendChild(hB);
          const A = LC.moveMount(hA, settled, { W: 1280, theme: 'rose' }), B = LC.moveMount(hB, liveT, { W: 1280, theme: 'rose', live: true, desc: LC.DESC.shell });
          const ra = A.close(t, 1), rb = B.open(t);
          const gp = el(`<div class="mnum"></div>`);
          cell.querySelector('.mnum').textContent = `A p ${ra.g.toFixed(2)} row ${ra.row} · B p ${rb.g.toFixed(2)} row ${rb.row}`;
          cell.querySelector('.mf').style.height = Math.round((A.outer.offsetHeight + B.outer.offsetHeight + 36) * Z) + 'px';
        });
      });
    });
}
const LIVE6 = variantTurn(TURNS.ulive, t => { delete t.silentFor; t.planAt = 15; });
function liveWidget6(host) {
  const box = el(`<div data-theme="rose" style="border:1px solid var(--rule);border-radius:12px;padding:16px 28px 28px;width:1336px"><div style="display:flex;align-items:center;gap:12px;flex-wrap:wrap;margin-bottom:16px;font:12px/16px var(--mono);color:var(--ink2)"><button class="pb" id="w-open" type="button">▶ Open</button><button class="pb" id="w-close" type="button">◀ Close</button><button class="pb" id="w-live" type="button" aria-pressed="false">Live card</button><button class="pb" id="w-cross" type="button">Crossing</button><button class="pb" id="w-slow" type="button">¼ speed</button><span style="width:8px"></span><span>scrub</span><input id="w-scrub" type="range" min="0" max="320" value="0" step="1" style="width:300px;accent-color:var(--accent)"><span id="w-num" style="min-width:420px"></span></div><div id="w-host"></div></div>`);
  host.appendChild(box);
  const hostEl = box.querySelector('#w-host');
  let live = false, m = null, raf = 0, speed = 1, cur = { dir: 'open', t: 0, g0: 1 }, crossing = null;
  const num = box.querySelector('#w-num'), sc = box.querySelector('#w-scrub');
  function build() { cancelAnimationFrame(raf); crossing = null; hostEl.innerHTML = ''; const h = el('<div></div>'); hostEl.appendChild(h); m = with5(() => LC.moveMount(h, live ? LIVE6 : TURNS.u, { W: 1280, theme: 'rose', live, desc: LC.DESC.shell })); show('open', 0); }
  function show(dir, t, g0) { cur = { dir, t, g0: g0 == null ? 1 : g0 }; const r = dir === 'open' ? m.open(t) : m.close(t, cur.g0); sc.max = dir === 'open' ? 320 : 220; sc.value = t; num.textContent = dir + ' ' + Math.round(t) + ' ms · ' + LC.strip(r); return r; }
  function run(dir) {
    cancelAnimationFrame(raf);
    const g = m.state.g;
    let g0 = null, startT = 0;
    if (dir === 'open') { startT = g >= 1 ? 0 : (g > 0 ? 320 * (1 - Math.pow(1 - g, 1 / 3)) : 0); if (g >= 1) { m.open(0); } }
    else { if (g <= 0) { m.paint(1, 'open', 320); } g0 = m.state.g || 1; }
    const dur = dir === 'open' ? 320 : Math.max(110, 220 * (g0 || 1));
    const t0 = performance.now() - startT / speed;
    (function step(now) { const t = Math.min(dur, (now - t0) * speed); show(dir, t, g0 == null ? 1 : g0); if (t < dur) raf = requestAnimationFrame(step); })(performance.now());
  }
  box.querySelector('#w-open').onclick = () => run('open');
  box.querySelector('#w-close').onclick = () => run('close');
  box.querySelector('#w-live').onclick = e => { live = !live; e.target.setAttribute('aria-pressed', live); build(); };
  box.querySelector('#w-slow').onclick = e => { speed = speed === 1 ? .25 : 1; e.target.textContent = speed === 1 ? '¼ speed' : 'full speed'; };
  sc.oninput = () => { cancelAnimationFrame(raf); show(cur.dir, +sc.value, cur.g0); };
  box.querySelector('#w-cross').onclick = () => {
    cancelAnimationFrame(raf); hostEl.innerHTML = '';
    const hA = el('<div></div>'), hB = el('<div style="margin-top:12px"></div>'); hostEl.appendChild(hA); hostEl.appendChild(hB);
    const A = with5(() => LC.moveMount(hA, TURNS.u, { W: 1280, theme: 'rose' })), B = with5(() => LC.moveMount(hB, LIVE6, { W: 1280, theme: 'rose', live: true, desc: LC.DESC.shell }));
    A.close(0, 1); B.open(0);
    const t0 = performance.now();
    (function step(now) { const t = Math.min(320, (now - t0) * speed); const ra = A.close(t, 1), rb = B.open(t); num.textContent = `crossing ${Math.round(t)} ms · A p ${ra.g.toFixed(2)} row ${ra.row} · B p ${rb.g.toFixed(2)} row ${rb.row}`; if (t < 320) raf = requestAnimationFrame(step); })(t0);
  };
  build();
}
function artW2() {
  artboard('W2', 'The move, live · Open and Close from a settled or a live card, scrub, quarter speed, the crossing',
    'Open and Close run the real choreography at display rate; Live card swaps the card for the live one (the head keeps breathing through the move); the slider scrubs; a press during a move reverses from where it is; Crossing closes one card while the next opens.',
    host => { with5(() => liveWidget6(host)); });
}
