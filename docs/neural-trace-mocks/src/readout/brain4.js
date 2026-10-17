// Fourth pass: the right side is the account. Left column: small head, filter chips, step list. Right: the agent's turn in its own words.
const B4 = (function () {
  const clamp = RO.clamp, ROW = 28;
  const OPT4 = window.OPT4 = window.OPT4 || { lcMin: 320, lcMax: 360, lcK: .27, splitAt: 924, storyMin: 440, detailMin: 460, rows: 9 };

  function metrics(W, o) {
    o = o || {};
    const rowsN = o.listRows || OPT4.rows;
    if (W >= 860) {
      const Lw = clamp(Math.round(OPT4.lcK * W), OPT4.lcMin, OPT4.lcMax), Hs = Lw, Hh = Math.round(Hs * 420 / 576);
      const A = W - 24 - Lw;
      const split = A >= OPT4.splitAt;
      const story = split ? clamp(Math.round(.42 * A), OPT4.storyMin, 680) : A;
      const detail = split ? A - 24 - story : 0;
      const rowsH = rowsN * ROW;
      const rowH = Hh + 8 + 34 + 36 + rowsH + 4 + 24;
      return { layout: 'split', W, Lw, Hs, Hh, A, split, story, detail, rowsH, rowH, gutter: 24, R: A };
    }
    const Hs = Math.min(W, 280), Hh = Math.round(Hs * 420 / 576);
    return { layout: 'stacked', W, Lw: W, Hs, Hh, A: W, split: false, rowsH: 0, rowH: 0, gutter: 0, R: W };
  }

  function mount(host, turn, o) {
    RO.prep(turn);
    const M = metrics(o.W, o);
    const st = Object.assign({ cursor: -1, hover: -1, zones: null, failed: false, query: '', searchOpen: false, following: true, live: false, menu: false, legend: false, focus: null }, o.state || {});
    if (st.zones && !(st.zones instanceof Set)) st.zones = new Set(st.zones);
    host.innerHTML = '';
    const row = document.createElement('div');
    row.className = 'row4 ' + M.layout;
    host.appendChild(row);
    const headKey = o.headKey || (o.theme + '-' + RO.faceKey(turn) + '-settled');
    o.unfold = new Set(o.unfold || []); o.showAll = new Set(o.showAll || []);
    const ctl = { st, M, turn, row, host, o, kind: 'acct' };
    if (M.layout === 'split') {
      row.style.cssText = `position:relative;width:${M.W}px;height:${M.rowH}px`;
      row.innerHTML = `<div class="lcol" style="position:absolute;left:0;top:0;width:${M.Lw}px;height:${M.rowH}px">
        <div class="stage" style="position:absolute;left:0;top:0;width:${M.Hs}px;height:${M.Hh}px;overflow:visible">${RO.headImgHtml(ASSET(headKey, 'stage'), M.Hs, M.Hh)}<div class="nodes"></div></div>
        <div class="lwrap" style="position:absolute;left:0;top:${M.Hh + 8}px;width:${M.Lw}px;height:${M.rowH - M.Hh - 8}px"><div class="chiprow" style="height:34px"></div><div class="lbody"></div></div>
      </div><div class="acct" style="position:absolute;left:${M.Lw + 24}px;top:0;width:${M.A}px;height:${M.rowH}px"><i class="tab-mark" style="position:absolute;left:-1px;width:3px;height:24px;background:var(--t,var(--accent));display:none;z-index:3;border-radius:1px"></i><div class="acslot" style="height:100%"></div></div>`;
    } else {
      row.style.cssText = `position:relative;width:${M.W}px`;
      row.innerHTML = `<div class="stage" style="position:relative;margin:0 auto;width:${M.Hs}px;height:${M.Hh}px;overflow:visible">${RO.headImgHtml(ASSET(headKey, 'stage'), M.Hs, M.Hh)}<div class="nodes"></div></div><div class="chiprow" style="margin-top:8px"></div><div class="acslot narrow" style="margin-top:4px"></div>`;
    }
    ctl.stageEl = row.querySelector('.stage');
    ctl.info = ST.mountNodes(ctl.stageEl, turn, { S: M.Hs, hot: null, leader: false });
    ctl.nodes = [...ctl.info.svg.querySelectorAll('.n')];
    ctl.render = () => render(ctl);
    render(ctl);
    if (!o.noFooter) host.insertAdjacentHTML('beforeend', ST.footerHtml(turn, o.W, o.footer || {}));
    return ctl;
  }

  function render(ctl) {
    const { st, M, turn, row, o } = ctl;
    const lbody = row.querySelector('.lbody');
    ctl.vis = BR.visible(turn, st);
    if (M.layout === 'split') {
      const lb = BR.listBlock(turn, st, { rowsH: M.rowsH, focus: st.focus === 'list', hint: true });
      lbody.innerHTML = lb.html;
      row.querySelector('.chiprow').innerHTML = BR.zoneChips(turn, st);
      const rows = lbody.querySelector('.lrows');
      if (rows) {
        const cur = st.cursor, el = cur >= 0 ? rows.querySelector(`.lr[data-i="${cur}"]`) : null;
        const maxTop = Math.max(0, rows.scrollHeight - rows.clientHeight);
        if (o.listScroll != null) rows.scrollTop = o.listScroll;
        else if (el && (ctl.lastCur !== cur)) { const want = clamp(el.offsetTop - (M.rowsH - el.offsetHeight) / 2, 0, maxTop); let snap = 0; rows.querySelectorAll('.lr').forEach(r => { if (r.offsetTop <= want + 1) snap = r.offsetTop; }); rows.scrollTop = snap; ctl.lastTop = rows.scrollTop; }
        else rows.scrollTop = ctl.lastTop || 0;
        if (st.live && st.following) rows.scrollTop = rows.scrollHeight;
        ctl.lastCur = cur;
        rows.addEventListener('scroll', () => { ctl.lastTop = rows.scrollTop; });
      }
      BR.fitArgs(lbody);
    } else {
      row.querySelector('.chiprow').innerHTML = BR.zoneChips(turn, st);
    }
    account(ctl);
    BR.head(ctl);
    if (st.legend) legend(ctl);
  }

  function selectedStep(ctl) {
    const st = ctl.st;
    const i = st.hover >= 0 && st.hover !== st.cursor ? st.hover : st.cursor;
    return i >= 0 ? ctl.turn.steps[i] : null;
  }
  function account(ctl) {
    const { st, M, turn, o } = ctl;
    const slot = ctl.row.querySelector('.acslot');
    const c = AC.counts(turn);
    const solo = st.zones && st.zones.size === 1 && st.zones.has('say');
    const filt = BR.filtered(st);
    const ao = { unfold: o.unfold, showAll: o.showAll, split: M.split, arrive: o.arrive, planOpen: o.planOpen, planCompact: o.planCompact };
    const oldBox = slot.querySelector(M.split ? '.story' : '.ac-bd'); const oldTop = oldBox ? oldBox.scrollTop : null; const oldDet = slot.querySelector('.detcol'); const oldDetTop = oldDet ? oldDet.scrollTop : 0;
    const v5 = OPT.v5 ? AC.html5(turn, st, ao) : null;
    const story = v5 ? v5.body : AC.html(turn, st, ao);
    const hdRight = st.live ? (st.following === false ? 'following paused' : 'following') : `${c.said} said · ${c.steps} steps · ${turn.dur}`;
    const hd = `<div class="ac-hd"><span class="lbl">${solo ? 'What it told you' : 'The account'}</span>${turn.outcome === 'running' ? '<span class="chip run">LIVE</span>' : '<span class="chip ok">SETTLED</span>'}${filt ? `<span class="chip filt">filtered</span>` : ''}<span class="ct">${hdRight}</span></div>`;
    const pill = st.live && st.following === false ? '<button class="follow acf" type="button">Following paused · jump to latest <kbd>End</kbd></button>' : '';
    const ft = `<div class="ac-ft"><span><kbd>s</kbd><kbd>S</kbd> said</span><span><kbd>a</kbd> ask</span><span><kbd>↑</kbd><kbd>↓</kbd> items</span><span><kbd>Enter</kbd> detail</span><span class="sp"></span><span>${turn.steps[0].at}</span></div>`;
    let body;
    const topHtml = v5 ? `<div class="ac-top5">${v5.top}</div>` : hd;
    if (M.split) {
      const sel = selectedStep(ctl);
      let det;
      if (sel && sel.fam !== 'say' && sel.fam !== 'think') { const m = RO.stepReadout(turn, sel, { pinned: st.cursor === sel.i }); det = `<div class="det f-${sel.fam}">${m.hd.replace('class="ro-hd', 'class="dc-hd')}<div class="dc-bd">${m.bd}</div>${m.ft.replace('class="ro-ft"', 'class="dc-ft"')}</div>`; }
      else { const m = RO.digestReadout(turn); det = `<div class="det digest">${m.hd.replace('class="ro-hd', 'class="dc-hd')}<div class="dc-bd">${m.bd}</div></div>`; }
      body = `<div class="ac-split" style="grid-template-columns:${M.story}px ${M.detail}px"><div class="story scrollable">${story}</div><div class="detcol scrollable">${det}</div></div>`;
    } else body = `<div class="story scrollable" style="max-width:${o.storyMax || 760}px">${story}</div>`;
    slot.innerHTML = `${topHtml}<div class="ac-bd">${body}</div>${pill}${M.layout === 'split' ? ft : ''}`;
    slot.classList.toggle('focus', st.focus === 'account');
    const same = ctl.lastAccCur === st.cursor && oldTop != null && !ctl.forceAcc;
    OPT.outMax = 8;
    const sc = slot.querySelector('.story');
    const cur = st.cursor >= 0 ? slot.querySelector(`[data-i="${st.cursor}"]`) : null;
    if (st.live && st.following) { const sc2 = M.split ? slot.querySelector('.story') : slot.querySelector('.ac-bd'); (sc2 || sc).scrollTop = 1e6; }
    else if (cur && o.accScroll == null) { const box = M.split ? sc : slot.querySelector('.ac-bd'); let anchor = cur.closest('.it.work') || cur; const pv = anchor.previousElementSibling; if (pv && pv.classList.contains('said')) anchor = pv; box.scrollTop = Math.max(0, anchor.getBoundingClientRect().top - box.getBoundingClientRect().top + box.scrollTop - 8); }
    else if (o.accScroll != null) { (M.split ? sc : slot.querySelector('.ac-bd')).scrollTop = o.accScroll; }
    if (same && !(st.live && st.following)) { const nb = slot.querySelector(M.split ? '.story' : '.ac-bd'); if (nb) nb.scrollTop = oldTop; const nd = slot.querySelector('.detcol'); if (nd) nd.scrollTop = oldDetTop; }
    ctl.lastAccCur = st.cursor; ctl.forceAcc = false;
    BR.fitArgs(slot);
    const tab = ctl.row.querySelector('.tab-mark');
    ctl.row.querySelectorAll('.acslot .stt.pend').forEach(n => n.remove());
  }
  function legend(ctl) {
    const T = [['↑ ↓  k j', 'previous, next step'], ['s  S', 'next, previous thing it said'], ['a', 'jump to what it asks'], ['[ ]  p n', 'previous, next failed'], ['← →  h l', 'previous, next in this zone'], ['r', 'go to the related step'], ['PgUp PgDn', '8 steps'], ['Home End  g G', 'first, last (End follows)'], ['1  2–6  0', 'solo SAID, other zones, clear'], ['! x', 'failed only'], ['/', 'search'], ['Enter', 'into the account, and back'], ['Space', 'unfold work, show all'], ['c  C', 'copy command, output'], ['Esc', 'search, filters, cursor, close']];
    const el = document.createElement('div');
    el.className = 'legend';
    const cell = ([k, d]) => `<div class="lg-r${k === 's  S' || k === 'a' ? ' new' : ''}"><span class="kk">${k.split('  ').map(g => g.split(' ').map(x => `<kbd>${x}</kbd>`).join('')).join('<i>or</i>')}</span><span class="dd">${d}</span></div>`;
    el.innerHTML = `<div class="lg-h"><span class="lbl">Keys</span><kbd>?</kbd></div><div class="lg-g" style="grid-template-rows:repeat(8,26px)">${T.map(cell).join('')}</div>`;
    el.style.left = Math.round((ctl.M.W - 760) / 2) + 'px'; el.style.top = '60px';
    ctl.row.appendChild(el);
  }
  return { mount, metrics, render, OPT4 };
})();
