// The transition for the third-pass layout: the card's picture travels to the small head, the filter panel and list rows arrive after it.
const TR2 = (function () {
  const clamp = (v, a = 0, b = 1) => Math.max(a, Math.min(b, v)), lerp = (a, b, t) => a + (b - a) * t;
  function mount(host, turn, o) {
    RO.prep(turn);
    const W = o.W, theme = o.theme;
    host.innerHTML = '';
    const outer = el(`<div class="trow2" style="position:relative;width:${W}px;overflow:hidden"></div>`);
    host.appendChild(outer);
    const inner = el('<div></div>'); outer.appendChild(inner);
    const ctl = BR.mount(inner, turn, { W, theme, state: {}, listRows: o.listRows || 9, noFooter: true, headKey: theme + '-' + RO.faceKey(turn) + '-settled' });
    const M = ctl.M, FOOT = 56, cardH = 112, full = M.rowH + FOOT;
    const row = ctl.row;
    inner.insertAdjacentHTML('beforeend', `<div class="t-foot" style="position:absolute;left:0;top:${M.rowH + 8}px;width:${W}px;opacity:0">${ST.footerHtml(turn, W, {})}</div>`);
    const foot = inner.querySelector('.t-foot');
    inner.style.position = 'relative';
    const card = el(`<div class="t-card" style="position:absolute;left:0;top:0;width:${W}px;height:${cardH}px">${RO.cardHtml(turn, { theme, density: 'comfortable' })}</div>`);
    outer.appendChild(card);
    const cardEl = card.querySelector('.card');
    card.querySelector('.pic').style.visibility = 'hidden';
    const stage = ctl.stageEl;
    const left = M.Lw - M.Hs;
    const ps = RO.picSize('comfortable'), pic = { x: 16, y: (cardH - ps.h) / 2, w: ps.w, h: ps.h };
    const face = RO.faceKey(turn);
    stage.insertAdjacentHTML('afterbegin', RO.headImgHtml(ASSET(theme + '-' + face + '-rest', 'stage'), M.Hs, M.Hh).replace('class="head"', 'class="a"'));
    const imgs = stage.querySelectorAll('img');
    const finalImg = [...imgs].find(i => i.className === 'head');
    const lightsHost = el(`<div class="lights" style="position:absolute;inset:0;overflow:hidden"></div>`);
    lightsHost.innerHTML = card.querySelector('.pic svg.light').outerHTML.replace(/width="\d+" height="\d+"/, `width="${M.Hs}" height="${M.Hh}"`).replace(/id="g-/g, 'id="tg-').replace(/url\(#g-/g, 'url(#tg-') + card.querySelector('.pic svg.ringsvg').outerHTML.replace(/width="\d+" height="\d+"/, `width="${M.Hs}" height="${M.Hh}"`);
    lightsHost.querySelectorAll('svg').forEach(s => s.style.cssText = 'position:absolute;inset:0');
    stage.style.overflow = 'hidden'; stage.style.transformOrigin = '0 0';
    stage.insertBefore(lightsHost, stage.querySelector('.nodes'));
    const sweep = el('<div class="sweep" style="position:absolute;inset:0;mix-blend-mode:screen;opacity:0;pointer-events:none"></div>');
    stage.appendChild(sweep);
    const svg = ctl.info.svg;
    const nodeEls = ctl.nodes;
    const edges = [...svg.querySelectorAll('path.e')];
    edges.forEach(p => { try { const L = p.getTotalLength(); p.dataset.len = L; p.style.strokeDasharray = L + ' ' + L; } catch (e) {} });
    const tieEls = [...svg.querySelectorAll('.tie,.tie-l')];
    const zl = [...svg.querySelectorAll('.zl')];
    const nN = turn.steps.length;
    const edgeNodes = turn.an.edges.map(e => typeof e.b === 'object' ? e.b.ids[e.b.ids.length - 1] : e.b);
    const lh = row.querySelector('.lh'), fpanel = row.querySelector('.fpanel'), rows = [...row.querySelectorAll('.lr')], hint = row.querySelector('.lhint');
    const ro = row.querySelector('.ro-wrap');
    ro.style.opacity = 0;
    ctl.row.querySelector('.ro-bd');
    function apply(t, dir) {
      const f = TR.frame(t, dir, nN);
      const g = f.g;
      const rx = lerp(pic.x, left, g), ry = lerp(pic.y, 0, g), rw = lerp(pic.w, M.Hs, g);
      const sc = rw / M.Hs;
      stage.style.transform = `translate(${rx - left}px,${ry}px) scale(${sc})`;
      stage.style.borderRadius = (8 * (1 - g) / Math.max(sc, .01)) + 'px';
      outer.style.height = lerp(cardH, full, g) + 'px';
      cardEl.style.background = `color-mix(in srgb,var(--raised) ${f.cardSurface * 100}%,transparent)`;
      cardEl.style.borderColor = `color-mix(in srgb,var(--rule) ${f.cardSurface * 100}%,transparent)`;
      cardEl.style.setProperty('--edge', `color-mix(in srgb,var(--accent) ${f.cardText * 100}%,transparent)`);
      cardEl.querySelectorAll('.txt,.btns').forEach(n => { n.style.opacity = f.cardText; n.style.transform = `translateX(${f.cardTextDx}px)`; });
      finalImg.style.opacity = f.lightsRest;
      lightsHost.style.opacity = f.lights;
      if (f.sweepAmt > .001) { const x = lerp(-.25, 1.25, f.sweep) * 100; sweep.style.background = `linear-gradient(105deg,transparent ${x - 14}%,color-mix(in srgb,var(--accent) ${Math.round(70 * f.sweepAmt)}%,transparent) ${x}%,transparent ${x + 14}%)`; sweep.style.opacity = 1; } else sweep.style.opacity = 0;
      nodeEls.forEach((n, i) => {
        n.style.opacity = f.nodeAlpha(i); n.style.transformBox = 'view-box'; n.style.transformOrigin = '0 0';
        n.dataset.base = n.dataset.base || n.getAttribute('transform');
        n.setAttribute('transform', n.dataset.base + ` scale(${f.nodeScale(i)})`);
      });
      edges.forEach((p, i) => { const L = +p.dataset.len || 0, wp = f.wireP(edgeNodes[i] != null ? edgeNodes[i] : nN - 1); p.style.strokeDashoffset = L * (1 - wp); p.style.opacity = wp > 0 ? '' : 0; });
      tieEls.forEach(x => x.style.opacity = f.ties);
      zl.forEach(z => { z.style.opacity = dir === 'close' ? 1 - clamp(t / 120) : clamp((t - 100) / 80); });
      const pa = dir === 'open' ? clamp((t - 150) / 100) : 1 - clamp(t / 80);
      if (fpanel) fpanel.style.opacity = pa; if (lh) lh.style.opacity = pa; if (hint) hint.style.opacity = dir === 'open' ? clamp((t - 260) / 50) : 1 - clamp(t / 80);
      rows.forEach((r, k) => {
        const p = dir === 'open' ? clamp((t - (130 + k * 12)) / 70) : 1 - clamp((t - k * 3) / 70);
        r.style.opacity = p; r.style.transform = `translateY(${(1 - p) * 6}px)`;
      });
      ro.style.opacity = f.readoutAlpha; ro.style.transform = `translateX(${f.readoutDx}px)`;
      foot.style.opacity = f.footer;
      return f;
    }
    apply(0, 'open');
    return { apply, frame: TR.frame, row: outer, full, W, M };
  }
  return { mount };
})();
