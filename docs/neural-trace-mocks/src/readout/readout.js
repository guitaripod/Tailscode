// The readout, the card and the stage, as one library. Everything here is the mock; the real thing is Core + clients.
const OPT = window.OPT = window.OPT || { trim: true, anchor: 'row', relationsUp: true, minH: 420 };
const RO = (function () {
  const esc = s => String(s).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
  const clamp = (v, a, b) => Math.max(a, Math.min(b, v));
  const MINUS = '−';
  const shape = (fam, size) => Neural.shapeSvg(fam, size);
  const ZN = ZONE_LABEL, ZONES = Neural.ZONES;

  function prep(turn) {
    if (turn.prepped) return turn;
    const st = turn.steps;
    st.forEach((s, i) => { s.i = i; });
    turn.an = Neural.analyse(st);
    st.forEach((s, i) => {
      if (s.status === 'fail' && s.key && !s.retriedAt) {
        const later = st.findIndex((t, j) => j > i && t.key === s.key && t.status === 'ok');
        if (later >= 0) s.retriedAt = later + 1;
      }
    });
    turn.count = {};
    ZORDER.forEach(z => { turn.count[z] = st.filter(s => s.fam === z).length; });
    turn.tools = Neural.toolCount(st);
    turn.tally = Neural.diffTally(st);
    turn.fails = st.filter(s => s.status === 'fail');
    turn.unrecovered = turn.fails.filter(s => !s.retriedAt && !s.recovered);
    turn.prepped = true;
    return turn;
  }

  function sentence(turn) {
    const st = turn.steps, n = (f, t) => st.filter(s => s.fam === f && (!t || s.tool === t)).length;
    const cmd = n('shell'), rd = n('sense', 'Read'), gr = n('sense', 'Grep'), ed = n('act'), dl = n('delegate');
    const bits = [];
    const word = (k, one, many) => k === 1 ? one : many.replace('#', k);
    if (cmd) bits.push(word(cmd, 'ran one command', 'ran # commands'));
    if (rd) bits.push(word(rd, 'read one file', 'read # files'));
    if (gr) bits.push(word(gr, 'searched once', gr === 2 ? 'searched twice' : 'searched # times'));
    if (ed) bits.push(word(ed, 'edited one file', 'edited # files'));
    if (dl) bits.push(word(dl, 'asked a reviewer', 'asked # agents'));
    let s = bits.join(', ');
    s = s.replace(/, ([^,]+)$/, bits.length > 1 ? ' and $1' : ', $1');
    s = s.charAt(0).toUpperCase() + s.slice(1) + '.';
    return s;
  }
  function failClause(turn, short) {
    const r = turn.fails.filter(s => s.retriedAt || s.recovered).length, u = turn.unrecovered.length;
    if (u) return u + ' failed';
    if (!r) return '';
    return (r === 1 ? (short ? '1 failed, then passed' : 'One command failed, then passed.') : r + ' failed, then passed');
  }
  function digestLine(turn) {
    let s = sentence(turn);
    const fc = failClause(turn, false);
    if (fc) s += ' ' + fc;
    if (turn.provenance && turn.provenance.length && turn.id === 'big') s += ' Wrote ' + turn.provenance[0] + '.';
    return s;
  }
  function dirfile(p) {
    const i = p.lastIndexOf('/');
    return i < 0 ? { dir: '', fn: p } : { dir: p.slice(0, i + 1), fn: p.slice(i + 1) };
  }
  function shortDir(d) { const parts = d.split('/').filter(Boolean); return parts.length > 2 ? '\u2026/' + parts.slice(-2).join('/') + '/' : d; }
  function pathHtml(p, short) { const d = dirfile(p); return `<span class="dir">${esc(short ? shortDir(d.dir) : d.dir)}</span><span class="fn">${esc(d.fn)}</span>`; }
  function tone(s) { return 'f-' + s.fam; }
  function statusOf(s) {
    return { ok: ['DONE', 'ok'], fail: ['FAILED', 'fail'], run: ['RUNNING', 'run'], wait: ['WAITING FOR YOU', 'wait'], stall: ['STALLED', 'stall'], stopped: ['STOPPED', 'stopped'] }[s.status] || ['DONE', 'ok'];
  }

  function relations(turn, s) {
    const st = turn.steps, out = [];
    if (s.status === 'fail' && s.retriedAt) out.push({ kind: 'retry', label: 'retried at', ids: [s.retriedAt - 1] });
    else if (s.key && s.keyKind === 'cmd') {
      const prior = st.filter((t, j) => j < s.i && t.key === s.key && t.status === 'fail');
      if (prior.length) out.push({ kind: 'retry', label: 'retry of', ids: prior.map(t => t.i) });
    }
    if (s.key && s.keyKind !== 'cmd') {
      const o = st.filter(t => t.key === s.key && t.i !== s.i).map(t => t.i);
      if (o.length) out.push({ kind: 'file', label: 'same file as', ids: o });
    }
    if (s.key && s.keyKind === 'cmd' && !out.length) {
      const o = st.filter(t => t.key === s.key && t.i !== s.i).map(t => t.i);
      if (o.length) out.push({ kind: 'cmd', label: 'same command as', ids: o });
    }
    return out;
  }

  function outBlock(s, opt) {
    opt = opt || {};
    const lines = s.out || [];
    const shown = opt.all ? lines : lines.slice(0, opt.max || OPT.outMax || 8);
    const rest = lines.length - shown.length;
    const bad = s.status === 'fail';
    const hit = l => bad && /error:|FAILED|matches no streams/i.test(l);
    return `<pre class="out${bad ? ' bad' : ''}">${shown.map(l => `<span class="l${hit(l) ? ' hit' : ''}">${esc(l)}</span>`).join('')}${opt.caret ? '<span class="l"><i class="caret"></i></span>' : ''}${rest > 0 ? `<span class="moar">${rest} more line${rest > 1 ? 's' : ''}</span>` : ''}</pre>`;
  }
  function diffBlock(s) {
    const L = s.lines || [];
    return `<div class="diff">${L.map(l => `<div class="dl ${l.k}"><span class="g">${l.k === 'add' ? '' : l.o}</span><span class="g">${l.k === 'del' ? '' : l.n}</span><span class="mk">${l.k === 'add' ? '+' : l.k === 'del' ? MINUS : ''}</span><span class="tx">${esc(l.t) || ' '}</span></div>`).join('')}</div>`;
  }
  function splitArg(s) {
    const m = (s.arg || '').split(/ {2,}/);
    return m.length > 1 ? { pat: m[0], scope: m.slice(1).join(' ') } : { pat: s.arg, scope: '' };
  }

  function stepBody(turn, s) {
    const z = ZN[s.fam];
    let h = '';
    if (s.fam === 'think' || s.fam === 'say') {
      h += `<div class="sec"><div class="subj"><h3>${s.fam === 'think' ? 'Thinking' : 'Said'}</h3></div><p class="thought">${esc(s.text)}</p></div>`;
      return h;
    }
    const copy = '<button class="sbtn copy" type="button">Copy</button>';
    h += '<div class="sec"><div class="subj"><h3 class="tn">' + esc(s.tool) + '</h3>' + (s.fam === 'delegate' && s.tool === 'Task' ? '<button class="sbtn copy" type="button">Open agent</button>' : copy) + '</div>';
    if (s.fam === 'shell') h += `<div class="cmd"><span class="ps">$</span>${esc(s.arg)}</div>`;
    else if (s.tool === 'Grep') { const g = splitArg(s); h += `<div class="cmd">${esc(g.pat)}</div><div class="path"><span class="dir">in </span>${pathHtml(g.scope)}</div>`; }
    else if (s.tool === 'Task') h += `<div class="cmd" style="font-family:var(--sans);font-size:14px">${esc(s.arg)}</div>`;
    else h += `<div class="path">${pathHtml(s.arg)}</div>`;
    h += '</div>';
    const rel = relations(turn, s);
    const relHtml = rel.length ? `<div class="sec"><div class="lbl">Relations</div><div class="rel">${rel.map(r => `<span class="rchip ${r.kind}"><span class="k">${r.label}</span> <span class="n">${r.ids.map(i => i + 1).join(', ')}</span></span>`).join('')}</div></div>` : '';
    if (OPT.relationsUp) h += relHtml;
    if (s.why) h += `<div class="sec"><div class="why"><div class="lbl">Why</div><p>${esc(s.why)}</p></div></div>`;
    if (s.fam === 'shell') {
      const n = (s.out || []).length;
      h += `<div class="sec"><div class="lbl">Output<span class="r">${s.exit != null ? 'exit ' + s.exit + ' · ' : ''}${n} line${n === 1 ? '' : 's'}</span></div>${outBlock(s)}</div>`;
    } else if (s.fam === 'act') {
      h += `<div class="sec"><div class="lbl">Diff<span class="r stat"><span class="a">+${s.diff[0]}</span> <span class="d">${MINUS}${s.diff[1]}</span></span></div>${diffBlock(s)}</div>`;
    } else if (s.tool === 'Read') {
      h += `<div class="sec"><div class="lbl">Read<span class="r">${esc((s.out || [])[0] || '')}</span></div>${outBlock(Object.assign({}, s, { out: (s.out || []).slice(1) }))}</div>`;
    } else if (s.tool === 'Grep') {
      h += `<div class="sec"><div class="lbl">Matches<span class="r">${(s.out || []).length}</span></div>${outBlock(s)}</div>`;
    } else if (s.tool === 'Task') {
      h += `<div class="sec"><div class="lbl">Result<span class="r">${esc(s.spawn || '')}</span></div>${outBlock(s)}</div>`;
    } else if (s.out) {
      h += `<div class="sec"><div class="lbl">Result</div>${outBlock(s)}</div>`;
    }
    if (!OPT.relationsUp) h += relHtml;
    return h;
  }
  function stepHeader(turn, s, pinned) {
    const [word, cls] = statusOf(s);
    const z = ZN[s.fam];
    return `<div class="ro-hd ${tone(s)}"><span class="zg">${shape(s.fam, 18)}</span><span class="zl">${z}</span><span class="chip ${cls}">${word}</span>${pinned ? '<span class="pin" title="Pinned">● pinned</span>' : ''}<span class="ct">${s.i + 1} of ${turn.steps.length}</span></div>`;
  }
  function stepFooter(turn, s) {
    const g = turn.an.groups[s.g];
    return `<div class="ro-ft"><span>message ${s.msg}</span><span>${s.at || ''}</span><span class="sp"></span><span>turn began ${turn.steps[0].at}</span></div>`;
  }
  function stepReadout(turn, s, opt) {
    opt = opt || {};
    return { hd: stepHeader(turn, s, opt.pinned), bd: `<div class="${tone(s)}">${stepBody(turn, s)}</div>`, ft: stepFooter(turn, s), cls: tone(s) };
  }

  function zoneBarsHtml(turn, compact) {
    const max = Math.max(...ZORDER.map(z => turn.count[z]));
    return `<div class="zbars${compact ? ' compact' : ''}">${ZORDER.filter(z => turn.count[z]).map(z => `<div class="rowz f-${z}"><span class="n">${ZN[z]}</span><span class="bar"><i style="width:${Math.round(turn.count[z] / max * 100)}%"></i></span><span class="c">${turn.count[z]}</span></div>`).join('')}</div>`;
  }
  function zoneChipsHtml(turn) {
    return `<div class="zchips">${ZORDER.filter(z => turn.count[z]).map(z => `<span class="zc f-${z} lit">${shape(z, 14)}<span>${ZN[z]}</span><b>${turn.count[z]}</b></span>`).join('')}</div>`;
  }
  function timelineHtml(turn, opt) {
    opt = opt || {};
    const n = turn.steps.length;
    const x = i => ((i + .5) / (n + (opt.answer === false ? 0 : 1.6))) * 100;
    let h = '<div class="tl"><div class="base"></div>';
    turn.steps.forEach((s, i) => { h += `<i class="tk f-${s.fam}${s.status === 'fail' ? ' f' : ''}${opt.on === i ? ' on' : ''}" style="left:${x(i)}%"></i>`; });
    if (opt.answer !== false) h += `<div class="ans" style="left:${x(n)}%"><span>ANSWER</span></div>`;
    return h + '</div>';
  }
  function changedFiles(turn) {
    const m = new Map();
    turn.steps.forEach(s => { if (s.fam === 'act' && s.diff) { const e = m.get(s.arg) || { p: s.arg, a: 0, d: 0, ids: [] }; e.a += s.diff[0]; e.d += s.diff[1]; e.ids.push(s.i + 1); m.set(s.arg, e); } });
    return [...m.values()];
  }
  function failuresHtml(turn) {
    if (!turn.fails.length) return '';
    return `<div class="sec fails"><div class="lbl">Failures<span class="r">${turn.fails.length}</span></div>${turn.fails.map(s => {
      const first = (s.out || []).find(l => /error:|matches no|failed/i.test(l)) || (s.out || [])[0] || '';
      return `<div class="fr"><span class="no">${s.i + 1}</span><span class="m"><div class="pth mono">${esc(s.arg)}</div><div class="s">${esc(first)}</div></span><span class="re${s.retriedAt ? '' : ' never'}">${s.retriedAt ? 'retried at ' + s.retriedAt : 'never retried'}</span></div>`;
    }).join('')}</div>`;
  }
  function digest(turn, opt) {
    opt = opt || {};
    const first = sentence(turn), fc = failClause(turn, false);
    let h = `<div class="sec"><p class="dg-h">${esc(first)}${fc ? ' <span class="f">' + esc(fc) + '</span>' : ''}</p></div>`;
    if (OPT.digestOrder === 'spec') {
      h += `<div class="sec"><div class="lbl">Where the work went</div>${zoneBarsHtml(turn)}</div>`;
      h += `<div class="sec"><div class="lbl">Timeline<span class="r">${turn.steps.length} steps</span></div>${timelineHtml(turn)}</div>`;
    } else {
      h += `<div class="sec"><div class="lbl">Where the work went<span class="r">${turn.steps.length} steps</span></div>${zoneBarsHtml(turn, true)}${timelineHtml(turn)}</div>`;
      h += failuresHtml(turn);
    }
    const ch = changedFiles(turn);
    if (ch.length) {
      h += `<div class="sec changed"><div class="lbl">Changed<span class="r stat"><span class="a">+${turn.tally[0]}</span> <span class="d">${MINUS}${turn.tally[1]}</span></span></div>${ch.map(c => {
        const tot = c.a + c.d;
        return `<div class="cr"><span class="pth">${pathHtml(c.p, true)}</span><span class="pm" style="width:${clamp(tot * 6, 12, 72)}px"><i class="a" style="flex:${c.a}"></i>${c.d ? `<i class="d" style="flex:${c.d}"></i>` : ''}</span><span class="st stat"><span class="a">+${c.a}</span> <span class="d">${MINUS}${c.d}</span></span></div>`;
      }).join('')}</div>`;
    }
    if (OPT.digestOrder === 'spec') h += failuresHtml(turn);
    if (turn.answer) {
      h += `<div class="sec"><div class="lbl">Answer</div><p class="ansl">${esc(turn.answer[0].replace(/`/g, '')).slice(0, 150)}${turn.answer[0].length > 150 ? '\u2026' : ''}</p>${turn.provenance ? `<div class="pchips">${turn.provenance.map(p => `<span class="pchip">${esc(p)}</span>`).join('')}</div>` : ''}</div>`;
    }
    return h;
  }
  function digestReadout(turn) {
    const chip = '<span class="chip ok">SETTLED</span>';
    const hd = `<div class="ro-hd"><span class="zl" style="color:var(--ink2)">TURN</span>${chip}<span class="ct">${turn.steps.length} steps \u00b7 ${turn.dur}</span></div>`;
    const ft = `<div class="ro-ft"><span>${turn.steps.length} steps</span><span>${turn.steps[0].at}</span><span class="sp"></span><span>hover a step to read it</span></div>`;
    return { hd, bd: digest(turn), ft, cls: '' };
  }

  function zoneRows(turn, zone, selIdx) {
    const rows = turn.steps.filter(s => s.fam === zone);
    return rows.map(s => `<div class="zrow f-${zone}${s.i === selIdx ? ' sel' : ''}${s.status === 'fail' ? ' bad' : ''}${s.status === 'run' ? ' run' : ''}"><span class="no">${s.i + 1}</span><span class="tn">${esc(s.tool)}</span><span class="ar">${esc(s.arg || s.text || '')}</span><span class="sd"></span></div>`).join('');
  }
  function zoneReadout(turn, zone, selIdx) {
    const rows = turn.steps.filter(s => s.fam === zone);
    const fails = rows.filter(s => s.status === 'fail').length;
    const hd = `<div class="ro-hd f-${zone}"><span class="zg">${shape(zone, 18)}</span><span class="zl">${ZN[zone]}</span><span class="chip ok">${rows.length} STEPS</span>${fails ? `<span class="chip fail">${fails} FAILED</span>` : ''}<span class="ct">esc surfaces</span></div>`;
    const bd = `<div class="sec"><div class="lbl">${ZN[zone]} · steps in order</div><div class="zlist">${zoneRows(turn, zone, selIdx)}</div></div>`;
    const ft = `<div class="ro-ft"><span>${rows.length} of ${turn.steps.length} steps</span><span class="sp"></span><span>click a row to pin it on the stage</span></div>`;
    return { hd, bd, ft, cls: 'f-' + zone };
  }

  function nowReadout(turn, s, attention) {
    const [word] = statusOf(s);
    const tail = (s.out || []).slice(-8);
    const hd = `<div class="ro-hd ${tone(s)}"><span class="now-h"><span class="pulse${attention ? ' attn' : ''}"></span><span class="nowl${attention ? ' attn' : ''}">${attention ? 'NEEDS YOU' : 'NOW'}</span></span><span class="zg">${shape(s.fam, 18)}</span><span class="zl">${ZN[s.fam]}</span><span class="chip ${attention ? 'wait' : 'run'}">${attention ? 'WAITING FOR YOU' : 'RUNNING'}</span><span class="ct">${s.i + 1} of ${s.i + 1}</span></div>`;
    let h = '';
    if (attention) {
      h += `<div class="sec"><div class="ask f-shell"><p class="q">Run <span class="mono" style="font-size:13px">scripts/install-linuxapp.sh</span>?</p><div class="cmdl"><span style="color:var(--t)">$</span> ${esc(s.arg)}</div><p class="why2">${esc(s.why)}</p><div style="display:flex;gap:8px;margin-top:12px"><button class="btn" type="button">Go to approval ↓</button></div></div></div>`;
      h += `<div class="sec" style="margin-top:12px"><div class="lbl">Waiting since 22:01:37 · the approval itself is in the transcript</div></div>`;
    } else {
      h += `<div class="sec"><div class="subj"><h3 class="tn">${esc(s.tool)}</h3><button class="sbtn copy" type="button">Copy</button></div><div class="cmd"><span class="ps">$</span>${esc(s.arg)}</div></div>`;
      h += `<div class="sec"><div class="why"><div class="lbl">Why</div><p>${esc(s.why)}</p></div></div>`;
      h += `<div class="sec"><div class="lbl">Output<span class="r">live · last ${tail.length} lines</span></div>${outBlock(Object.assign({}, s, { out: tail }), { all: true, caret: true })}</div>`;
    }
    const done = Object.assign({}, turn, { steps: turn.steps.slice(0, -1), prepped: false });
    prep(done);
    h += `<div class="sofar"><div class="lbl" style="color:var(--ink2);margin-bottom:4px">So far</div><p class="sh">${esc(sentence(done))}${failClause(done, false) ? ' <span style="color:var(--warn)">' + esc(failClause(done, false)) + '</span>' : ''}</p>${zoneChipsHtml(done)}</div>`;
    const ft = `<div class="ro-ft"><span>message ${s.msg}</span><span>${s.at}</span><span class="sp"></span><span>${attention ? 'asked' : 'started'} ${s.at}</span></div>`;
    return { hd, bd: `<div class="${tone(s)}">${h}</div>`, ft, cls: tone(s) };
  }

  function stripHtml(turn, s) {
    const [word, cls] = statusOf(s);
    const arg = s.arg || s.text || '';
    return `<div class="strip ${tone(s)}"><div class="sl1"><span class="zg">${shape(s.fam, 16)}</span><span class="zl">${ZN[s.fam]}</span><b class="tnm">${esc(s.tool)}</b><span class="chip ${cls}">${word}</span><span class="ct">${s.i + 1} of ${turn.steps.length}</span></div><div class="sl2">${s.fam === 'shell' ? '<span class="ps">$</span> ' : ''}${esc(arg)}</div></div>`;
  }
  function readoutHtml(m, extra) {
    return `<div class="ro ${m.cls || ''} ${extra && extra.cls || ''}" style="${extra && extra.style || ''}">${m.hd}<div class="ro-bd">${m.bd}</div>${m.ft}</div>`;
  }

  // ───── metrics (NeuralStageMetrics.make) ─────
  const VIEW = () => OPT.trim ? { x0: 64, w: 576 } : { x0: 0, w: 640 };
  function metrics(W, density) {
    const GUT = 24, aspect = 420 / VIEW().w;
    const cardH = density === 'compact' ? 84 : 112;
    if (W >= 860) {
      let S = clamp(.54 * W, 420, 720), R = Math.min(W - S - GUT, 560);
      if (W - S - GUT > 560) { S = Math.min(W - GUT - 560, 760); R = W - S - GUT; }
      S = Math.round(S); R = Math.round(R);
      return { layout: 'split', S, R, gutter: GUT, H: Math.round(S * aspect), cardH, rowH: Math.max(Math.round(S * aspect), OPT.minH) };
    }
    if (W >= 560) {
      const S = Math.round(W * .5), R = W - S - GUT;
      return { layout: 'split', S, R, gutter: GUT, H: Math.round(S * aspect), cardH, small: true, rowH: Math.max(Math.round(S * aspect), OPT.minH) };
    }
    const S = Math.min(W, 760);
    return { layout: 'stacked', S, R: W, gutter: 0, H: Math.round(S * aspect), cardH, rowH: Math.round(S * aspect) };
  }

  // ───── card ─────
  const LIGHT_N = z => 0;
  function picSize(density) { const v = VIEW(); const h = density === 'compact' ? 72 : 96; return { w: Math.round(h * v.w / 420), h }; }
  function headImgHtml(src, S, H) {
    const v = VIEW(), k = S / v.w;
    return `<img class="head" alt="" src="${src}" style="position:absolute;left:${-v.x0 * k}px;top:0;width:${640 * k}px;height:${H}px;max-width:none">`;
  }
  function cardPicture(turn, theme, density) {
    const { w, h } = picSize(density), v = VIEW();
    const key = theme + '-' + faceKey(turn) + '-rest';
    const id = turn.id + '-' + density + '-' + theme;
    let defs = '', circles = '', rings = '';
    ZORDER.forEach(z => {
      const n = turn.count[z]; if (!n) return;
      const c = ZONES[z], k = Math.min(n, 4), r = 44 + 12 * k, o = .62 + .1 * k;
      defs += `<radialGradient id="g-${id}-${z}" cx="${c[0]}" cy="${c[1]}" r="${r}" gradientUnits="userSpaceOnUse"><stop offset="0" stop-color="var(--t-${z})" stop-opacity="${o.toFixed(2)}"/><stop offset=".55" stop-color="var(--t-${z})" stop-opacity="${(o * .45).toFixed(2)}"/><stop offset="1" stop-color="var(--t-${z})" stop-opacity="0"/></radialGradient>`;
      circles += `<circle cx="${c[0]}" cy="${c[1]}" r="${r}" fill="url(#g-${id}-${z})"/>`;
      const bad = turn.steps.some(s => s.fam === z && s.status === 'fail' && !(s.retriedAt || s.recovered));
      const healed = turn.steps.some(s => s.fam === z && s.status === 'fail' && (s.retriedAt || s.recovered));
      if (bad) rings += `<circle cx="${c[0]}" cy="${c[1]}" r="${r + 10}" fill="none" stroke="var(--danger)" stroke-width="13"/>`;
      else if (healed) rings += `<circle cx="${c[0]}" cy="${c[1]}" r="${r + 10}" fill="none" stroke="var(--danger)" stroke-width="13" stroke-dasharray="26 18" opacity=".9"/>`;
    });
    const vb = `${v.x0} 0 ${v.w} 420`;
    return `<div class="pic" style="width:${w}px;height:${h}px">${headImgHtml(ASSET(key, 'card'), w, h)}<svg class="light" viewBox="${vb}" width="${w}" height="${h}" style="position:absolute;inset:0"><defs>${defs}</defs><g style="mix-blend-mode:screen">${circles}</g></svg><svg class="ringsvg" viewBox="${vb}" width="${w}" height="${h}" style="position:absolute;inset:0">${rings}</svg></div>`;
  }
  function faceKey(turn) { return { opus: 'opus3', sonnet: 'sonnet3', fable: 'fable4' }[turn.family] || 'sonnet3'; }
  function cardHtml(turn, o) {
    prep(turn);
    o = o || {};
    const narrow = !!o.narrow;
    const density = narrow ? 'comfortable' : (o.density || 'comfortable'), compact = density === 'compact';
    const state = o.state || (turn.unrecovered.length ? 'failed' : 'settled');
    const chips = ZORDER.filter(z => turn.count[z]).map(z => `<span class="zc f-${z}${turn.count[z] ? ' lit' : ''}">${shape(z, compact ? 12 : 14)}<span>${ZN[z]}</span><b>${turn.count[z]}</b></span>`).join('');
    const fc = failClause(turn, true);
    const tally = turn.tally[0] || turn.tally[1] ? `<span class="tally"><span class="a">+${turn.tally[0]}</span> <span class="d">${MINUS}${turn.tally[1]}</span></span>` : '';
    const pic = narrow ? cardPicture(turn, o.theme, 'compact') : cardPicture(turn, o.theme, density);
    const stateWord = { wait: 'Waiting for you', stopped: 'Stopped' }[state];
    const failHtml = stateWord ? `<span class="fail${state === 'stopped' ? '" style="color:var(--ink2)' : ''}">${stateWord}</span>` : (fc ? `<span class="fail${turn.unrecovered.length ? ' bad' : ''}">${fc}</span>` : '');
    const body = narrow
      ? `<span class="txt"><span class="hl"><span class="num">${turn.tools}</span><span class="unit">tools</span><span class="dur">${turn.dur}</span></span><span class="sub">${tally}${failHtml}</span><span class="btns2"><span class="sbtn">\u25b6 Replay</span><span class="sbtn">Rows</span></span></span>`
      : `<span class="txt"><span class="hl"><span class="num">${turn.tools}</span><span class="unit">tools</span><span class="dur">${turn.dur}</span>${tally}${failHtml}</span><span class="zs">${chips}</span><span class="dg">${esc(digestLine(turn))}</span></span><span class="btns"><span class="sbtn">\u25b6 Replay</span><span class="sbtn">Rows</span></span>`;
    return `<button class="card ${density}${narrow ? ' narrow' : ''} ${state}${o.hover ? ' hover' : ''}" type="button" data-turn="${turn.id}" style="height:${compact ? 84 : 112}px" aria-label="${turn.tools} tools, ${turn.dur}. Open the brain.">${pic}${body}</button>`;
  }

  return { OPT, VIEW, picSize, headImgHtml, zoneChipsHtml, stripHtml, esc, clamp, prep, sentence, digestLine, failClause, relations, stepReadout, digestReadout, zoneReadout, nowReadout, readoutHtml, metrics, cardHtml, cardPicture, faceKey, dirfile, pathHtml, changedFiles, timelineHtml, zoneBarsHtml, zoneRows, MINUS, shape };
})();
