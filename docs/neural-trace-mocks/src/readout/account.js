// The account: the agent's turn told in its own words, the work folded into the story, the detail opened inside it.
const AC = (function () {
  const esc = RO.esc, MINUS = '−';
  const FAMHEX = { fable: '#d97757', opus: '#a78bfa', sonnet: '#38bdf8', haiku: '#3fc47c' };
  const NOUN = { think: ['plan', 'plans'], sense: ['read', 'reads'], act: ['edit', 'edits'], shell: ['command', 'commands'], delegate: ['agent', 'agents'], say: ['note', 'notes'] };
  const sense = { Read: ['read', 'reads'], Grep: ['search', 'searches'] };

  function structure(turn, st) {
    RO.prep(turn);
    const vis = new Set(BR.visible(turn, st || {}).map(r => r.i));
    const out = [];
    let run = null;
    turn.steps.forEach(s => {
      if (!vis.has(s.i)) return;
      if (s.fam === 'say' || s.fam === 'think') { if (run) { out.push(run); run = null; } out.push({ kind: s.fam === 'say' ? 'said' : 'thought', i: s.i, s }); }
      else { if (!run) run = { kind: 'work', ids: [] }; run.ids.push(s.i); }
    });
    if (run) out.push(run);
    return out;
  }
  function workSummary(turn, ids) {
    const steps = ids.map(i => turn.steps[i]);
    const marks = [];
    steps.forEach(s => { const k = s.fam; const same = marks.find(m => m.fam === k); if (same) same.n++; else marks.push({ fam: k, n: 1, tool: s.tool }); });
    const failed = steps.filter(s => s.status === 'fail');
    const files = new Map();
    steps.forEach(s => { if (s.fam === 'act' && s.diff) { const e = files.get(s.arg) || { a: 0, d: 0 }; e.a += s.diff[0]; e.d += s.diff[1]; files.set(s.arg, e); } });
    return { marks, failed, files };
  }
  function markHtml(m, words) {
    const nn = NOUN[m.fam];
    let w = nn[m.n === 1 ? 0 : 1];
    if (m.fam === 'sense' && m.tool === 'Grep') w = m.n === 1 ? 'search' : 'searches';
    return `<span class="wm f-${m.fam}">${Neural.shapeSvg(m.fam, 18)}<b>${m.n}</b>${words ? `<span>${w}</span>` : ''}</span>`;
  }
  function workLine(turn, w, st, o) {
    const sum = workSummary(turn, w.ids);
    const first = w.ids[0] + 1, last = w.ids[w.ids.length - 1] + 1;
    const liveTip = st.live && st.following !== false && w.ids.includes(turn.steps.length - 1);
    const open = o.unfold.has(w.ids[0]) || w.ids.includes(st.cursor) || w.ids.includes(st.hover) || liveTip;
    const words = sum.marks.length <= 3;
    let h = `<div class="it work${open ? ' open' : ''}" data-w="${w.ids[0]}"><button class="wl" type="button"><span class="chev">${open ? '▾' : '▸'}</span><span class="wms">${sum.marks.map(m => markHtml(m, words)).join('')}</span>`;
    if (sum.failed.length) {
      const fs = sum.failed[0];
      h += `<span class="wf"><svg width="14" height="14" viewBox="0 0 14 14"><path d="M3.5 3.5l7 7M10.5 3.5l-7 7" stroke="var(--danger)" stroke-width="1.8" stroke-linecap="round"/></svg>${sum.failed.length} failed${fs.retriedAt ? `, <u>retried at ${fs.retriedAt}</u>` : ''}</span>`;
    }
    [...sum.files].slice(0, 1).forEach(([p, e]) => { const d = RO.dirfile(p); h += `<span class="wfile"><span class="fn">${esc(d.fn)}</span> <span class="a">+${e.a}</span> <span class="d">${MINUS}${e.d}</span></span>`; });
    h += `<span class="wsp"></span><span class="wn">${first === last ? '#' + first : '#' + first + '–' + last}</span></button>`;
    if (open) {
      const rows = w.ids.map(i => BR.rowsOf(turn)[i]);
      h += '<div class="wrows">';
      rows.forEach((r, k) => {
        h += BR.rowHtml(turn, r, st, rows, k);
        if (!o.split && (st.cursor === r.i || (st.hover === r.i && st.hover !== st.cursor) || (liveTip && r.i === turn.steps.length - 1 && st.cursor < 0))) h += detailCard(turn, r.s, st.cursor === r.i, o);
      });
      h += '</div>';
    }
    return h + '</div>';
  }
  function detailCard(turn, s, pinned, o) {
    const m = RO.stepReadout(turn, s, { pinned });
    return `<div class="dcard f-${s.fam}${pinned ? '' : ' preview'}${s.status === 'run' ? ' live' : ''}">${m.hd.replace('class="ro-hd', 'class="dc-hd')}<div class="dc-bd">${m.bd}</div>${m.ft.replace('class="ro-ft"', 'class="dc-ft"')}</div>`;
  }
  function saidItem(turn, it, st, o, prev) {
    const s = it.s, fam = turn.family;
    const showSpk = !prev || prev.kind !== 'said';
    const long = s.text.length > 520;
    const hot = st.cursor === it.i, hov = st.hover === it.i;
    const txt = esc(s.text).replace(/`([^`]+)`/g, '<code>$1</code>');
    let h = `<article class="it said${hot ? ' cursor' : ''}${hov ? ' hover' : ''}${o.arrive === it.i ? ' arrive' : ''}" data-i="${it.i}">`;
    if (showSpk) h += `<header class="spk"><i class="fam" style="background:${FAMHEX[fam] || 'var(--accent)'}"></i><b>${esc(turn.speaker || fam)}</b><time>${s.at}</time></header>`;
    h += `<p class="say${long && !o.showAll.has(it.i) ? ' clamp' : ''}">${txt}</p>`;
    if (long && !o.showAll.has(it.i)) h += '<button class="showall" type="button">Show all</button>';
    h += `<span class="acts"><button class="sbtn" type="button">Copy</button><button class="sbtn" type="button">Reply</button></span><span class="sn">#${it.i + 1}</span></article>`;
    return h;
  }
  function thoughtItem(turn, it, st) {
    const hot = st.cursor === it.i;
    return `<div class="it thought${hot ? ' cursor' : ''}" data-i="${it.i}"><span class="gl">${Neural.shapeSvg('think', 18)}</span><span class="tx">${esc(it.s.text)}</span><button class="showall" type="button">Show</button><span class="sn">#${it.i + 1}</span></div>`;
  }
  function askItem(turn, s) {
    return `<section class="it ask"><div class="ak"><i class="pulse attn"></i><span class="lbl">Needs you</span><span class="aw">${ZONE_LABEL[s.fam]} · waiting since ${s.at}</span></div><p class="say">${esc(s.why || '')}</p><div class="cmdl"><span class="ps">$</span>${esc(s.arg)}</div><div class="abtns"><button class="btn" type="button">Go to approval ↓</button><button class="btn ghost" type="button">Show step #${s.i + 1}</button></div></section>`;
  }
  function answerItem(turn) {
    return `<div class="it answer"><span class="lbl">Then it answered</span><p class="say">${esc(turn.answer[0].replace(/`/g, '')).slice(0, 170)}…</p><span class="wn">answer ↓</span></div>`;
  }

  function html(turn, st, o) {
    o = Object.assign({ unfold: new Set(), showAll: new Set(), split: false }, o || {});
    if (!(o.unfold instanceof Set)) o.unfold = new Set(o.unfold);
    if (!(o.showAll instanceof Set)) o.showAll = new Set(o.showAll);
    const items = structure(turn, st);
    const ask = turn.steps.find(s => s.status === 'wait');
    let h = '';
    if (ask) h += askItem(turn, ask);
    let prev = null;
    items.forEach(it => {
      if (it.kind === 'said') h += saidItem(turn, it, st, o, prev);
      else if (it.kind === 'thought') h += thoughtItem(turn, it, st);
      else h += workLine(turn, it, st, o);
      prev = it;
    });
    if (turn.answer && !(st.zones && st.zones.size && !st.zones.has('say')) ) h += answerItem(turn);
    return h;
  }
  function counts(turn) { return { said: turn.steps.filter(s => s.fam === 'say').length, steps: turn.steps.length }; }
  return { structure, html, detailCard, counts, FAMHEX, saidItem, thoughtItem, askItem, workLine };
})();
