// Sixth pass: the live card, the settle, the move both ways from both card states.
const LC = (function () {
  const esc = RO.esc, clamp = (v, a = 0, b = 1) => Math.max(a, Math.min(b, v));
  const easeOut = x => 1 - Math.pow(1 - clamp(x, 0, 1), 3);
  const easeInOut = x => { x = clamp(x, 0, 1); return x < .5 ? 4 * x * x * x : 1 - Math.pow(-2 * x + 2, 3) / 2; };
  const DESC = {
    shell: { vk: 'working', verdict: 'Working', title: 'Ran the tests', arg: 'swift test --filter TranscriptRowsTests', out: 'Test Case ‘TranscriptRowsTests.testRows’ passed (0.004 s)', img: 'shell', counts: [12, 3, '4m 05s'] },
    sense: { vk: 'working', verdict: 'Working', title: 'Read QuotaGlance.swift', arg: 'TailscodeCore/Sources/TailscodeCore/QuotaGlance.swift', out: '212 lines', img: 'sense', counts: [6, 1, '0m 31s'] },
    act: { vk: 'working', verdict: 'Working', title: 'Edited TranscriptRows.swift (+6 −1)', arg: 'TailscodeLinux/Sources/TailscodeLinux/Chat/TranscriptRows.swift', out: 'The file TranscriptRows.swift has been updated.', img: 'act', counts: [9, 2, '1m 48s'] },
    wait: { vk: 'needs', verdict: 'Waiting for you', title: 'Wants to run scripts/install-linuxapp.sh', arg: 'restarts Tailscode, so it asked first', out: '', img: 'wait', counts: [18, 4, '6m 05s'], tone: 'attn' },
    stuck: { vk: 'stuck', verdict: 'Stuck for 40 s', title: 'Ran ffmpeg', arg: 'ffmpeg -i ios-tour/walk.mov -vf fps=30 out/demo/ios-30.mp4', out: '', silent: '40 s', img: 'stalled', counts: [11, 4, '3m 52s'], tone: 'attn' },
    retry: { vk: 'retry', verdict: 'Hit an error: trying again', title: 'Built the project', arg: 'swift build -c release 2>&1 | tail -20', out: 'error: switch must be exhaustive', outTone: 'attn', img: 'retry', counts: [8, 2, '2m 14s'], tone: 'attn' },
    note: { vk: 'working', verdict: 'Working', title: '', arg: '', out: '', quote: 'The build stops on .note, which my first edit did not cover. Folding it into the prose case now.', img: 'shell', counts: [13, 3, '2m 49s'] }
  };
  const ZONES6 = ['say', 'think', 'sense', 'act', 'shell'];
  function chipsFor(d) {
    const n = { say: d.counts[1], think: 2, sense: 3, act: 2, shell: 5 };
    return ZONES6.map(z => z === 'say' ? `<span class="zc f-say lit">${Neural.shapeSvg(z, 14)}<span>SAID</span><b>${n[z]}</b></span>` : `<span class="zc f-${z} lit">${Neural.shapeSvg(z, 14)}<span>${ZONE_LABEL[z]}</span><b>${n[z]}</b></span>`).join('');
  }
  function sync() { return `animation-delay:-${Math.round(performance.now() % 1900)}ms`; }
  function livePicImgs(theme, img, w, h) {
    const lo = LIVEIMG[theme + '-lv-' + img + '-lo'] || LIVEIMG[theme + '-' + img] || LIVEIMG[theme + '-lv-' + img];
    const hi = LIVEIMG[theme + '-lv-' + img + '-hi'];
    let s = RO.headImgHtml(lo, w, h);
    if (hi) s += RO.headImgHtml(hi, w, h).replace('class="head"', 'class="head br on"').replace('style="', `style="animation-delay:-${Math.round(performance.now() % 1900)}ms;`);
    return s;
  }
  function picHtml(d, theme, density) {
    const { w, h } = RO.picSize(density);
    const imgs = livePicImgs(theme, d.img, w, h);
    return `<div class="pic" style="width:${w}px;height:${h}px">${imgs}</div>`;
  }
  function nowHtml(d, density) {
    if (d.quote) return `<span class="nowq"><span class="qg">“</span><span class="qs">Sonnet</span><span class="nq">${esc(d.quote)}</span></span>`;
    const outCls = d.outTone ? ' ' + d.outTone : '';
    const silent = d.silent ? `<span class="silent">${NV.GL.stuck}silent for ${d.silent}</span>` : '';
    const out = d.out ? `<span class="nowout${outCls}">${esc(d.out)}</span>` : '';
    const line = `<span class="nowt"><b>${esc(d.title)}</b>${d.arg ? `<span class="nowa">${esc(d.arg)}</span>` : ''}</span>`;
    return line + (density === 'compact' ? '' : (silent || out));
  }
  function cardHtml(key, o) {
    o = o || {};
    const d = typeof key === 'string' ? DESC[key] : key;
    const density = o.density || 'comfortable', compact = density === 'compact', narrow = !!o.narrow;
    const tv = NV.TV[d.vk === 'working' ? 'working' : d.vk === 'needs' ? 'needs' : d.vk === 'stuck' ? 'stuck' : 'working'];
    const tone = d.tone || 'live';
    const glyph = d.vk === 'retry' ? NV.GL.bang : (d.vk === 'needs' ? NV.GL.pause : d.vk === 'stuck' ? NV.GL.stuck : NV.GL.pulse);
    const pic = picHtml(d, o.theme, narrow ? 'compact' : density);
    const cnt = `<span class="lcnt"><b class="n1">${d.counts[0]}</b> steps · <b class="n2">${d.counts[1]}</b> said · <b class="tm">${d.counts[2]}</b></span>`;
    const hl = `<span class="hl"><span class="vcl ${tone}">${glyph}<span>${esc(d.verdict)}</span></span>${cnt}</span>`;
    const edge = d.vk === 'needs' ? 'knock' : 'swell';
    const now = `<span class="nowline ${d.silent ? 'silent' : ''}">${nowHtml(d, narrow ? 'compact' : density)}</span>`;
    const outLine = !compact && !narrow && !d.quote && (d.out || d.silent) ? '' : '';
    const body = narrow
      ? `<span class="txt">${hl}${now}<span class="btns2"><span class="sbtn">Open</span><span class="sbtn">▶ Replay</span></span></span>`
      : `<span class="txt">${hl}<span class="zs">${chipsFor(d)}</span>${now}</span><span class="btns"><span class="sbtn">Open</span><span class="sbtn">▶ Replay</span></span>`;
    return `<button class="card lcard ${density}${narrow ? ' narrow' : ''} live-${tone} edge-${edge}" type="button" style="height:${compact ? 84 : 112}px" aria-label="${esc(d.verdict)}. Open the brain.">${pic}${body}</button>`;
  }

  /* ───── settle: 400 ms ───── */
  function settleMount(host, theme, density) {
    const d = DESC.shell, turn = TURNS.u; RO.prep(turn);
    host.innerHTML = '';
    const box = document.createElement('div');
    box.style.cssText = `position:relative;width:700px;height:${density === 'compact' ? 84 : 112}px`;
    host.appendChild(box);
    box.insertAdjacentHTML('beforeend', `<div class="sA" style="position:absolute;inset:0">${cardHtml('shell', { theme, density })}</div><div class="sB" style="position:absolute;inset:0">${with5(() => RO.cardHtml(turn, { theme, density }))}</div>`);
    const A = box.querySelector('.sA .card'), B = box.querySelector('.sB .card');
    const Ahl = A.querySelector('.hl'), Anow = A.querySelector('.nowline'), Apic = A.querySelector('.pic'), Azs = A.querySelector('.zs');
    const Bhl = B.querySelector('.hl'), Bdg = B.querySelector('.dg'), Bpic = B.querySelector('.pic'), Bzs = B.querySelector('.zs'), Bbtn = B.querySelector('.btns');
    B.style.background = 'transparent'; B.style.borderColor = 'transparent';
    B.querySelector('.btns').style.visibility = 'hidden';
    if (Bzs) Bzs.style.visibility = 'hidden';
    RO.fitQuotes(box);
    A.style.setProperty('--edge-anim', 'none');
    const hiImgs = A.querySelectorAll('img.br');
    function apply(t) {
      const e = easeOut(t / 400);
      const a = clamp(t / 170), b = clamp((t - 130) / 230);
      Apic.style.opacity = 1 - e; Bpic.style.opacity = e;
      hiImgs.forEach(i => { i.style.animation = 'none'; i.style.opacity = (1 - e) * .9; });
      Ahl.style.opacity = 1 - a; Ahl.style.transform = `translateY(${-6 * a}px)`;
      Bhl.style.opacity = b; Bhl.style.transform = `translateY(${6 * (1 - b)}px)`;
      Anow.style.opacity = 1 - clamp(t / 140);
      if (Bdg) { Bdg.style.opacity = clamp((t - 170) / 230); Bdg.style.transform = `translateY(${4 * (1 - clamp((t - 170) / 230))}px)`; }
      A.classList.toggle('settling', t > 0);
      const edgeC = `color-mix(in srgb,var(--accent) ${Math.round(100)}%,transparent)`;
      A.style.setProperty('--edge', edgeC);
      A.style.setProperty('--edgeop', t > 0 ? 1 : '');
      return { e, a, b };
    }
    apply(0);
    return { apply, box };
  }

  /* ───── the move ───── */
  const OPENMS = 320, CLOSEMS = 220;
  function te(g) { return OPENMS * (1 - Math.pow(1 - clamp(g, 0, 1), 1 / 3)); }
  function gOpen(t) { return easeOut(t / OPENMS); }
  function gClose(t, g0) { g0 = g0 == null ? 1 : g0; const dur = Math.max(110, CLOSEMS * g0); return g0 * (1 - easeInOut(t / dur)); }
  function overscale(g, dir) { if (dir !== 'open') return 0; const x = g; const u = clamp((x - .6) / .4, 0, 1); return .015 * Math.sin(Math.PI * u) * (g < 1 ? 1 : 0); }

  function moveMount(host, turn, o) {
    RO.prep(turn);
    const W = o.W, theme = o.theme, live = !!o.live, desc = o.desc || DESC.shell;
    host.innerHTML = '';
    const outer = el(`<div class="mv6" style="position:relative;width:${W}px;overflow:hidden"></div>`); host.appendChild(outer);
    const inner = el('<div style="position:relative"></div>'); outer.appendChild(inner);
    const ctl = with5(() => B4.mount(inner, turn, { W, theme, state: live ? { live: true, following: true } : { cursor: -1 }, noFooter: true, listRows: 9, headKey: theme + '-sonnet3-settled', accScroll: live ? undefined : 0 }));
    const M = ctl.M, cardH = M.cardH || 112, FOOT = 56;
    const rowH = (M.layout === 'split' ? M.rowH : inner.offsetHeight) ;
    const full = rowH + FOOT;
    inner.insertAdjacentHTML('beforeend', `<div class="m-foot" style="position:absolute;left:0;top:${rowH + 8}px;width:${W}px;opacity:0">${ST.footerHtml(turn, W, {})}</div>`);
    const foot = inner.querySelector('.m-foot');
    const cardWrap = el(`<div class="m-card" style="position:absolute;left:0;top:0;width:${W}px;height:112px">${live ? cardHtml(desc, { theme }) : with5(() => RO.cardHtml(turn, { theme, density: 'comfortable' }))}</div>`);
    outer.appendChild(cardWrap);
    const cardEl = cardWrap.querySelector('.card'); const cardPic = cardWrap.querySelector('.pic');
    cardPic.style.visibility = 'hidden';
    const edgeEl = el('<i style="position:absolute;left:0;top:0;width:3px;height:112px;background:var(--accent);border-radius:1px;opacity:0;z-index:3"></i>'); outer.appendChild(edgeEl);
    cardEl.classList.add('moving'); cardEl.style.setProperty('--edge', 'transparent');
    const stage = ctl.stageEl;
    const rowRect = inner.getBoundingClientRect(), stRect = stage.getBoundingClientRect();
    const left = stRect.left - rowRect.left, top = stRect.top - rowRect.top;
    const ps = RO.picSize('comfortable'), pic = { x: 16, y: (112 - ps.h) / 2, w: ps.w, h: ps.h };
    const imgEls = stage.querySelectorAll('img.head'); const finalImg = imgEls[0];
    const face = 'sonnet3';
    let lightsHost = null, restImg = null;
    if (live) {
      const lo = LIVEIMG[theme + '-lv-' + desc.img + '-lo'] || LIVEIMG[theme + '-lv-' + desc.img];
      const hi = LIVEIMG[theme + '-lv-' + desc.img + '-hi'];
      finalImg.src = lo;
      if (hi) { const h2 = finalImg.cloneNode(); h2.src = hi; h2.className = 'head br on'; h2.style.cssText += ';' + sync().replace('animation-delay', 'animation-delay'); h2.style.animationDelay = `-${Math.round(performance.now() % 1900)}ms`; finalImg.after(h2); }
      stage.querySelectorAll('img.head.br').forEach(i => { i.style.animationDelay = `-${Math.round(performance.now() % 1900)}ms`; });
    } else {
      restImg = finalImg.cloneNode(); restImg.src = ASSET(theme + '-' + face + '-rest', 'stage'); restImg.className = 'head rest'; stage.insertBefore(restImg, finalImg);
      lightsHost = el('<div class="lights" style="position:absolute;inset:0;overflow:hidden"></div>');
      const L = cardWrap.querySelector('.pic svg.light'), R = cardWrap.querySelector('.pic svg.ringsvg');
      lightsHost.innerHTML = L.outerHTML.replace(/width="\d+" height="\d+"/, `width="${M.Hs}" height="${M.Hh}"`).replace(/id="g-/g, 'id="mg-').replace(/url\(#g-/g, 'url(#mg-') + R.outerHTML.replace(/width="\d+" height="\d+"/, `width="${M.Hs}" height="${M.Hh}"`);
      lightsHost.querySelectorAll('svg').forEach(s => s.style.cssText = 'position:absolute;inset:0');
      stage.insertBefore(lightsHost, stage.querySelector('.nodes'));
    }
    const sweep = el('<div class="sweep" style="position:absolute;inset:0;mix-blend-mode:screen;opacity:0;pointer-events:none"></div>'); stage.appendChild(sweep);
    stage.style.overflow = 'hidden'; stage.style.transformOrigin = '0 0';
    const svg = ctl.info.svg, nodeEls = ctl.nodes, nN = turn.steps.length;
    const edges = [...svg.querySelectorAll('path.e')];
    edges.forEach(p => { try { const L = p.getTotalLength(); p.dataset.len = L; p.style.strokeDasharray = L + ' ' + L; } catch (e) {} });
    const tieEls = [...svg.querySelectorAll('.tie,.tie-l')], zl = [...svg.querySelectorAll('.zl')];
    const edgeNodes = turn.an.edges.map(e => typeof e.b === 'object' ? e.b.ids[e.b.ids.length - 1] : e.b);
    const lcol = ctl.row.querySelector('.lcol'), chip = ctl.row.querySelector('.chiprow'), lwrap = ctl.row.querySelector('.lwrap'), acct = ctl.row.querySelector('.acct') || ctl.row.querySelector('.acslot');
    const rows = [...ctl.row.querySelectorAll('.lr')];
    const nowTop = acct ? acct.querySelector('.nowl,.ac-top5') : null;
    const cardNow = cardWrap.querySelector('.nowline,.dg,.zs');
    const cardTxt = cardWrap.querySelectorAll('.txt,.btns,.btns2');
    const state = { g: 0, dir: 'open', t: 0 };
    function paint(g, dir, t) {
      state.g = g; state.dir = dir; state.t = t;
      const T = te(g);
      const sc = 1 + overscale(g, dir);
      const rx = pic.x + (left - pic.x) * g, ry = pic.y + (top - pic.y) * g, rw = pic.w + (M.Hs - pic.w) * g;
      const base = rw / M.Hs, s = base * sc;
      const cx = (M.Hs * s - M.Hs * base) / 2;
      stage.style.transform = `translate(${rx - cx}px,${ry - cx * (M.Hh / M.Hs)}px) scale(${s})`;
      stage.style.borderRadius = (8 * (1 - g) / Math.max(base, .01)) + 'px';
      outer.style.height = (cardH + (full - cardH) * g) + 'px';
      const cs = clamp(1 - T / 90);
      cardEl.style.background = `color-mix(in srgb,var(--raised) ${cs * 100}%,transparent)`;
      cardEl.style.borderColor = `color-mix(in srgb,var(--rule) ${cs * 100}%,transparent)`;
      cardTxt.forEach(n => { n.style.opacity = clamp(1 - T / 90); n.style.transform = `translateX(${-8 * clamp(T / 90)}px)`; });
      const ex = dir === 'open' ? clamp(T / 90) : clamp((1 - T / 90));
      edgeEl.style.left = (ex * (rx - 12 - 0)) + 'px';
      edgeEl.style.opacity = T < 90 ? 1 : clamp(1 - (T - 90) / 60);
      if (restImg) { finalImg.style.opacity = clamp((T - 40) / 160); lightsHost.style.opacity = 1 - clamp((T - 40) / 160); restImg.style.opacity = 1; }
      const sw = dir === 'open' && T > 40 && T < 200 ? Math.sin(Math.PI * clamp((T - 40) / 160)) : 0;
      if (sw > .001) { const x = (-.25 + 1.5 * clamp((T - 40) / 160)) * 100; sweep.style.background = `linear-gradient(105deg,transparent ${x - 14}%,color-mix(in srgb,var(--accent) ${Math.round(42 * sw)}%,transparent) ${x}%,transparent ${x + 14}%)`; sweep.style.opacity = 1; } else sweep.style.opacity = 0;
      const nodeStart = i => 120 + 150 * (i / Math.max(1, nN - 1));
      const pop = u => { u = clamp(u); const c = 1.7; const v = 1 + (c + 1) * Math.pow(u - 1, 3) + c * Math.pow(u - 1, 2); return .6 + .4 * v; };
      nodeEls.forEach((n, i) => { const u = (T - nodeStart(i)) / 30; n.style.opacity = easeOut(u); n.dataset.base = n.dataset.base || n.getAttribute('transform'); n.style.transformBox = 'view-box'; n.style.transformOrigin = '0 0'; n.setAttribute('transform', n.dataset.base + ` scale(${dir === 'open' ? pop(u) : 1})`); });
      edges.forEach((p, i) => { const L = +p.dataset.len || 0, wp = clamp((T - (nodeStart(edgeNodes[i] != null ? edgeNodes[i] : nN - 1) + 10)) / 70); p.style.strokeDashoffset = L * (1 - wp); p.style.opacity = wp > 0 ? '' : 0; });
      tieEls.forEach(x => x.style.opacity = clamp((T - 260) / 40)); zl.forEach(z => z.style.opacity = clamp((T - 100) / 80));
      const lcA = clamp((T - 90) / 90);
      if (chip) { chip.style.opacity = lcA; chip.style.transform = `translateY(${(1 - lcA) * 4}px)`; }
      const lh = ctl.row.querySelector('.lh'); if (lh) lh.style.opacity = lcA;
      rows.forEach((r, k) => { const p = clamp((T - (100 + k * 12)) / 70); r.style.opacity = p; r.style.transform = `translateY(${(1 - p) * 6}px)`; });
      const hint = ctl.row.querySelector('.lhint'); if (hint) hint.style.opacity = clamp((T - 260) / 50);
      if (acct) { const ra = easeOut((T - 130) / 170); acct.style.opacity = ra; acct.style.transform = M.layout === 'split' ? `translateX(${24 * (1 - ra)}px)` : `translateY(${12 * (1 - ra)}px)`; }
      if (nowTop && live) nowTop.style.opacity = easeOut((T - 190) / 110);
      foot.style.opacity = clamp((T - 240) / 80);
      return { g, T, scale: s, row: Math.round(cardH + (full - cardH) * g), cardA: clamp(1 - T / 90), acctA: easeOut((T - 150) / 170), footA: clamp((T - 240) / 80), edge: T < 90 ? 1 : clamp(1 - (T - 90) / 60) };
    }
    function open(t) { return paint(gOpen(t), 'open', t); }
    function close(t, g0) { return paint(gClose(t, g0), 'close', t); }
    open(0);
    return { open, close, paint, state, outer, full, cardH, W, ctl };
  }
  function strip(r) { return `p ${r.g.toFixed(2)} · row ${r.row} px · scale ${r.scale.toFixed(3)} · card α ${r.cardA.toFixed(2)} · acct α ${Math.max(0, r.acctA).toFixed(2)} · edge ${r.edge.toFixed(2)}`; }
  return { DESC, cardHtml, settleMount, moveMount, strip, gOpen, gClose, easeOut, easeInOut, OPENMS, CLOSEMS, te };
})();
