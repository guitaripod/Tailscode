// Fifth pass artboards: U the entity's window, U2 verdicts, U3 live, U4 results, U5 plain words, U6 narrow, U7 phone and Mac.
function with5(fn) {
  return with4(() => { const old = OPT.v5; OPT.v5 = true; try { return fn(); } finally { OPT.v5 = old; if (!old) delete OPT.v5; } });
}
function winOf(host, theme, W, turn, o, title, noPrompt) {
  const w = win(theme, W + 56, title || 'Tailscode — conversation');
  host.appendChild(w);
  const col = w.querySelector('.col'); col.style.width = W + 'px';
  if (!noPrompt) col.insertAdjacentHTML('beforeend', promptHtml(turn));
  const h = el('<div class="open"></div>'); col.appendChild(h);
  const ctl = with5(() => B4.mount(h, turn, Object.assign({ W, theme }, o)));
  return { w, ctl, col };
}
const failIdx = t => t.steps.findIndex(s => s.status === 'fail');
const NEWSUP5 = '';

function artU() {
  artboard('U', 'The entity\u2019s window \u00b7 a turn that fixed an error on the way \u00b7 1280 px',
    'Three views of one account. First: header (who, effort, the verdict in words), Asked, the agent\u2019s Plan as a checklist (open here; a finished plan folds to one line), the story begins. Second: the cursor on the build that failed and was fixed: the work line says \u201cfixed an error at step 8\u201d in amber, the card says FIXED ON RETRY and \u201cIt failed here and passed at step 12\u201d, with the passing step as a chip. Third: the Result and the answer.',
    host => {
      const col = el('<div style="display:flex;flex-direction:column;gap:28px"></div>'); host.appendChild(col);
      const t = TURNS.u; RO.prep(t);
      const fail = failIdx(t);
      winOf(col, 'rose', 1280, t, { state: { cursor: -1 }, listRows: 11, accScroll: 0, planOpen: true }, 'Tailscode \u2014 the account', true);
      winOf(col, 'rose', 1280, t, { state: { cursor: fail }, listRows: 11 }, 'Tailscode \u2014 the cursor on the fixed build', true);
      winOf(col, 'rose', 1280, t, { state: { cursor: -1 }, listRows: 11, accScroll: 1e6 }, 'Tailscode \u2014 the account, scrolled to its end', true);
    }, { gap: 0 });
}

function verdictCases() {
  const base = TURNS.u;
  const clean = variantTurn(base, t => { t.steps.forEach(s => { if (s.status === 'fail') s.status = 'ok'; }); });
  const stuck = variantTurn(TURNS.ulive, t => { const r = t.steps.find(s => s.status === 'run'); r.status = 'stall'; t.silentFor = '40 s'; });
  const stopped = variantTurn(base, t => { t.outcome = 'stopped'; t.steps = t.steps.slice(0, 13); t.steps[12].status = 'stopped'; delete t.answer; t.dur = '2m 41s'; });
  const silent = variantTurn(base, t => { t.outcome = 'answerless'; delete t.answer; });
  const failed = variantTurn(base, t => { const k = t.steps.findIndex((s, i) => s.key === 'swift build' && s.status === 'ok'); t.steps[k].status = 'fail'; t.steps[k].out = ['TranscriptRows.swift:214:9: error: cannot find ‘proseRows’ in scope', 'error: build had 1 command failures']; t.steps[k].exit = 1; });
  return [
    ['Done', clean, 'settled', 'rose-sonnet3-settled'],
    ['Done after retries', base, 'settled', 'rose-sonnet3-settled'],
    ['Needs you', TURNS.accwait, 'approval', 'rose-sonnet3-approval'],
    ['Working', TURNS.ulive, 'working', 'rose-sonnet3-working'],
    ['Stuck', stuck, 'stalled', 'rose-sonnet3-stalled'],
    ['Stopped', stopped, 'neutral', 'rose-sonnet3-neutral'],
    ['Didn’t answer', silent, 'neutral', 'rose-sonnet3-neutral'],
    ['Failed (a failure nobody fixed)', failed, 'failed', 'rose-sonnet3-failed']
  ];
}
function artU2() {
  artboard('U2', 'Verdicts · every turn verdict (card, header line, the head’s eye) and every step verdict (chip, list mark)',
    'Amber is for a fixed error and always carries the retry arrow and the words; danger is only for a failure nobody fixed and always carries the cross. The card’s ring is dashed amber for fixed, solid danger for unfixed. The head’s eye follows the turn: the family colour when settled (a fixed error does not change it), attention when it needs you or is stuck, danger when failed, neutral when stopped or silent.',
    host => {
      const w = win('rose', 1336, 'Tailscode — verdicts'); host.appendChild(w);
      const col = w.querySelector('.col'); col.style.width = '1280px';
      with5(() => {
        const grid = el('<div style="display:grid;grid-template-columns:150px 640px 1fr;gap:10px 20px;align-items:center"></div>'); col.appendChild(grid);
        verdictCases().forEach(([name, t, st, img]) => {
          RO.prep(t);
          grid.insertAdjacentHTML('beforeend', `<div class="lbl" style="color:var(--ink2)">${name}</div><div>${RO.cardHtml(t, { theme: 'rose', density: 'compact' })}</div><div style="display:flex;align-items:center;gap:16px"><div style="position:relative;width:132px;height:96px;flex:none;border-radius:8px;overflow:hidden;background:var(--bg)">${RO.headImgHtml(ASSET(img, 'stage'), 132, 96)}</div><div class="acchead" style="flex:1;min-width:0">${AC.header5(t)}</div></div>`);
        });
        RO.fitQuotes(col);
        col.insertAdjacentHTML('beforeend', '<div class="lbl" style="color:var(--ink2);margin:28px 0 10px">Step verdicts · chip, list mark, what it means</div>');
        const steps = [
          ['done', 'Completed. Shown only in the detail, never as a list mark.'], ['fixed', 'An error that a later step of the same file or command fixed. Never red.'], ['failed', 'An error nobody fixed: the turn ended or moved on.'], ['trying', 'An error in a turn that is still running, not yet retried.'],
          ['running', 'In flight.'], ['waiting', 'An approval or an answer is pending.'], ['stuck', 'The machine found it silent for too long.'], ['stopped', 'You stopped it.']
        ];
        const tbl = el('<div style="display:grid;grid-template-columns:170px 300px 1fr;gap:6px 20px;align-items:center"></div>'); col.appendChild(tbl);
        steps.forEach(([k, d]) => {
          const t = { id: 'sv', family: 'sonnet', outcome: 'settled', dur: '1m', steps: [{ fam: 'shell', tool: 'Bash', arg: 'swift build -c release', status: k === 'fixed' || k === 'failed' || k === 'trying' ? 'fail' : 'ok', vkey: k, msg: 1, at: '10:00:00', out: ['x'], retriedAt: k === 'fixed' ? 12 : undefined }] };
          RO.prep(t);
          const v = NV.stepVerdict(t, t.steps[0]);
          const row = BR.rowHtml(t, BR.rowsOf(t)[0], { cursor: -1, hover: -1 }, BR.rowsOf(t), 0).replace('class="lr', 'style="width:300px" class="lr');
          tbl.insertAdjacentHTML('beforeend', `<div>${NV.chipHtml(v)}</div><div>${k === 'done' ? '<div class="lr f-shell tool h5" style="height:28px;width:300px;opacity:.7"><span></span><span class="gl">' + Neural.shapeSvg('shell', 18) + '</span><span class="no">6</span><span class="tt">Built the project</span><span class="ar">swift build</span><span></span></div>' : row}</div><div style="font:12.5px/18px var(--sans);color:var(--ink2)">${d}</div>`);
        });
        BR.fitArgs(tbl);
      });
    });
}
function artU3() {
  artboard('U3', 'Live · the Now line, the Plan ticking, the pulse, the story following',
    'While it works the header says what it is doing in words, the Now line under it gives the step’s plain title, its command, the output tail and how long since it last spoke; the Plan is the most watchable part, with the item in progress pulsing; the story follows its newest item. Bottom: after 40 seconds of silence the Now line and the verdict go to the attention tone (“silent for 40 s”) and nothing turns red.',
    host => {
      const col = el('<div style="display:flex;flex-direction:column;gap:28px"></div>'); host.appendChild(col);
      const live = variantTurn(TURNS.ulive, t => { delete t.silentFor; t.planAt = 15; });
      const silent = variantTurn(TURNS.ulive, t => { t.silentFor = '40 s'; t.planAt = 15; });
      silent.steps.find(s => s.status === 'run').out = silent.steps.find(s => s.status === 'run').out.slice(0, 4);
      winOf(col, 'rose', 1280, live, { state: { live: true, following: true }, listRows: 12, headKey: 'rose-sonnet3-working', footer: { scrub: .97 } }, 'Tailscode — working', true);
      winOf(col, 'rose', 1280, silent, { state: { live: true, following: true }, planCompact: true, listRows: 12, headKey: 'rose-sonnet3-stalled', footer: { scrub: .97 } }, 'Tailscode — quiet for 40 s', true);
    }, { gap: 0 });
}
function artU4() {
  artboard('U4', 'The Result block · clean, fixed errors, one unfixed failure, no files changed, only reads',
    'Nothing is guessed: a check is a command that is recognisably a build or a test, and its mark is the tool’s own status; files come from edit and write steps; an unfixed failure names its step and its first error line; a turn that changed nothing says so.',
    host => {
      const base = TURNS.u;
      const cases = [
        ['Clean', variantTurn(base, t => { t.steps = t.steps.filter(s => s.status !== 'fail'); t.steps.forEach(s => { delete s.recovered; }); })],
        ['Fixed errors', base],
        ['One unfixed failure', variantTurn(base, t => { const k = t.steps.findIndex((s, i) => s.key === 'swift build' && s.status === 'ok'); t.steps[k].status = 'fail'; t.steps[k].out = ['TranscriptRows.swift:214:9: error: cannot find ‘proseRows’ in scope']; })],
        ['No files changed', variantTurn(base, t => { t.steps = t.steps.filter(s => s.fam !== 'act'); })],
        ['Only reads', variantTurn(base, t => { t.steps = t.steps.filter(s => s.fam === 'sense' || s.fam === 'think' || s.fam === 'say'); t.answer = ['The strip is decided in QuotaGlance.tightestPerProvider.']; })]
      ];
      const w = win('rose', 1700, 'Tailscode — Result block'); host.appendChild(w);
      const col = w.querySelector('.col'); col.style.width = '1644px';
      const grid = el('<div style="display:grid;grid-template-columns:repeat(3,520px);gap:24px 32px;align-items:start"></div>'); col.appendChild(grid);
      with5(() => cases.forEach(([n, t]) => { RO.prep(t); grid.insertAdjacentHTML('beforeend', `<div><div class="lbl" style="color:var(--ink2);margin-bottom:6px">${n}</div>${AC.result5(t)}</div>`); BR.fitArgs(grid); }));
    });
}
function artU5() {
  artboard('U5', 'Plain words · the step list and the work lines, with the raw command one glance away',
    'Titles are sentences built from the kind, the name and the arguments, and nothing else: Read film.sh, Searched for compaction, Built the project, Ran the build again, Checked git status, Looked at the diff, Committed, Pushed, Installed, Searched the files, Looked at files, Fetched a page, Ran ffmpeg, Ran parity.sh, Asked an agent, Used the frames-cli skill. The command or path stays in the mono role beside it. A work line says the same in clauses.',
    host => {
      const t = TURNS.titles; RO.prep(t);
      const w = win('rose', 1336, 'Tailscode — titles'); host.appendChild(w);
      const col = w.querySelector('.col'); col.style.width = '1280px';
      with5(() => {
        const grid = el('<div style="display:grid;grid-template-columns:600px 640px;gap:32px;align-items:start"></div>'); col.appendChild(grid);
        const left = el('<div><div class="lbl" style="color:var(--ink2);margin-bottom:6px">The step list</div><div class="lbody" style="width:600px"></div></div>'); grid.appendChild(left);
        const lb = BR.listBlock(t, { cursor: 4, hover: -1, zones: null, failed: false, query: '', following: true }, { rowsH: 21 * 28, hint: false });
        left.querySelector('.lbody').innerHTML = lb.html.replace(/<div class="lh">.*?<\/div>(?=<div class="lrows)/s, '');
        BR.fitArgs(left);
        const right = el('<div><div class="lbl" style="color:var(--ink2);margin-bottom:6px">Work lines</div><div class="story5" style="gap:12px"></div></div>'); grid.appendChild(right);
        const st = { cursor: -1, hover: -1 };
        [[0, 1, 2, 3, 4], [5, 6, 7, 8, 9], [10, 11, 12, 13, 14], [15, 16, 17, 18, 19, 20]].forEach(ids => right.querySelector('.story5').insertAdjacentHTML('beforeend', AC.work5(t, { kind: 'work', ids }, st, { unfold: new Set(), showAll: new Set() })));
      });
    });
}
function artU6() {
  artboard('U6', 'Narrow · the entity’s window as the accordion at 520 and 380 px',
    'Header, Asked, Plan, the story and the Result stack in one column; the cursor row opens its card in place. The head stays small on top.',
    host => {
      const t = TURNS.u; RO.prep(t);
      [520, 380].forEach(W => {
        const w = win('rose', W + 40, W + ' px'); host.appendChild(w);
        const col = w.querySelector('.col'); col.style.width = W + 'px'; col.style.padding = '16px 0';
        const h = el('<div class="open"></div>'); col.appendChild(h);
        with5(() => B4.mount(h, t, { W, theme: 'rose', state: { cursor: failIdx(t) }, headKey: 'rose-sonnet3-hover-shell', storyMax: W, accScroll: 0 }));
      });
    }, { gap: 24 });
}
function artU7() {
  artboard('U7', 'iPhone and Mac · how it is ported · system look',
    'iPhone 390 and 430: the card, then the account as an inline accordion in the transcript (touch rows 32 px, chips 36, buttons 44 targets). Inline wins over a bottom sheet: the person stays in the conversation, one row opens at a time, the same rows are the same on an iPad column and a split pane; the sheet (right) is shown as the alternative and costs a modal for something that is read in passing. Mac: the sidebar and the floating composer and status capsule are glass; the head, the list and the account are content on the opaque canvas (the transcript’s own), as TailscodeMac/AGENTS.md requires, in the system light and dark looks.',
    host => {
      const t = TURNS.u; RO.prep(t);
      const phone = (theme, W, sheet) => {
        const f = el(`<div class="phone" data-theme="${theme}" data-light="${PAL[theme].dark === '0' ? 1 : 0}" style="width:${W + 28}px;border:1px solid var(--rule2);border-radius:44px;padding:14px;background:var(--bg);position:relative;overflow:hidden"><div style="display:flex;justify-content:space-between;padding:6px 18px 10px;font:600 13px/16px var(--sans);color:var(--ink)"><span>9:41</span><span>●●●</span></div><div class="pc" style="width:${W}px;position:relative"></div></div>`);
        const pc = f.querySelector('.pc');
        pc.insertAdjacentHTML('beforeend', `<div class="prompt" style="margin:0 0 12px;font-size:14px">${RO.esc(t.prompt)}</div>`);
        with5(() => {
          pc.insertAdjacentHTML('beforeend', RO.cardHtml(t, { theme, narrow: true }));
          const h = el('<div class="open" style="margin-top:14px"></div>'); pc.appendChild(h);
          B4.mount(h, t, { W, theme, state: { cursor: sheet ? failIdx(t) : failIdx(t) }, headKey: theme + '-sonnet3-settled', storyMax: W, accScroll: 0, noFooter: true });
        });
        return f;
      };
      const g = el('<div style="display:flex;gap:28px;align-items:flex-start"></div>'); host.appendChild(g);
      g.appendChild(phone('macdark', 390)); g.appendChild(phone('maclight', 430));
      const mac = (theme) => {
        const light = PAL[theme].dark === '0';
        const w = el(`<div class="macwin" data-theme="${theme}" data-light="${light ? 1 : 0}" style="width:1180px;border:1px solid var(--rule2);border-radius:14px;overflow:hidden;position:relative;background:var(--bg);font-family:-apple-system,system-ui,'Noto Sans',sans-serif"></div>`);
        w.innerHTML = `<div style="position:absolute;left:0;top:0;bottom:0;width:200px;background:linear-gradient(180deg,${light ? 'rgba(235,235,240,.92),rgba(225,225,232,.88)' : 'rgba(44,44,48,.9),rgba(34,34,38,.9)'});border-right:1px solid var(--rule);backdrop-filter:blur(30px);padding:44px 12px;font:13px/20px var(--sans);color:var(--ink2)"><div style="position:absolute;left:14px;top:14px;display:flex;gap:8px"><i style="width:12px;height:12px;border-radius:50%;background:#ff5f57"></i><i style="width:12px;height:12px;border-radius:50%;background:#febc2e"></i><i style="width:12px;height:12px;border-radius:50%;background:#28c840"></i></div><div class="lbl" style="margin-bottom:8px">Chats</div><div style="padding:6px 10px;border-radius:8px;background:color-mix(in srgb,var(--accent) 16%,transparent);color:var(--ink)">Fix the Linux build</div><div style="padding:6px 10px">Make a product demo</div><div style="padding:6px 10px">Install the Mac build</div></div><div class="mc" style="margin-left:200px;padding:44px 24px 96px;position:relative"></div><div style="position:absolute;left:224px;right:24px;bottom:16px;height:48px;border-radius:24px;background:${light ? 'rgba(250,250,252,.72)' : 'rgba(60,60,66,.62)'};backdrop-filter:blur(30px);border:1px solid var(--rule);display:flex;align-items:center;padding:0 20px;font:14px/20px var(--sans);color:var(--ink2);box-shadow:0 8px 30px rgba(0,0,0,.18)">Message the agent<span style="margin-left:auto;color:var(--accent);font-weight:600">↑</span></div><div style="position:absolute;left:50%;top:10px;transform:translateX(-50%);height:26px;padding:0 14px;border-radius:13px;background:${light ? 'rgba(250,250,252,.7)' : 'rgba(60,60,66,.6)'};backdrop-filter:blur(30px);border:1px solid var(--rule);font:12px/26px var(--sans);color:var(--ink)">Fix the Linux build · done</div>`;
        const mc = w.querySelector('.mc');
        with5(() => B4.mount(el('<div></div>', mc) || mc, t, { W: 932, theme, state: { cursor: failIdx(t) }, headKey: theme + '-sonnet3-settled', listRows: 9, accScroll: 0, noFooter: true }));
        return w;
      };
      const g2 = el('<div style="display:flex;flex-direction:column;gap:28px;margin-left:28px"></div>'); host.appendChild(g2);
      const mw1 = mac('macdark'); g2.appendChild(mw1);
      const mw2 = mac('maclight'); g2.appendChild(mw2);
      [mw1, mw2].forEach(w => { const mc = w.querySelector('.mc'); const h = el('<div class="open"></div>'); mc.innerHTML = ''; mc.appendChild(h); with5(() => B4.mount(h, t, { W: 932, theme: w.dataset.theme, state: { cursor: failIdx(t) }, headKey: w.dataset.theme + '-sonnet3-settled', listRows: 9, accScroll: 0, noFooter: true })); });
    }, { gap: 0 });
}
