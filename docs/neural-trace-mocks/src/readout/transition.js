// NeuralTransition as a function of time: section 3 of the spec, numbers only, then one renderer that applies them.
const TR = (function () {
  const clamp = (v, a = 0, b = 1) => Math.max(a, Math.min(b, v));
  const lerp = (a, b, t) => a + (b - a) * t;
  const easeOutCubic = x => 1 - Math.pow(1 - clamp(x), 3);
  const easeInCubic = x => Math.pow(clamp(x), 3);
  const easeInOut = x => { x = clamp(x); return x < .5 ? 4 * x * x * x : 1 - Math.pow(-2 * x + 2, 3) / 2; };
  const backC = (function () {
    let lo = 0, hi = 6;
    for (let k = 0; k < 40; k++) {
      const c = (lo + hi) / 2;
      let mx = 0;
      for (let u = 0; u <= 1; u += .005) { const v = 1 + (c + 1) * Math.pow(u - 1, 3) + c * Math.pow(u - 1, 2); mx = Math.max(mx, .6 + .4 * v); }
      if (mx > 1.06) hi = c; else lo = c;
    }
    return (lo + hi) / 2;
  })();
  const popScale = u => { u = clamp(u); const v = 1 + (backC + 1) * Math.pow(u - 1, 3) + backC * Math.pow(u - 1, 2); return .6 + .4 * v; };

  const OPEN = 320, CLOSE = 220;

  /** Every number for one instant. dir 'open' | 'close'; t in ms from the press (close counts its own 220 ms). */
  function frame(t, dir, nNodes) {
    const f = { dir, t };
    if (dir === 'open') {
      f.duration = OPEN;
      f.g = easeOutCubic(t / OPEN);
      f.cardText = 1 - clamp(t / 90);
      f.cardTextDx = -8 * clamp(t / 90);
      f.cardSurface = 1 - clamp(t / 90);
      f.sweepOn = t > 40 && t < 200;
      f.sweep = clamp((t - 40) / 160);
      f.sweepAmt = f.sweepOn ? Math.sin(Math.PI * clamp((t - 40) / 160)) : 0;
      f.lights = 1 - easeOutCubic((t - 40) / 160);
      f.nodeStart = i => 120 + 150 * (i / Math.max(1, nNodes - 1));
      f.nodeP = i => clamp((t - f.nodeStart(i)) / 30);
      f.nodeScale = i => popScale(f.nodeP(i));
      f.nodeAlpha = i => easeOutCubic(f.nodeP(i));
      f.wireP = i => clamp((t - (f.nodeStart(i) + 10)) / 70);
      f.ties = clamp((t - 260) / 40);
      f.readoutDx = 24 * (1 - easeOutCubic((t - 150) / 170));
      f.readoutAlpha = easeOutCubic((t - 150) / 170);
      f.contentAlpha = clamp((t - 230) / 90);
      f.footer = clamp((t - 240) / 80);
    } else {
      f.duration = CLOSE;
      f.g = 1 - easeInCubic(t / CLOSE);
      f.cardText = clamp((t - 100) / 120);
      f.cardTextDx = -8 * (1 - clamp((t - 100) / 120));
      f.cardSurface = clamp((t - 120) / 100);
      f.sweepOn = false; f.sweep = 0; f.sweepAmt = 0;
      f.lights = clamp((t - 130) / 90);
      f.nodeStart = i => 0;
      f.nodeP = i => 1 - clamp(t / 150);
      f.nodeScale = i => 1;
      f.nodeAlpha = i => 1 - clamp(t / 150);
      f.wireP = i => 1 - clamp(t / 150);
      f.ties = 1 - clamp(t / 100);
      f.readoutDx = 24 * easeInCubic(t / 100);
      f.readoutAlpha = 1 - clamp(t / 100);
      f.contentAlpha = 1 - clamp(t / 60);
      f.footer = 1 - clamp(t / 100);
    }
    f.lightsRest = 1 - f.lights;
    return f;
  }

  function mount(host, turn, o) {
    RO.prep(turn);
    const W = o.W, theme = o.theme, M = RO.metrics(W, o.density || 'comfortable');
    const S = M.S, H = M.H, R = M.R, cardH = M.cardH, FOOT = 56, RH = M.rowH;
    const ps = RO.picSize(o.density || 'comfortable'), picW = ps.w, picH = ps.h, picX = 16, picY = (cardH - picH) / 2;
    const full = RH + FOOT;
    host.innerHTML = '';
    const row = el(`<div class="trow" style="position:relative;width:${W}px;height:${cardH}px"></div>`);
    host.appendChild(row);

    const card = el(`<div class="t-card" style="position:absolute;left:0;top:0;width:${W}px;height:${cardH}px">${RO.cardHtml(turn, { theme, density: 'comfortable' })}</div>`);
    row.appendChild(card);
    const cardEl = card.querySelector('.card');
    const cardPic = card.querySelector('.pic');
    const cardTxt = card.querySelectorAll('.txt,.btns');
    cardPic.style.visibility = 'hidden';

    const face = RO.faceKey(turn);
    const trav = el(`<div class="t-trav" style="position:absolute;left:0;top:0;width:${S}px;height:${H}px;transform-origin:0 0;overflow:hidden;will-change:transform">
      ${RO.headImgHtml(ASSET(theme + '-' + face + '-rest', 'stage'), S, H).replace('class="head"', 'class="a"')}
      ${RO.headImgHtml(ASSET(theme + '-' + face + '-settled', 'stage'), S, H).replace('class="head"', 'class="b"').replace('style="', 'style="opacity:0;')}
      <div class="lights" style="position:absolute;inset:0"></div>
      <div class="sweep" style="position:absolute;inset:0;mix-blend-mode:screen;opacity:0"></div>
      <div class="stage" style="position:absolute;inset:0;width:${S}px;height:${H}px"><div class="nodes"></div></div>
    </div>`);
    row.appendChild(trav);
    const lights = trav.querySelector('.lights');
    lights.innerHTML = card.querySelector('.pic svg.light').outerHTML.replace(/width="\d+" height="\d+"/, `width="${S}" height="${H}"`) + card.querySelector('.pic svg:not(.light)').outerHTML.replace(/width="\d+" height="\d+"/, `width="${S}" height="${H}"`);
    lights.querySelectorAll('svg').forEach(s => { s.style.cssText = 'position:absolute;inset:0'; s.querySelectorAll('radialGradient').forEach(g => { g.id = 't' + g.id; }); s.querySelectorAll('circle[fill^="url"]').forEach(c => c.setAttribute('fill', c.getAttribute('fill').replace('url(#', 'url(#t'))); });

    const ro = el(`<div class="t-ro" style="position:absolute;left:${S + M.gutter}px;top:0;width:${R}px;height:${RH}px;opacity:0"></div>`);
    row.appendChild(ro);
    const model = RO.digestReadout(turn);
    ro.innerHTML = RO.readoutHtml(model, { style: `height:${RH}px` });
    const roEl = ro.querySelector('.ro');
    const foot = el(`<div class="t-foot" style="position:absolute;left:0;top:${RH + 8}px;width:${W}px;opacity:0">${ST.footerHtml(turn, W, {})}</div>`);
    row.appendChild(foot);

    const ghost = ro;
    const stageEl = trav.querySelector('.stage');
    const info = ST.mountNodes(stageEl, turn, { S, hot: null, leader: false });
    const svg = info.svg;
    const nodeEls = [...svg.querySelectorAll('.n')];
    const edges = [...svg.querySelectorAll('path.e')];
    edges.forEach(p => { try { const L = p.getTotalLength(); p.dataset.len = L; p.style.strokeDasharray = L + ' ' + L; } catch (e) {} });
    const tieEls = [...svg.querySelectorAll('.tie')];
    const vias = [...svg.querySelectorAll('.via')];
    const zl = [...svg.querySelectorAll('.zl')];
    const tieLabels = [...svg.querySelectorAll('.tie-l')];
    const an = turn.an;
    const edgeTarget = edges.map(p => 0);
    const nN = turn.steps.length;
    const wires = []; let k = 0;
    const edgeNodes = [];
    an.edges.forEach(e => { const b = typeof e.b === 'object' ? e.b.ids[e.b.ids.length - 1] : e.b; edgeNodes.push(b); });
    const seen = new Set(); const edgeIdx = [];
    an.edges.forEach((e, i) => { edgeIdx.push(i); });
    const wireNode = edges.map((p, i) => edgeNodes[i] != null ? edgeNodes[i] : nN - 1);
    const sweepTone = getComputedStyle(row).getPropertyValue('--accent') || '#fff';
    const sweepEl = trav.querySelector('.sweep');

    const picRect = { x: picX, y: picY, w: picW, h: picH };
    const stageRect = { x: 0, y: 0, w: S, h: H };

    function apply(t, dir) {
      const f = frame(t, dir, nN);
      const g = f.g;
      const rx = lerp(picRect.x, stageRect.x, g), ry = lerp(picRect.y, stageRect.y, g);
      const rw = lerp(picRect.w, stageRect.w, g), rh = lerp(picRect.h, stageRect.h, g);
      const sc = rw / S;
      trav.style.transform = `translate(${rx}px,${ry}px) scale(${sc})`;
      trav.style.borderRadius = (8 * (1 - g) / Math.max(sc, .01)) + 'px';
      row.style.height = lerp(cardH, full, g) + 'px';
      cardEl.style.opacity = '1';
      cardEl.style.background = `color-mix(in srgb,var(--raised) ${f.cardSurface * 100}%,transparent)`;
      cardEl.style.borderColor = `color-mix(in srgb,var(--rule) ${f.cardSurface * 100}%,transparent)`;
      cardEl.style.setProperty('--edge-a', f.cardSurface);
      cardEl.style.boxShadow = 'none';
      cardEl.querySelectorAll('.txt,.btns').forEach(n => { n.style.opacity = f.cardText; n.style.transform = `translateX(${f.cardTextDx}px)`; });
      cardEl.style.setProperty('--edge', `color-mix(in srgb,${cardEl.classList.contains('failed') ? 'var(--danger)' : 'var(--accent)'} ${f.cardText * 100}%,transparent)`);
      trav.querySelector('img.b').style.opacity = f.lightsRest;
      lights.style.opacity = f.lights;
      if (f.sweepAmt > 0.001) {
        const x = lerp(-.25, 1.25, f.sweep) * 100;
        sweepEl.style.background = `linear-gradient(105deg,transparent ${x - 14}%,color-mix(in srgb,var(--accent) ${Math.round(70 * f.sweepAmt)}%,transparent) ${x}%,transparent ${x + 14}%)`;
        sweepEl.style.opacity = 1;
      } else sweepEl.style.opacity = 0;
      nodeEls.forEach((n, i) => {
        const a = f.nodeAlpha(i), s = f.nodeScale(i);
        n.style.opacity = a;
        n.style.transformBox = 'view-box'; n.style.transformOrigin = '0 0';
        const base = n.getAttribute('transform');
        n.dataset.base = n.dataset.base || base;
        n.setAttribute('transform', n.dataset.base + ` scale(${s})`);
      });
      edges.forEach((p, i) => {
        const L = +p.dataset.len || 0, wp = f.wireP(wireNode[i]);
        p.style.strokeDashoffset = L * (1 - wp);
        p.style.opacity = wp > 0 ? '' : 0;
      });
      vias.forEach(v => { v.style.opacity = f.wireP(nN - 1) > 0 ? 1 : 0; });
      tieEls.forEach(x => { x.style.opacity = f.ties; });
      tieLabels.forEach(x => { x.style.opacity = f.ties; });
      zl.forEach(z => { z.style.opacity = clamp((t - 100) / 80); if (dir === 'close') z.style.opacity = 1 - clamp(t / 120); });
      ro.style.opacity = f.readoutAlpha;
      ro.style.transform = `translateX(${f.readoutDx}px)`;
      roEl.querySelector('.ro-bd').style.opacity = f.contentAlpha;
      foot.style.opacity = f.footer;
      return f;
    }
    apply(0, 'open');
    return { apply, frame, row, W, S, H, full, cardH };
  }

  return { frame, mount, OPEN, CLOSE, easeOutCubic, easeInCubic, popScale, backC };
})();
