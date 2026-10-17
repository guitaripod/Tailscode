// The open row: head left, leader line, readout right, footer. Uses the first design's node engine for nodes, wires and ties.
const ST = (function () {
  const LABEL_W = { think: 22, sense: 30, act: 20, shell: 30, delegate: 44, say: 20 };

  function positions(steps) {
    const cnt = {};
    return steps.map(s => {
      const n = cnt[s.fam] || 0; cnt[s.fam] = n + 1;
      const list = Neural.ZONE_SLOTS[s.fam], o = list[Math.min(n, list.length - 1)], c = Neural.ZONES[s.fam];
      return { x: c[0] + o[0], y: c[1] + o[1] };
    });
  }
  function segDist(p, a, b) {
    const dx = b.x - a.x, dy = b.y - a.y, l2 = dx * dx + dy * dy || 1;
    const t = RO.clamp(((p.x - a.x) * dx + (p.y - a.y) * dy) / l2, 0, 1);
    return Math.hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy));
  }
  function segHitsBox(a, b, bx) {
    for (let t = 0; t <= 1; t += .04) {
      const x = a.x + (b.x - a.x) * t, y = a.y + (b.y - a.y) * t;
      if (x > bx.x0 && x < bx.x1 && y > bx.y0 && y < bx.y1) return true;
    }
    return false;
  }
  function polyLen(pts) { let l = 0; for (let i = 1; i < pts.length; i++) l += Math.hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y); return l; }

  function labelBoxes() {
    return Object.keys(Neural.ZONES).map(z => {
      const c = Neural.ZONES[z], wr = z === 'say' ? [56, 38] : [66, 58], w = LABEL_W[z] + 4;
      return { x0: c[0] - w, x1: c[0] + w, y0: c[1] - wr[1] - 17, y1: c[1] - wr[1] + 3 };
    });
  }

  function route(P, T, others, r, boxes) {
    const stub = 14, x1 = P.x + stub, cands = [];
    const lanes = [0, -16, 16, -32, 32, -48, 48, -64, 64, -90, 90];
    lanes.forEach(off => {
      const yL = RO.clamp(P.y + off, 6, 414);
      const d1 = Math.abs(yL - P.y), d2 = Math.abs(T.y - yL);
      const xmax = T.x - d1 - d2;
      if (xmax < x1 - .5) return;
      [x1, (x1 + xmax) / 2, xmax].forEach(xa => {
        const pts = [P, { x: x1, y: P.y }];
        if (xa > x1 + .5) pts.push({ x: xa, y: P.y });
        if (d1 > .5) pts.push({ x: pts[pts.length - 1].x + d1, y: yL });
        if (d2 > .5) { pts.push({ x: Math.max(pts[pts.length - 1].x, T.x - d2), y: yL }); }
        pts.push({ x: T.x, y: T.y });
        cands.push({ pts, off });
      });
    });
    let best = null;
    cands.forEach(c => {
      let hits = 0;
      for (let i = 1; i < c.pts.length; i++) {
        others.forEach(o => { if (segDist(o, c.pts[i - 1], c.pts[i]) < r + 5) hits++; });
        boxes.forEach(b => { if (segHitsBox(c.pts[i - 1], c.pts[i], b)) hits += 2; });
      }
      const cost = polyLen(c.pts) + hits * 500 + c.pts.length * 5 + Math.abs(c.off) * 2;
      if (!best || cost < best.cost) best = { pts: c.pts, cost, hits };
    });
    return best;
  }

  function mountNodes(stageEl, turn, o) {
    const S = o.S, V = RO.VIEW(), u0 = S / V.w;
    const host = stageEl.querySelector('.nodes');
    const r = Math.round(RO.clamp(11 / u0, 9, 14) * 10) / 10;
    const groups = new Set(turn.steps.map(s => s.msg)).size;
    const nv = Neural.mount(host, { steps: turn.steps, layout: 'cortex', bare: true, say: true, r, spacing: { def: 28, say: 24 }, step: Math.min(.5, 14 / groups), eye: 'done', label: 'Everything the agent did before answering' });
    const svg = host.querySelector('.nv-svg');
    svg.setAttribute('viewBox', V.x0 + ' 0 ' + V.w + ' 420');
    nv.settle();
    const pos = positions(turn.steps);
    const target = o.hot != null && o.hot >= 0 ? o.hot : (o.leaderFor != null ? o.leaderFor : -1);
    if (o.hot != null && o.hot >= 0 && !o.noDim) nv.setHot(o.hot);
    else if (o.set) nv.setSet(o.set);
    const info = { nv, svg, pos, u: u0, r, view: { x0: V.x0, y0: 0, w: V.w, h: 420, s: 1 } };
    if (o.dive) {
      const c = Neural.ZONES[o.dive.zone], s = o.dive.s, w = 640 / s, h = 420 / s;
      info.view = { x0: c[0] - w / 2, y0: c[1] - h / 2, w, h, s };
      svg.setAttribute('viewBox', [info.view.x0, info.view.y0, w, h].join(' '));
      svg.style.clipPath = 'inset(0)';
      info.u = S / w;
    }
    if (target >= 0 && o.leader !== false) {
      if (o.dive) drawLeaderPx(stageEl, turn, info, o, target);
      else drawLeader(stageEl, turn, info, Object.assign({}, o, { hot: target }));
    }
    return info;
  }

  function drawLeader(stageEl, turn, info, o) {
    const { svg, pos, u, r, view } = info;
    const s = turn.steps[o.hot], P = pos[o.hot];
    const gutPx = o.gutter == null ? 24 : o.gutter;
    const Tx = view.x0 + view.w + gutPx / u;
    const H = stageEl.offsetHeight;
    const hdY = 20, lo = 40 + 16, hi = H - 32 - 16;
    let Ty;
    if (o.anchor === 'header') Ty = hdY / u;
    else Ty = RO.clamp(P.y * u, lo, hi) / u;
    const others = pos.filter((p, i) => i !== o.hot);
    const best = route({ x: P.x, y: P.y }, { x: Tx, y: Ty }, others, r, labelBoxes());
    const pts = best.pts.slice();
    const ns = 'http://www.w3.org/2000/svg';
    const g = document.createElementNS(ns, 'g');
    g.setAttribute('class', 'leader f-' + s.fam);
    const path = document.createElementNS(ns, 'path');
    path.setAttribute('d', 'M' + pts.map(p => p.x.toFixed(1) + ',' + p.y.toFixed(1)).join('L'));
    path.setAttribute('style', 'stroke:var(--t);stroke-opacity:.7;stroke-width:1.25px;vector-effect:non-scaling-stroke');
    g.appendChild(path);
    const dot = document.createElementNS(ns, 'circle');
    dot.setAttribute('cx', Tx); dot.setAttribute('cy', pts[pts.length - 1].y); dot.setAttribute('r', 2.5 / u);
    dot.setAttribute('style', 'fill:var(--t)');
    g.appendChild(dot);
    const ring = document.createElementNS(ns, 'circle');
    ring.setAttribute('cx', P.x); ring.setAttribute('cy', P.y); ring.setAttribute('r', r + 5);
    ring.setAttribute('style', 'fill:none;stroke:var(--t);stroke-opacity:.8;stroke-width:1.25px;vector-effect:non-scaling-stroke');
    g.appendChild(ring);
    svg.insertBefore(g, svg.querySelector('.n'));
    info.leader = { g, path, dot, ring, pts, Ty, Tx, best };
    const tab = stageEl.parentElement && stageEl.parentElement.querySelector('.tab-mark');
    if (tab) { tab.style.top = (Ty * u - 12) + 'px'; tab.style.display = o.anchor === 'header' || RO.OPT.noTab ? 'none' : 'block'; }
    return info.leader;
  }

  function drawLeaderPx(stageEl, turn, info, o, idx) {
    const v = info.view, u = o.S / v.w, s = turn.steps[idx], P0 = info.pos[idx];
    const P = { x: (P0.x - v.x0) * u, y: (P0.y - v.y0) * u };
    const H = stageEl.offsetHeight, gut = o.gutter == null ? 24 : o.gutter;
    const Tx = o.S + gut, Ty = RO.clamp(P.y, 56, H - 48);
    const stub = 18, x1 = P.x + stub, ay = Math.abs(Ty - P.y);
    const xd = Math.max(x1, Tx - ay - 10);
    const pts = [P, { x: x1, y: P.y }];
    if (ay > 1) { pts.push({ x: xd, y: P.y }); pts.push({ x: xd + ay, y: Ty }); }
    pts.push({ x: Tx, y: Ty });
    const ns = 'http://www.w3.org/2000/svg';
    const svg = document.createElementNS(ns, 'svg');
    svg.setAttribute('class', 'leader-px');
    svg.setAttribute('width', Tx + 6); svg.setAttribute('height', H);
    svg.style.cssText = 'position:absolute;left:0;top:0;overflow:visible;pointer-events:none';
    const g = document.createElementNS(ns, 'g'); g.setAttribute('class', 'leader f-' + s.fam);
    g.innerHTML = `<path d="M${pts.map(p => p.x.toFixed(1) + ',' + p.y.toFixed(1)).join('L')}" style="stroke:var(--t);stroke-opacity:.7;stroke-width:1.25px;fill:none;stroke-linejoin:round"/><circle cx="${Tx}" cy="${Ty}" r="2.5" style="fill:var(--t)"/><circle cx="${P.x}" cy="${P.y}" r="${info.r * v.s + 5}" style="fill:none;stroke:var(--t);stroke-opacity:.8;stroke-width:1.25px"/>`;
    svg.appendChild(g);
    stageEl.appendChild(svg);
    const tab = stageEl.parentElement.querySelector('.tab-mark');
    if (tab) { tab.style.top = (Ty - 12) + 'px'; tab.style.display = 'block'; }
  }

  function footerHtml(turn, W, o) {
    o = o || {};
    const n = turn.steps.length;
    const marks = turn.steps.map((s, i) => s.status === 'fail' ? `<i class="fm" style="left:${(i + .5) / n * 100}%"></i>` : '').join('');
    const narrow = W < 640;
    const prov = turn.provenance && W >= 960 ? `<span class="ia"><span class="lbl">In the answer</span>${turn.provenance.map(p => `<span class="pchip">${RO.esc(p)}</span>`).join('')}</span>` : '';
    const frac = o.scrub == null ? 1 : o.scrub;
    const last = turn.steps[turn.steps.length - 1];
    const btn = W < 960 ? '' : '<button class="pb" type="button" title="Esc">Close</button>';
    return `<div class="rfoot" style="width:${W}px"><button class="pb" type="button">▶${narrow ? '' : ' Replay'}</button><span class="scrub"><span class="trk"></span><span class="fill" style="width:${frac * 100}%"></span>${marks}<span class="th" style="left:${frac * 100}%"></span></span><span class="t">${last.at || ''}</span>${prov}<button class="pb" type="button">Rows</button><button class="pb" type="button">Share</button>${btn}</div>`;
  }

  function build(host, turn, o) {
    RO.prep(turn);
    const M = RO.metrics(o.W, o.density);
    const S = M.S, H = M.H, R = M.R;
    const headKey = o.headKey || (o.theme + '-' + RO.faceKey(turn) + '-settled');
    host.innerHTML = '';
    const row = document.createElement('div');
    row.className = 'row';
    row.style.width = o.W + 'px';
    if (M.layout === 'stacked') { row.style.flexDirection = 'column'; row.style.gap = '12px'; }
    const stage = document.createElement('div');
    stage.className = 'stage';
    stage.style.width = S + 'px'; stage.style.height = H + 'px';
    const trimmedOff = o.dive;
    let img;
    if (trimmedOff) img = `<img class="head" alt="" src="${ASSET(headKey, 'stage')}" style="position:absolute;left:0;top:0;width:${S}px;height:${H}px">`;
    else img = RO.headImgHtml(ASSET(headKey, 'stage'), S, H);
    stage.innerHTML = img + '<div class="nodes"></div>';
    row.appendChild(stage);
    const wrap = document.createElement('div');
    wrap.className = 'ro-wrap';
    wrap.style.cssText = `position:relative;width:${R}px;height:${M.layout === 'stacked' ? 'auto' : M.rowH + 'px'}`;
    wrap.innerHTML = `<i class="tab-mark" style="position:absolute;left:-1px;width:3px;height:24px;background:var(--t,var(--accent));display:none;z-index:2;border-radius:1px"></i>`;
    row.appendChild(wrap);
    host.appendChild(row);
    return { M, row, stage, wrap };
  }

  return { build, mountNodes, drawLeader, footerHtml, positions, route };
})();
