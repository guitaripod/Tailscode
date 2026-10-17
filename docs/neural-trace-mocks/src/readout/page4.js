// Fourth pass artboards: T the account, T2 widths, T3 cards, T4 list and SAID solo, T5 narrow, T6 reply, T7 live.
function with4(fn) {
  const oldL = ZONE_LABEL.say, oldF = Neural.FAM.say.label, oldO = Object.assign({}, OPT);
  ZONE_LABEL.say = 'SAID'; Neural.FAM.say.label = 'SAID'; Object.assign(OPT, { said4: true, compactStatus: true });
  try { return fn(); } finally { ZONE_LABEL.say = oldL; Neural.FAM.say.label = oldF; Object.assign(OPT, oldO); delete OPT.said4; delete OPT.compactStatus; }
}
function acctWin(host, theme, W, turn, o, title, noPrompt) {
  const w = win(theme, W + 56, title || 'Tailscode — conversation');
  host.appendChild(w);
  const col = w.querySelector('.col'); col.style.width = W + 'px';
  if (!noPrompt) col.insertAdjacentHTML('beforeend', promptHtml(turn));
  const h = el('<div class="open"></div>'); col.appendChild(h);
  const ctl = with4(() => B4.mount(h, turn, Object.assign({ W, theme }, o)));
  if (!noPrompt && turn.answer && !(o && o.noAnswer)) col.insertAdjacentHTML('beforeend', answerHtml(turn, 1));
  return { w, ctl, col };
}
const FIRST = (t, pred) => t.steps.findIndex(pred);
const NEWSUP = ' <em style="color:#c9a25c;font-style:normal">Superseded on the right side by the fourth pass (T, section 8): the right display is the account.</em>';

function artT() {
  artboard('T', 'The account · the right side is the agent talking to you · 1280 px',
    'Top: a settled turn with the cursor on the failed swift build. The agent’s notes are prose with its name and clock, thoughts are one muted line, work is a folded line of zone marks that unfolds into the list’s own rows with the cursor step’s card inline, and the answer closes the story. Copy and Reply appear on the note under the pointer or the cursor (T4, T7). Bottom: the same turn waiting on an approval, which is pinned at the top of the account in the attention tone.',
    host => {
      const col = el('<div style="display:flex;flex-direction:column;gap:28px"></div>'); host.appendChild(col);
      const t = TURNS.acc; RO.prep(t);
      const fail = FIRST(t, s => s.status === 'fail');
      acctWin(col, 'rose', 1280, t, { state: { cursor: fail }, listRows: 9 });
      const w = TURNS.accwait; RO.prep(w);
      acctWin(col, 'rose', 1280, w, { state: { cursor: -1 }, listRows: 9, noAnswer: true }, 'Tailscode — waiting for you', true);
    }, { gap: 0 });
}
function artT2() {
  artboard('T2', 'The account scales with the window · 1920, 1440 and 1100 px',
    'The head column stays 300 to 360 wide; the account takes the rest. From an account of 924 px (a 1310 px window) it splits into the story on the left and the open step’s card on the right; under that the card unfolds in place. Prose stops at 78 characters whatever the width.',
    host => {
      const col = el('<div style="display:flex;flex-direction:column;gap:28px"></div>'); host.appendChild(col);
      const t = TURNS.acc; RO.prep(t);
      const fail = FIRST(t, s => s.status === 'fail');
      [1920, 1440, 1100].forEach(W => acctWin(col, 'tokyo', W, t, { state: { cursor: fail }, listRows: 9, headKey: 'tokyo-sonnet3-hover-shell' }, 'Tailscode — ' + W + ' px', true));
    }, { gap: 0 });
}
function artT3() {
  artboard('T3', 'The card · the agent’s own first words as the third line · both densities',
    'The third line is what the agent said first, with its name and a quote glyph, cut at a whole word; a turn that said nothing keeps the sentence of counts. The zone chip is spelled SAID.',
    host => {
      const turns = [TURNS.calm, TURNS.acc, TURNS.big];
      ['rose', 'dawn'].forEach(theme => {
        const w = win(theme, 776, 'Tailscode — conversation'); host.appendChild(w);
        const col = w.querySelector('.col'); col.style.width = '720px';
        with4(() => ['comfortable', 'compact'].forEach((den, di) => {
          col.insertAdjacentHTML('beforeend', `<div class="lbl" style="color:var(--ink2);margin:${di ? 28 : 0}px 0 12px">${den}</div>`);
          turns.forEach(t => col.insertAdjacentHTML('beforeend', `<div style="margin:${den === 'compact' ? 12 : 16}px 0 0">${promptHtml(t)}${RO.cardHtml(t, { theme, density: den })}</div>`));
        }));
        RO.fitQuotes(col);
      });
    });
}
function artT4() {
  artboard('T4', 'The step list · Said rows are messages, Thought rows are one muted line · SAID solo',
    'Left: a Said row is 40 px tall, the quote glyph in the accent, two lines of ink; a Thought row is one muted line; the SAID chip leads the filter row, labelled, with its count. Right: SAID solo, where the list and the account are the transcript of what the agent told you.',
    host => {
      const col = el('<div style="display:flex;flex-direction:column;gap:28px"></div>'); host.appendChild(col);
      const t = TURNS.acc; RO.prep(t);
      acctWin(col, 'rose', 1280, t, { state: { cursor: 9 }, listRows: 9, listScroll: 0 }, 'Tailscode — all steps', true);
      acctWin(col, 'rose', 1280, t, { state: { cursor: 9, zones: ['say'] }, listRows: 9 }, 'Tailscode — SAID only', true);
    }, { gap: 0 });
}
function artT5() {
  artboard('T5', 'Narrow · the account as the accordion at 520 and 380 px',
    'Under 860 px the head is small on top, the chips follow, and the account is the list: notes as messages, thoughts as one line, work folded; a press unfolds work into the step rows and the cursor row opens its card in place. One open at a time.',
    host => {
      const t = TURNS.acc; RO.prep(t);
      const fail = FIRST(t, s => s.status === 'fail');
      [520, 380].forEach(W => {
        const w = win('rose', W + 40, W + ' px'); host.appendChild(w);
        const col = w.querySelector('.col'); col.style.width = W + 'px'; col.style.padding = '16px 0';
        const h = el('<div class="open"></div>'); col.appendChild(h);
        with4(() => B4.mount(h, t, { W, theme: 'rose', state: { cursor: fail }, headKey: 'rose-sonnet3-hover-shell', storyMax: W }));
      });
      const w = win('dawn', 560, 'Dawn · 520'); host.appendChild(w);
      const col = w.querySelector('.col'); col.style.width = '520px'; col.style.padding = '16px 0';
      const h = el('<div class="open"></div>'); col.appendChild(h);
      with4(() => B4.mount(h, t, { W: 520, theme: 'dawn', state: { cursor: 9 }, storyMax: 520, headKey: 'dawn-sonnet3-settled' }));
    }, { gap: 24 });
}
function composerHtml(q) {
  return `<div class="composer focus">${q ? `<div class="quote"><div><div class="qh">Replying to Sonnet · 14:03:41</div><div class="qb">${RO.esc(q)}</div></div><button class="qx" type="button">×</button></div>` : ''}<div class="line"><div class="inp">${q ? '' : '<span class="ph">Message the agent</span>'}<i class="caret"></i></div><span class="mp"><i style="background:#38bdf8"></i>Sonnet<span class="bars"><b style="height:4px"></b><b style="height:7px"></b><b style="height:10px"></b><b style="height:10px;opacity:.3"></b><b style="height:10px;opacity:.3"></b></span></span><span class="send">↑</span></div></div>`;
}
function artT6() {
  artboard('T6', 'Reply · the quote lands in the composer, focused, nothing sent · and the updated key legend',
    'Reply on a note puts its words in the composer as a quote above the field and moves the caret there; the quote can be dismissed, and Send goes through the ordinary send. The legend names s and S (next and previous thing it said) and a (what it asks).',
    host => {
      const t = TURNS.acc; RO.prep(t);
      const si = FIRST(t, s => s.fam === 'say' && s.text.length > 400);
      const left = el('<div style="display:flex;flex-direction:column;gap:20px"></div>'); host.appendChild(left);
      const w = win('rose', 1136, 'Tailscode — conversation'); left.appendChild(w);
      const col = w.querySelector('.col'); col.style.width = '1080px';
      const h = el('<div class="open"></div>'); col.appendChild(h);
      const ctl = with4(() => B4.mount(h, t, { W: 1080, theme: 'rose', state: { cursor: si, hover: si }, noFooter: true, listRows: 8 }));
      col.insertAdjacentHTML('beforeend', `<div style="margin-top:16px">${composerHtml(t.steps[si].text.replace(/`/g, '').slice(0, 130) + '…')}</div>`);
      const w2 = win('rose', 1136, 'Tailscode — key legend (?)'); left.appendChild(w2);
      const c2 = w2.querySelector('.col'); c2.style.width = '1080px'; c2.style.height = '330px'; c2.style.position = 'relative';
      const h2 = el('<div class="open" style="position:relative"></div>'); c2.appendChild(h2);
      with4(() => { const cc = B4.mount(h2, t, { W: 1080, theme: 'rose', state: { cursor: si, legend: true }, noFooter: true, listRows: 8 }); });
      w2.querySelector('.col').style.overflow = 'hidden';
    }, { gap: 0 });
}
function artT7() {
  artboard('T7', 'A live turn · the account follows the newest item · a note arriving · following paused',
    'Top: the account sits at its end; the newest note is sliding in (twelve pixels, fading up, marked just now), the work line for the running step is open with its card and the output tail with a caret, and the list follows the newest row. Bottom: scrolled up to read an earlier note, the account stops following and offers the way back; so does the list.',
    host => {
      const col = el('<div style="display:flex;flex-direction:column;gap:28px"></div>'); host.appendChild(col);
      const t = TURNS.acclive; RO.prep(t);
      const lastSay = t.steps.map((s, i) => s.fam === 'say' ? i : -1).filter(i => i >= 0).pop();
      acctWin(col, 'rose', 1280, t, { state: { live: true, following: true }, listRows: 9, arrive: lastSay, headKey: 'rose-sonnet3-working', footer: { scrub: .97 } }, 'Tailscode — working', true);
      acctWin(col, 'rose', 1280, t, { state: { live: true, following: false, cursor: 1 }, listRows: 9, headKey: 'rose-sonnet3-working', footer: { scrub: .97 }, listScroll: 20 }, 'Tailscode — following paused', true);
    }, { gap: 0 });
}

function artTLive() {
  artboard('T8', 'Live \u00b7 browse the account with the mouse and the keyboard',
    'Click a note, a work line, a row or a node; hover previews; s and S walk what it said, a jumps to the ask, [ ] the failures, j k the steps, 1 solos SAID, ? the legend, Esc in its steps. Reply and Copy answer with a toast.',
    host => {
      const w = win('rose', 1336, 'Tailscode \u2014 live account'); host.appendChild(w);
      const col = w.querySelector('.col'); col.style.width = '1280px';
      const h = el('<div class="open"></div>'); col.appendChild(h);
      Object.assign(OPT, { said4: true, compactStatus: true }); ZONE_LABEL.say = 'SAID'; Neural.FAM.say.label = 'SAID';
      const ctl = B4.mount(h, TURNS.accwait, { W: 1280, theme: 'rose', state: { cursor: -1 } });
      liveAccount(ctl, w);
    });
}
function liveAccount(ctl, root) {
  const st = ctl.st, turn = ctl.turn;
  const toast = el('<div style="position:absolute;right:24px;top:48px;z-index:30;padding:6px 12px;border-radius:14px;background:var(--raised);border:1px solid var(--accent);font:12px/16px var(--sans);color:var(--ink);display:none"></div>');
  root.style.position = 'relative'; root.appendChild(toast);
  const say = t => { toast.textContent = t; toast.style.display = 'block'; clearTimeout(say.t); say.t = setTimeout(() => toast.style.display = 'none', 1100); };
  const clamp = (v, a, b) => Math.max(a, Math.min(b, v));
  const vis = () => BR.visible(turn, st);
  const re = () => ctl.render();
  const set = i => { st.cursor = i; st.hover = -1; ctl.forceAcc = true; re(); };
  const move = d => { const v = vis(); if (!v.length) return; const k = v.findIndex(r => r.i === st.cursor); set(v[clamp(k < 0 ? (d > 0 ? 0 : v.length - 1) : k + d, 0, v.length - 1)].i); };
  const saidStep = d => { const ids = vis().filter(r => r.fam === 'say').map(r => r.i); if (!ids.length) return; const n = d > 0 ? ids.find(i => i > st.cursor) : [...ids].reverse().find(i => i < st.cursor); set(n != null ? n : (d > 0 ? ids[0] : ids[ids.length - 1])); };
  const failedStep = d => { const f = turn.steps.map((s, i) => s.status === 'fail' ? i : -1).filter(i => i >= 0); if (!f.length) return; const nx = d > 0 ? f.find(i => i > st.cursor) : [...f].reverse().find(i => i < st.cursor); set(nx != null ? nx : (d > 0 ? f[0] : f[f.length - 1])); };
  const toggleZone = z => { if (!st.zones) st.zones = new Set(); st.zones.has(z) ? st.zones.delete(z) : st.zones.add(z); re(); };
  document.addEventListener('keydown', e => {
    if (st.searchOpen) {
      if (e.key === 'Escape') { st.query = ''; st.searchOpen = false; re(); e.preventDefault(); return; }
      if (e.key === 'Enter') { const v = vis(); st.searchOpen = false; if (v.length) set(v[0].i); else re(); e.preventDefault(); return; }
      if (e.key === 'Backspace') { st.query = st.query.slice(0, -1); re(); e.preventDefault(); return; }
      if (e.key.length === 1 && !e.ctrlKey && !e.metaKey) { st.query += e.key; re(); e.preventDefault(); return; }
      return;
    }
    const k = e.key, ZK = { 1: 'say', 2: 'think', 3: 'sense', 4: 'act', 5: 'shell', 6: 'delegate' };
    let used = true;
    if (k === 'ArrowDown' || k === 'j') move(1); else if (k === 'ArrowUp' || k === 'k') move(-1);
    else if (k === 'PageDown') move(8); else if (k === 'PageUp') move(-8);
    else if (k === 'Home' || k === 'g') { const v = vis(); if (v.length) set(v[0].i); }
    else if (k === 'End' || k === 'G') { const v = vis(); if (v.length) set(v[v.length - 1].i); }
    else if (k === 's') saidStep(1); else if (k === 'S') saidStep(-1);
    else if (k === 'a') { const a = turn.steps.findIndex(s => s.status === 'wait'); if (a >= 0) { set(a); const it = root.querySelector('.it.ask'); if (it) it.animate([{ outlineColor: 'transparent' }, { outlineColor: 'var(--warn)' }], { duration: 400 }); } else say('Nothing is asking'); }
    else if (k === ']' || k === 'n') failedStep(1); else if (k === '[' || k === 'p') failedStep(-1);
    else if (ZK[k]) toggleZone(ZK[k]); else if (k === '0') { st.zones = null; re(); }
    else if (k === '!' || k === 'x') { st.failed = !st.failed; re(); }
    else if (k === '/') { st.searchOpen = true; re(); }
    else if (k === 'c') say('Copied command'); else if (k === 'C') say('Copied output');
    else if (k === '?') { st.legend = !st.legend; re(); }
    else if (k === ' ') { const w = turn.steps[st.cursor] && root.querySelector(`.it.work:has([data-i="${st.cursor}"])`); if (w) { const id = +w.dataset.w; ctl.o.unfold.has(id) ? ctl.o.unfold.delete(id) : ctl.o.unfold.add(id); re(); } }
    else if (k === 'Escape') { if (st.legend) st.legend = false; else if (st.query) st.query = ''; else if (st.zones && st.zones.size || st.failed) { st.zones = null; st.failed = false; } else if (st.cursor >= 0) st.cursor = -1; else say('Esc four: the brain would collapse'); re(); }
    else used = false;
    if (used) e.preventDefault();
  });
  root.addEventListener('click', e => {
    const z = e.target.closest('[data-z]'), f = e.target.closest('[data-failed]'), r = e.target.closest('.lr'), it = e.target.closest('.it.said,.it.thought'), wl = e.target.closest('.wl'), n = e.target.closest('.n');
    if (e.target.closest('.sbtn')) { say(e.target.textContent === 'Reply' ? 'Quoted in the composer' : 'Copied'); return; }
    if (e.target.closest('.showall')) { const i = +e.target.closest('[data-i]').dataset.i; ctl.o.showAll.has(i) ? ctl.o.showAll.delete(i) : ctl.o.showAll.add(i); re(); return; }
    if (z) { if (e.shiftKey) st.zones = new Set([z.dataset.z]); else toggleZone(z.dataset.z); re(); return; }
    if (f) { st.failed = !st.failed; re(); return; }
    if (e.target.closest('.srch')) { st.searchOpen = true; re(); return; }
    if (e.target.closest('.follow')) { st.following = true; re(); return; }
    if (wl) { const w = wl.closest('.it.work'); const id = +w.dataset.w; ctl.o.unfold.has(id) ? ctl.o.unfold.delete(id) : ctl.o.unfold.add(id); st.cursor = -1; ctl.forceAcc = false; re(); return; }
    if (r) { set(+r.dataset.i); return; }
    if (it) { set(+it.dataset.i); return; }
    if (n) { const i = ctl.nodes.indexOf(n); if (i >= 0) set(i); }
  });
  root.addEventListener('mouseover', e => {
    const r = e.target.closest('.lr'), it = e.target.closest('.it.said'), n = e.target.closest('.n');
    const i = r ? +r.dataset.i : it ? +it.dataset.i : n ? ctl.nodes.indexOf(n) : -1;
    if (i !== st.hover) { st.hover = i; const sc = root.querySelector('.lrows'); const t = sc && sc.scrollTop; re(); const s2 = root.querySelector('.lrows'); if (s2 && t != null) s2.scrollTop = t; }
  });
  root.addEventListener('mouseleave', () => { st.hover = -1; re(); });
}
