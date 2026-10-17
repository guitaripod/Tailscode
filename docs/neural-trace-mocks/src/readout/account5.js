// Fifth pass account: the entity's window. Header, Asked, Needs you, Plan, Now, the story in plain words, Result.
(function () {
  const esc = RO.esc, MINUS = '−';
  const FAM = AC.FAMHEX;
  const NAME = { fable: 'Fable', opus: 'Opus', sonnet: 'Sonnet', haiku: 'Haiku' };

  function bars(n) { return '<span class="eff" title="effort">' + [4, 6, 8, 10, 12].map((h, i) => `<b style="height:${h}px;${i < n ? '' : 'opacity:.25'}"></b>`).join('') + '</span>'; }
  function counts(turn, tv) {
    const said = turn.steps.filter(s => s.fam === 'say').length;
    let s = `${said} said · ${turn.steps.length} steps`;
    if (tv.fixed) s += ` · ${tv.fixed} ${tv.fixed === 1 ? 'error' : 'errors'} fixed`;
    if (tv.failed) s += ` · ${tv.failed} failed`;
    return s;
  }
  function header(turn, tv) {
    const spk = turn.speaker || NAME[turn.family] || turn.family;
    const pill = `<span class="vpill ${tv.tone}">${NV.GL[tv.gl]}<span>${tv.words}</span></span>`;
    let sentence = tv.head;
    if (tv.key === 'retry') sentence = `<span class="vamber">${NV.GL.retry}${'fixed ' + (tv.fixed === 1 ? '1 error' : tv.fixed + ' errors') + ' on the way'}</span>`;
    else sentence = esc(tv.head.replace(/^Finished in /, 'in '));
    const first = tv.key === 'retry' || tv.key === 'done' ? `<span class="vt">in ${turn.dur}</span>` : '';
    const line2 = (tv.key === 'done' || tv.key === 'retry') ? `${first}${tv.key === 'retry' ? ' · ' + sentence : ''}` : esc(tv.head);
    return `<div class="eh"><i class="fam" style="background:${FAM[turn.family] || 'var(--accent)'}"></i><b>${esc(spk)}</b>${bars(turn.effort)}${pill}<span class="vline">${line2}</span><span class="sp"></span><span class="ect">${counts(turn, tv)}</span></div>`;
  }
  function asked(turn) {
    return `<section class="asked"><span class="lbl">Asked</span><p class="aq">${esc(turn.prompt)}</p></section>`;
  }
  function planBlock(turn, atStep, o) {
    const pl = NV.plan(turn, atStep);
    if (!pl) return '';
    const pct = Math.round(pl.done / pl.total * 100);
    const collapsed = turn.outcome !== 'running' && pl.done === pl.total && !o.planOpen;
    let h = `<section class="plan${collapsed ? ' collapsed' : ''}"><div class="ph"><span class="chev">${collapsed ? '\u25b8' : '\u25be'}</span><span class="lbl">Plan</span><b>${pl.done} of ${pl.total} done</b><span class="pbar"><i style="width:${pct}%"></i></span></div>${collapsed ? '' : '<ul>'}`;
    if (!collapsed) pl.items.forEach(it => {
      const ic = it.st === 'done' ? NV.GL.check : it.st === 'doing' ? '<i class="pulse"></i>' : '<i class="tdot"></i>';
      h += `<li class="${it.st}"><span class="pi">${ic}</span><span class="pt">${esc(it.c)}</span></li>`;
    });
    return h + (collapsed ? '' : '</ul>') + '</section>';
  }
  function planCompact(turn) {
    const pl = NV.plan(turn, turn.planAt);
    if (!pl) return '';
    const cur = pl.items.find(i => i.st === 'doing');
    return `<section class="plan compact"><div class="ph"><span class="chev">\u25b8</span><span class="lbl">Plan</span><b>${pl.done} of ${pl.total} done</b><span class="segs">${pl.items.map(i => `<i class="${i.st}"></i>`).join('')}</span>${cur ? `<span class="cur"><i class="pulse"></i>${esc(cur.c)}</span>` : ''}</div></section>`;
  }
  function nowLine(turn, tv) {
    const s = turn.steps.find(x => x.status === 'run');
    if (!s) return '';
    const silent = !!turn.silentFor;
    const tail = (s.out || []).slice(-2);
    return `<section class="nowl${silent ? ' silent' : ''}"><div class="nh"><i class="pulse${silent ? ' attn' : ''}"></i><span class="lbl">Now</span><b>${esc(NH.title(turn, s))}</b><span class="since">${silent ? NV.GL.stuck + 'silent for ' + turn.silentFor : 'last output 4 s ago'}</span></div><div class="na">${esc(s.arg || '')}</div><pre class="out" style="margin:6px 0 0">${tail.map(l => `<span class="l">${esc(l)}</span>`).join('')}<span class="l"><i class="caret"></i></span></pre></section>`;
  }

  function cutWords(t, n) { if (t.length <= n) return t; const k = t.lastIndexOf(' ', n); return t.slice(0, k > 0 ? k : n) + ' \u2026'; }
  function clauses(turn, ids) {
    const steps = ids.map(i => turn.steps[i]);
    const out = [];
    const groups = new Map();
    steps.forEach(s => {
      const cat = NH.category(turn, s);
      const key = (s.fam === 'act' || cat === 'read' || cat === 'search' || cat === 'build' || cat === 'test') ? cat + (cat === 'build' || cat === 'test' ? '' : '') : cat;
      const gk = s.tool === 'Edit' ? 'edit:' + s.arg : s.tool === 'Read' ? 'read' : s.tool === 'Grep' ? 'grep' : (cat === 'build' || cat === 'test') ? cat : 'x:' + NH.title(turn, s).replace(/ again$/, '');
      const g = groups.get(gk) || { steps: [], cat };
      g.steps.push(s); groups.set(gk, g);
    });
    groups.forEach((g, gk) => {
      const last = g.steps[g.steps.length - 1];
      const vs = g.steps.map(s => NV.stepVerdict(turn, s));
      if (gk.startsWith('edit:')) { const d = g.steps.reduce((a, s) => [a[0] + (s.diff ? s.diff[0] : 0), a[1] + (s.diff ? s.diff[1] : 0)], [0, 0]); out.push({ t: 'Edited ' + RO.dirfile(last.arg).fn, delta: d }); }
      else if (gk === 'read') out.push({ t: g.steps.length === 1 ? NH.title(turn, last) : `Read ${g.steps.length} files` });
      else if (gk === 'grep') out.push({ t: g.steps.length === 1 ? NH.title(turn, last) : `Searched ${g.steps.length} times` });
      else {
        const t = (g.cat === 'build' || g.cat === 'test') ? NH.title(turn, g.steps.find(s => vs[g.steps.indexOf(s)].key !== 'fixed') || last).replace(/ again$/, '').replace(/^Ran the build$/, 'Built the project') : NH.title(turn, last);
        const finalOk = last.status === 'ok';
        out.push({ t: g.steps.length > 1 && g.cat !== 'build' && g.cat !== 'test' ? `${t} (${g.steps.length}×)` : t, ok: (g.cat === 'build' || g.cat === 'test') && finalOk });
      }
      vs.forEach((v, k) => {
        const s = g.steps[k];
        if (v.key === 'fixed') out.push({ amber: `fixed an error at step ${s.i + 1}` });
        if (v.key === 'failed') out.push({ danger: `failed at step ${s.i + 1}` });
        if (v.key === 'trying') out.push({ amber: `hit an error at step ${s.i + 1}` });
      });
    });
    return out;
  }
  function clauseHtml(c) {
    if (c.amber) return `<span class="wc amber">${NV.GL.retry}${esc(c.amber)}</span>`;
    if (c.danger) return `<span class="wc danger">${NV.GL.cross}${esc(c.danger)}</span>`;
    return `<span class="wc">${esc(c.t)}${c.delta ? ` <span class="a">+${c.delta[0]}</span> <span class="d">${MINUS}${c.delta[1]}</span>` : ''}${c.ok ? ' <span class="ok">' + NV.GL.check + '</span>' : ''}</span>`;
  }
  const origWork = AC.workLine;
  function workLine5(turn, w, st, o) {
    const open = o.unfold.has(w.ids[0]) || w.ids.includes(st.cursor) || w.ids.includes(st.hover) || (st.live && st.following !== false && w.ids.includes(turn.steps.length - 1));
    const cl = clauses(turn, w.ids);
    const shown = cl.slice(0, 4), more = cl.length - shown.length;
    const fams = [...new Set(w.ids.map(i => turn.steps[i].fam))];
    const first = w.ids[0] + 1, last = w.ids[w.ids.length - 1] + 1;
    let h = `<div class="it work${open ? ' open' : ''}" data-w="${w.ids[0]}"><button class="wl" type="button"><span class="chev">${open ? '▾' : '▸'}</span><span class="wms">${fams.map(f => `<span class="wm f-${f}">${Neural.shapeSvg(f, 18)}</span>`).join('')}</span><span class="wcs">${shown.map(clauseHtml).join('<i class="dot">·</i>')}${more > 0 ? `<i class="dot">·</i><span class="wc more">+${more} more</span>` : ''}</span><span class="wsp"></span><span class="wn">${first === last ? '#' + first : '#' + first + '–' + last}</span></button>`;
    if (open) {
      const rows = w.ids.map(i => BR.rowsOf(turn)[i]);
      h += '<div class="wrows">';
      rows.forEach((r, k) => {
        h += BR.rowHtml(turn, r, st, rows, k);
        const tip = st.live && st.following !== false && r.i === turn.steps.length - 1 && st.cursor < 0;
        if (!o.split && (st.cursor === r.i || (st.hover === r.i && st.hover !== st.cursor) || tip)) h += AC.detailCard(turn, r.s, st.cursor === r.i, o);
      });
      h += '</div>';
    }
    return h + '</div>';
  }

  function resultBlock(turn, tv) {
    const R = NV.result(turn);
    let h = '<section class="result"><div class="rh"><span class="lbl">Result</span></div>';
    if (R.files.length) {
      h += '<div class="rg"><div class="rl">Changed</div>' + R.files.map(f => `<div class="rf" data-i="${f.ids[0] - 1}"><span class="pth">${RO.pathHtml(f.p, true)}</span><span class="pm"><i class="a" style="flex:${f.a}"></i>${f.d ? `<i class="d" style="flex:${f.d}"></i>` : ''}</span><span class="st"><span class="a">+${f.a}</span> <span class="d">${MINUS}${f.d}</span></span><span class="sn">#${f.ids.join(', #')}</span></div>`).join('') + '</div>';
    }
    if (R.checks.length) {
      h += '<div class="rg"><div class="rl">Checks</div>' + R.checks.map(c => {
        const ok = c.last.status === 'ok';
        const word = ok ? (c.fails ? `passed after ${c.fails} ${c.fails === 1 ? 'retry' : 'retries'}` : 'passed') : 'failed';
        const cls = ok ? (c.fails ? 'amber' : 'ok') : 'danger';
        const g = ok ? (c.fails ? NV.GL.retry : NV.GL.check) : NV.GL.cross;
        const label = c.cat === 'build' ? 'Build' : 'Tests';
        return `<div class="rc ${cls}"><span class="rv">${g}</span><b>${label}</b><span class="rcmd">${esc(c.arg)}</span><span class="rw">${word}</span><span class="sn">#${c.ids.join(', #')}</span></div>`;
      }).join('') + '</div>';
    }
    if (R.unfixed.length) {
      h += '<div class="rg"><div class="rl danger">Still failing</div>' + R.unfixed.map(s => `<div class="rc danger"><span class="rv">${NV.GL.cross}</span><b>${esc(NH.title(turn, s))}</b><span class="rcmd">${esc((s.out || []).find(l => /error|fail/i.test(l)) || (s.out || [])[0] || '')}</span><span class="sn">#${s.i + 1}</span></div>`).join('') + '</div>';
    }
    if (!R.files.length && !R.checks.length && !R.unfixed.length) h += `<div class="rg"><div class="rnone">${R.reads ? 'It only looked: read ' + R.reads + (R.reads === 1 ? ' file' : ' files') + ', changed nothing.' : 'It changed no files and ran no build or test.'}</div></div>`;
    else if (!R.files.length) h += '<div class="rg"><div class="rnone">It changed no files.</div></div>';
    if (turn.answer) h += `<div class="rg"><div class="rl">Then it answered</div><p class="say">${esc(cutWords(turn.answer[0].replace(/`/g, ''), 150))}</p></div>`;
    else if (turn.outcome === 'answerless') h += '<div class="rg"><div class="rnone">It ended without an answer.</div></div>';
    return h + '</section>';
  }

  AC.html5 = function (turn, st, o) {
    o = Object.assign({ unfold: new Set(), showAll: new Set(), split: false }, o || {});
    const tv = NV.turnVerdict(turn);
    const running = turn.outcome === 'running';
    const items = AC.structure(turn, st);
    let body = '';
    const ask = turn.steps.find(s => s.status === 'wait');
    body += asked(turn);
    if (ask) body += AC.askItem(turn, ask);
    const pl = planBlock(turn, running ? turn.planAt : null, o);
    if (!running) body += pl;
    body += '<div class="story5">';
    let prev = null;
    items.forEach(it => {
      if (it.kind === 'said') body += AC.saidItem(turn, it, st, o, prev);
      else if (it.kind === 'thought') body += AC.thoughtItem(turn, it, st);
      else body += workLine5(turn, it, st, o);
      prev = it;
    });
    body += '</div>';
    if (!running) body += resultBlock(turn, tv);
    return { top: header(turn, tv) + (running ? nowLine(turn, tv) + (o.planCompact ? planCompact(turn) : pl) : ''), body, tv };
  };
  AC.clauses = clauses; AC.header5 = t => header(t, NV.turnVerdict(t)); AC.result5 = t => resultBlock(t, NV.turnVerdict(t)); AC.work5 = workLine5; AC.plan5 = planBlock;
})();
