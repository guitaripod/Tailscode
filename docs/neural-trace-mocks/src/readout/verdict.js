// Fifth pass: verdicts (what a step and a turn are in the reader's terms) and plain words for what a step did.
const NV = (function () {
  const esc = s => String(s).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
  const base = p => (p || '').split('/').pop();
  const GL = {
    check: '<svg class="vg" width="14" height="14" viewBox="0 0 14 14"><path d="M3 7.4l2.6 2.6L11 4.4" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/></svg>',
    retry: '<svg class="vg" width="14" height="14" viewBox="0 0 14 14"><path d="M11.2 5.2A4.6 4.6 0 1 0 11.6 8" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round"/><path d="M11.6 2.4v3h-3" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"/></svg>',
    cross: '<svg class="vg" width="14" height="14" viewBox="0 0 14 14"><path d="M3.5 3.5l7 7M10.5 3.5l-7 7" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round"/></svg>',
    bang: '<svg class="vg" width="14" height="14" viewBox="0 0 14 14"><path d="M7 2.2l5.2 9H1.8z" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linejoin="round"/><path d="M7 5.8v2.6M7 10v.1" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/></svg>',
    pulse: '<i class="pulse"></i>',
    pause: '<svg class="vg" width="14" height="14" viewBox="0 0 14 14"><path d="M4.6 3.2v7.6M9.4 3.2v7.6" stroke="currentColor" stroke-width="2" stroke-linecap="round"/></svg>',
    stuck: '<svg class="vg" width="14" height="14" viewBox="0 0 14 14"><circle cx="7" cy="7" r="4.6" fill="none" stroke="currentColor" stroke-width="1.6" stroke-dasharray="2 2.2"/><path d="M7 4.6V7l1.8 1.2" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/></svg>',
    stop: '<svg class="vg" width="14" height="14" viewBox="0 0 14 14"><rect x="3.6" y="3.6" width="6.8" height="6.8" rx="1.4" fill="none" stroke="currentColor" stroke-width="1.6"/></svg>'
  };
  const STEP = {
    done: { key: 'done', words: 'Done', tone: 'quiet', gl: 'check' },
    fixed: { key: 'fixed', words: 'Fixed on retry', tone: 'attn', gl: 'retry' },
    failed: { key: 'failed', words: 'Failed', tone: 'danger', gl: 'cross' },
    trying: { key: 'trying', words: 'Hit an error', tone: 'attn', gl: 'bang' },
    running: { key: 'running', words: 'Running', tone: 'live', gl: 'pulse' },
    waiting: { key: 'waiting', words: 'Waiting for you', tone: 'attn', gl: 'pause' },
    stuck: { key: 'stuck', words: 'Stuck', tone: 'attn', gl: 'stuck' },
    stopped: { key: 'stopped', words: 'Stopped', tone: 'quiet', gl: 'stop' }
  };
  function fixedBy(turn, s) {
    if (!s.key) return -1;
    return turn.steps.findIndex((t, j) => j > s.i && t.key === s.key && t.status === 'ok');
  }
  function stepVerdict(turn, s) {
    if (s.vkey) return STEP[s.vkey];
    if (s.status === 'run') return STEP.running;
    if (s.status === 'wait') return STEP.waiting;
    if (s.status === 'stall') return STEP.stuck;
    if (s.status === 'stopped') return STEP.stopped;
    if (s.status === 'fail') {
      if (s.retriedAt || fixedBy(turn, s) >= 0) return STEP.fixed;
      if (turn.outcome === 'running') {
        const later = turn.steps.some((t, j) => j > s.i && t.fam !== 'say' && t.fam !== 'think');
        if (!later) return STEP.trying;
      }
      return STEP.failed;
    }
    return STEP.done;
  }
  function chipHtml(v) { return `<span class="vchip ${v.tone}">${GL[v.gl]}<span>${v.words}</span></span>`; }
  function mark(v, s) {
    const to = v.key === 'fixed' ? (s.retriedAt || (s.i != null ? 0 : 0)) : 0;
    return v;
  }

  const TV = {
    done: { key: 'done', words: 'Done', tone: 'quiet', edge: 'accent', gl: 'check' },
    retry: { key: 'retry', words: 'Done', tone: 'quiet', edge: 'accent', gl: 'check' },
    needs: { key: 'needs', words: 'Needs you', tone: 'attn', edge: 'warn', gl: 'pause' },
    working: { key: 'working', words: 'Working', tone: 'live', edge: 'accent', gl: 'pulse' },
    stuck: { key: 'stuck', words: 'Stuck', tone: 'attn', edge: 'warn', gl: 'stuck' },
    stopped: { key: 'stopped', words: 'Stopped', tone: 'quiet', edge: 'quiet', gl: 'stop' },
    silent: { key: 'silent', words: 'Didn’t answer', tone: 'quiet', edge: 'quiet', gl: 'stop' },
    failed: { key: 'failed', words: 'Failed', tone: 'danger', edge: 'danger', gl: 'cross' }
  };
  const plural = (n, a, b) => n === 1 ? a : b.replace('#', n);
  function turnVerdict(turn) {
    const st = turn.steps, vs = st.map(s => stepVerdict(turn, s));
    const fixed = vs.filter(v => v.key === 'fixed').length, failed = vs.filter(v => v.key === 'failed').length;
    const out = { fixed, failed, steps: vs };
    if (turn.outcome === 'running') {
      if (vs.some(v => v.key === 'waiting')) return Object.assign(out, TV.needs, { clause: 'Needs you', head: 'Waiting for you' });
      if (vs.some(v => v.key === 'stuck')) return Object.assign(out, TV.stuck, { clause: 'Stuck', head: 'Stuck for ' + (turn.silentFor || '40 s') });
      const live = st.find(s => s.status === 'run');
      return Object.assign(out, TV.working, { clause: 'Working', head: 'Working on: ' + (live ? NH.title(turn, live) : 'its next step') });
    }
    if (turn.outcome === 'stopped') return Object.assign(out, TV.stopped, { clause: 'Stopped', head: 'Stopped by you' });
    if (turn.outcome === 'answerless') return Object.assign(out, TV.silent, { clause: 'Didn’t answer', head: 'Finished without an answer' });
    if (failed) return Object.assign(out, TV.failed, { clause: plural(failed, '1 step failed', '# steps failed'), head: 'Failed' + (fixed ? ' · ' + plural(fixed, '1 error fixed on the way', '# errors fixed on the way') : '') });
    if (fixed) return Object.assign(out, TV.retry, { clause: 'Done, ' + plural(fixed, 'fixed 1 error', 'fixed # errors'), head: 'Finished in ' + turn.dur + ' · ' + plural(fixed, 'fixed 1 error on the way', 'fixed # errors on the way') });
    return Object.assign(out, TV.done, { clause: 'Done', head: 'Finished in ' + turn.dur });
  }

  /* ───── plain words ───── */
  const NHm = (function () {
    function prog(cmd) {
      let c = cmd.trim();
      c = c.replace(/^(cd [^&;]+(&&|;)\s*)/, '').replace(/^(\w+=\S+\s+)+/, '');
      const first = c.split(/\s+/)[0] || '';
      return { c, first, name: first.split('/').pop() };
    }
    function bash(turn, s) {
      const { c, first, name } = prog(s.arg || '');
      let t = null, cat = 'other';
      if (/^(swift build|xcodebuild|cargo build|make\b|npm run build|gradle|cmake --build)/.test(c)) { t = 'Built the project'; cat = 'build'; }
      else if (/^(swift test|pytest|cargo test|npm test|npm run test|jest|go test|xcodebuild test)/.test(c)) { t = 'Ran the tests'; cat = 'test'; }
      else if (/^git\s+status/.test(c)) { t = 'Checked git status'; cat = 'git'; }
      else if (/^git\s+diff/.test(c)) { t = 'Looked at the diff'; cat = 'git'; }
      else if (/^git\s+commit/.test(c)) { t = 'Committed'; cat = 'git'; }
      else if (/^git\s+push/.test(c)) { t = 'Pushed'; cat = 'git'; }
      else if (/^git\s+log/.test(c)) { t = 'Read the git log'; cat = 'git'; }
      else if (/install/.test(first) || /^(brew|npm|pip3?|cargo) install/.test(c)) { t = 'Installed'; cat = 'install'; }
      else if (/^(rg|grep|find|fd)\b/.test(c)) { t = 'Searched the files'; cat = 'search'; }
      else if (/^(ls|cat|sed -n|head|tail|wc|stat|file)\b/.test(c)) { t = 'Looked at files'; cat = 'look'; }
      else if (/^(curl|wget)\b/.test(c)) { t = 'Fetched a page'; cat = 'net'; }
      else if (/^(ffmpeg|ffprobe)\b/.test(c)) { t = 'Ran ' + name; cat = 'media'; }
      else { t = 'Ran ' + (name || 'a command'); }
      return { t, cat };
    }
    function title(turn, s, plain) {
      if (s.fam === 'say') return 'Said';
      if (s.fam === 'think') return 'Thought';
      let t;
      if (s.tool === 'Bash') {
        const b = bash(turn, s); t = b.t;
        if (s.key && turn.steps.some((x, j) => j < s.i && x.key === s.key && x.status === 'fail')) {
          if (b.cat === 'build') t = 'Ran the build again'; else if (b.cat === 'test') t = 'Ran the tests again'; else t += ' again';
        }
        s.cat = b.cat;
      } else if (s.tool === 'Read') t = 'Read ' + base(s.arg);
      else if (s.tool === 'Grep') t = 'Searched for ' + (s.arg || '').split(/ {2,}/)[0].replace(/^["']|["']$/g, '');
      else if (s.tool === 'Edit') t = 'Edited ' + base(s.arg) + (s.diff ? ` (+${s.diff[0]} −${s.diff[1]})` : '');
      else if (s.tool === 'Write') t = 'Wrote ' + base(s.arg);
      else if (s.tool === 'Task') t = 'Asked an agent: ' + (s.arg || '').slice(0, 44) + ((s.arg || '').length > 44 ? '…' : '');
      else if (s.tool === 'Skill') t = 'Used the ' + s.arg + ' skill';
      else if (s.tool === 'TodoWrite') t = 'Updated its plan';
      else t = s.tool;
      return t;
    }
    function category(turn, s) { title(turn, s); return s.cat || (s.tool === 'Edit' ? 'edit' : s.tool === 'Read' ? 'read' : s.tool === 'Grep' ? 'search' : 'other'); }
    return { title, category, bash };
  })();
  const NH = NHm;

  /* ───── plan and result ───── */
  function plan(turn, atStep) {
    if (!turn.plan) return null;
    const done = turn.plan.filter(p => atStep == null ? p.st === 'done' : (p.at != null && p.at <= atStep)).length;
    const items = turn.plan.map((p, i) => {
      const isDone = atStep == null ? p.st === 'done' : (p.at != null && p.at <= atStep);
      const prevDone = i === 0 || (atStep == null ? turn.plan[i - 1].st === 'done' : (turn.plan[i - 1].at != null && turn.plan[i - 1].at <= atStep));
      const st = isDone ? 'done' : (atStep != null || p.st === 'doing') && prevDone ? 'doing' : (p.st === 'doing' ? 'doing' : 'todo');
      return { c: p.c, st };
    });
    return { items, done, total: turn.plan.length };
  }
  function result(turn) {
    RO.prep(turn);
    const files = RO.changedFiles(turn);
    const checks = [];
    const seen = new Map();
    turn.steps.forEach(s => {
      if (s.tool !== 'Bash') return;
      const cat = NH.category(turn, s);
      if (cat !== 'build' && cat !== 'test') return;
      const k = cat + '|' + (s.key || s.arg);
      const e = seen.get(k) || { cat, arg: s.arg, ids: [], fails: 0, last: null };
      e.ids.push(s.i); if (s.status === 'fail') e.fails++; e.last = s; seen.set(k, e);
    });
    seen.forEach(e => checks.push(e));
    const vs = turn.steps.map(s => stepVerdict(turn, s));
    const unfixed = turn.steps.filter((s, i) => vs[i].key === 'failed');
    const reads = turn.steps.filter(s => s.fam === 'sense').length;
    return { files, checks, unfixed, reads, tally: turn.tally };
  }
  return { stepVerdict, chipHtml, turnVerdict, GL, STEP, TV, NH, plan, result, fixedBy, esc };
})();
const NH = NV.NH;
