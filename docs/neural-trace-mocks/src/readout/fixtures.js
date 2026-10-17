// Fixtures for the readout mocks: three turns with the words a readout needs (why, output, diffs).
// Shape per step: fam, tool, status ok|fail|run|wait, msg, at, arg, key/keyKind (ties), why, out, exit, diff [+,-], lines (mini diff), recovered, retriedAt.

const SH = (arg, o) => Object.assign({ fam: 'shell', tool: 'Bash', status: 'ok', arg }, o);

const T_CALM = {
  id: 'calm', family: 'opus', effort: 3, dur: '38s', outcome: 'settled',
  prompt: 'Where does the quota strip decide which window is tightest?',
  answer: ['It is `QuotaGlance.tightestPerProvider` in Core: one line per provider, its tightest window, in the board’s own order, with walls first. Nothing re-ranks by pressure, so the rows do not move under the reader on a poll.'],
  steps: [
    { fam: 'think', tool: 'Thinking', status: 'ok', msg: 1, at: '10:41:02', text: 'The strip lives in Core, not in a client. Look for the type that picks a window per provider, then check whether anything sorts by pressure.' },
    { fam: 'sense', tool: 'Grep', status: 'ok', msg: 2, at: '10:41:06', arg: 'tightestPerProvider  TailscodeCore/Sources', why: 'Start from the name the board document gives the rule.', out: ['TailscodeCore/Sources/TailscodeCore/QuotaGlance.swift:88', 'TailscodeCore/Sources/TailscodeCore/QuotaBoard.swift:141', 'TailscodeCore/Tests/TailscodeCoreTests/QuotaGlanceTests.swift:57'] },
    { fam: 'sense', tool: 'Read', status: 'ok', msg: 2, at: '10:41:06', arg: 'TailscodeCore/Sources/TailscodeCore/QuotaGlance.swift', key: 'QuotaGlance.swift', out: ['212 lines', 'static func tightestPerProvider(_ holdings: [QuotaHolding]) -> [QuotaGlance.Line]'] },
    { fam: 'sense', tool: 'Read', status: 'ok', msg: 3, at: '10:41:21', arg: 'TailscodeCore/Sources/TailscodeCore/QuotaBoard.swift', key: 'QuotaBoard.swift', why: 'The glance takes its order from the board; confirm it is the person’s own.', out: ['296 lines', 'let order = preferences.order  // the person’s own, never a sort by pressure'] },
    { fam: 'sense', tool: 'Grep', status: 'ok', msg: 4, at: '10:41:30', arg: 'sorted(by:.*pressure  TailscodeCore/Sources', why: 'Rule out a hidden re-rank before answering.', out: ['(no matches)'] },
    { fam: 'sense', tool: 'Read', status: 'ok', msg: 5, at: '10:41:36', arg: 'TailscodeCore/Tests/TailscodeCoreTests/QuotaGlanceTests.swift', key: 'QuotaGlanceTests.swift', out: ['143 lines', 'func testRowsHoldTheirOrderWhenPressureChanges()'] }
  ]
};

const T_FIX = {
  id: 'fix', family: 'sonnet', effort: 3, dur: '6m 29s', outcome: 'settled',
  prompt: 'Fix the Linux build: it stops in TranscriptRows.',
  answer: ['Fixed. The build stopped on two switches that did not answer the new Compaction and Note cases. Both do now, the Mac manifest answers the same capability, and the parity check reports no gaps.', 'Tailscode 1.79 is installed on this machine (pid 41872).'],
  provenance: ['TranscriptRows.swift', 'Parity.swift', 'parity.sh'],
  steps: [
    { fam: 'think', tool: 'Thinking', status: 'ok', msg: 1, at: '14:02:11', text: 'The Linux build stops in TranscriptRows: a Compaction case reached the switch and nothing answers it. Look at every site that switches over the part kind before touching anything.' },
    { fam: 'sense', tool: 'Grep', status: 'ok', msg: 2, at: '14:02:19', arg: 'case .compaction  TailscodeLinux/Sources', why: 'Find every place that already names the case before adding another.', out: ['TailscodeLinux/Sources/TailscodeLinux/Chat/TranscriptRows.swift:212', 'TailscodeLinux/Sources/TailscodeLinux/Chat/RowFactory.swift:88'] },
    { fam: 'sense', tool: 'Read', status: 'ok', msg: 2, at: '14:02:19', arg: 'TailscodeLinux/Sources/TailscodeLinux/Chat/TranscriptRows.swift', key: 'TranscriptRows.swift', out: ['204 lines read', 'switch part.kind { case .text, .reasoning, .tool, .file, .compaction …'] },
    { fam: 'sense', tool: 'Read', status: 'ok', msg: 2, at: '14:02:19', arg: 'TailscodeLinux/Sources/TailscodeLinux/Parity.swift', key: 'Linux Parity.swift', out: ['388 lines read', 'case .compactActivity: return .implemented("CompactionCell")'] },
    { fam: 'act', tool: 'Edit', status: 'ok', msg: 3, at: '14:02:40', arg: 'TailscodeLinux/Sources/TailscodeLinux/Chat/TranscriptRows.swift', key: 'TranscriptRows.swift', diff: [6, 1], why: 'Answer the Compaction case where the row factory switches, as a divider rather than prose.',
      lines: [
        { k: 'ctx', o: 208, n: 208, t: '    func rows(for part: MessagePart) -> [Row] {' },
        { k: 'ctx', o: 209, n: 209, t: '        switch part.kind {' },
        { k: 'del', o: 210, t: '        case .text, .reasoning, .tool, .file:' },
        { k: 'add', n: 210, t: '        case .text, .reasoning:' },
        { k: 'add', n: 211, t: '            return proseRows(part)' },
        { k: 'add', n: 212, t: '        case .tool, .file:' },
        { k: 'add', n: 213, t: '            return toolRows(part)' },
        { k: 'add', n: 214, t: '        case .compaction:' },
        { k: 'add', n: 215, t: '            return [CompactionRow(part)]' },
        { k: 'ctx', o: 211, n: 216, t: '        }' }
      ], out: ['The file TranscriptRows.swift has been updated.'] },
    SH('swift build -c release 2>&1 | tail -20', {
      status: 'fail', recovered: true, retriedAt: 9, msg: 4, at: '14:02:52', key: 'swift build', keyKind: 'cmd', exit: 1,
      why: 'Compaction is answered. Build the release to see whether the compiler wants anything else before I touch the Mac client.',
      out: [
        '[1/3] Compiling TailscodeLinux TranscriptRows.swift',
        'TailscodeLinux/Chat/TranscriptRows.swift:212:9: error: switch must be exhaustive',
        '210 |         switch part.kind {',
        '211 |         case .text, .reasoning:',
        '212 |             return proseRows(part)',
        "    |         `- note: add missing case: '.note(_)'",
        '213 |         case .tool, .file:',
        '[2/3] Compiling TailscodeLinux RowFactory.swift',
        'error: fatalError',
        'error: build had 1 command failures',
        'Build failed after 6.8s'
      ] }),
    { fam: 'think', tool: 'Thinking', status: 'ok', msg: 5, at: '14:03:30', text: 'The build names .note, which my first edit did not cover. The Mac client answers the same capability in its own manifest, so check it while the cause is fresh.' },
    { fam: 'act', tool: 'Edit', status: 'ok', msg: 6, at: '14:03:48', arg: 'TailscodeLinux/Sources/TailscodeLinux/Chat/TranscriptRows.swift', key: 'TranscriptRows.swift', diff: [2, 2], why: 'Notes read like prose with a quieter tone; fold them into the prose arm.',
      lines: [
        { k: 'ctx', o: 209, n: 209, t: '        switch part.kind {' },
        { k: 'del', o: 210, t: '        case .text, .reasoning:' },
        { k: 'del', o: 211, t: '            return proseRows(part)' },
        { k: 'add', n: 210, t: '        case .text, .reasoning, .note:' },
        { k: 'add', n: 211, t: '            return proseRows(part, tone: part.kind == .note ? .quiet : .normal)' },
        { k: 'ctx', o: 212, n: 212, t: '        case .tool, .file:' },
        { k: 'ctx', o: 213, n: 213, t: '            return toolRows(part)' }
      ], out: ['The file TranscriptRows.swift has been updated.'] },
    SH('swift build -c release 2>&1 | tail -20', { msg: 7, at: '14:07:46', key: 'swift build', keyKind: 'cmd', exit: 0, why: 'Both arms answer now. Build again.',
      out: ['[1/3] Compiling TailscodeLinux TranscriptRows.swift', '[2/3] Compiling TailscodeLinux RowFactory.swift', '[3/3] Linking tailscode', 'Build complete! (212.4s)'] }),
    { fam: 'sense', tool: 'Read', status: 'ok', msg: 8, at: '14:07:52', arg: 'TailscodeMac/Sources/TailscodeMac/Parity.swift', key: 'Mac Parity.swift', why: 'The Mac answers the same capability in its own manifest.', out: ['412 lines read', 'case .compactActivity: return .implemented("CompactionCell")'] },
    { fam: 'act', tool: 'Edit', status: 'ok', msg: 9, at: '14:08:03', arg: 'TailscodeMac/Sources/TailscodeMac/Parity.swift', key: 'Mac Parity.swift', diff: [3, 0], why: 'The Mac manifest has no answer for Note yet.',
      lines: [
        { k: 'ctx', o: 301, n: 301, t: '        case .compactActivity:' },
        { k: 'ctx', o: 302, n: 302, t: '            return .implemented("CompactionCell")' },
        { k: 'add', n: 303, t: '        case .noteRows:' },
        { k: 'add', n: 304, t: '            return .implemented("NoteRowView")' },
        { k: 'add', n: 305, t: '' },
        { k: 'ctx', o: 303, n: 306, t: '        case .goalMarks:' }
      ], out: ['The file Parity.swift has been updated.'] },
    SH('scripts/parity.sh --check', { msg: 10, at: '14:08:21', exit: 0, why: 'Parity is the gate for any user-facing capability.',
      out: ['parity: 3 clients · 41 capabilities', 'iOS 38 implemented · 3 partial', 'Linux 36 implemented · 3 partial · 2 gaps', 'Mac 37 implemented · 4 partial', '0 undeclared'] }),
    { fam: 'delegate', tool: 'Task', status: 'ok', msg: 11, at: '14:08:34', arg: 'Review the diff for any switch over MessagePart.Kind that is still not exhaustive', spawn: 'reviewer · 7 tools · expands in place', why: 'A second pair of eyes on the other switches over the same kind.', out: ['No other switch over MessagePart.Kind is affected.', 'Checked 6 sites in TailscodeLinux and 4 in TailscodeMac.'] },
    SH('scripts/install-linuxapp.sh', { msg: 12, at: '14:08:40', exit: 0, why: 'Everything is green; put it on the machine it runs on.', out: ['building release …', 'installed Tailscode 1.79', 'restarted pid 41872'] })
  ]
};

const FLAC = '/mnt/nvme8tb/Music/Pantera-…/203-pantera-walk.flac';
const T_BIG = (function () {
  const off = [0, 0, 9, 21, 28, 36, 41, 52, 70, 78, 85, 96, 101, 112, 331, 340, 349, 357, 366, 372, 380, 391, 440, 449, 458, 497, 505];
  const T = m => { const t = 21 * 3600 + 52 * 60 + 22 + off[m]; return [Math.floor(t / 3600), Math.floor(t % 3600 / 60), t % 60].map(v => String(v).padStart(2, '0')).join(':'); };
  const s = [];
  const add = (m, o) => s.push(Object.assign({ msg: m, at: T(m), status: 'ok' }, o));
  add(1, { fam: 'think', tool: 'Thinking', text: 'He wants a shareable mp4 made with the real apps and mock data over the Pantera track. The film rig already records the Linux app in --demo and cuts the iOS tour, so reuse it instead of building a new one.' });
  add(2, SH('ls ~/Dev/film/tailscode-everywhere', { why: 'See what the film rig already has.', out: ['README.md  cut.sh  broll/  remotion/  sync/'] }));
  add(2, SH('ffprobe -v error -show_entries format=duration -of csv=p=0 ' + FLAC, { key: '203-pantera-walk.flac', out: ['336.12'] }));
  add(3, SH('sed -n 1,60p scripts/film.sh', { key: 'film.sh', out: ['#!/usr/bin/env bash', 'set -euo pipefail', 'ROOT=$(cd "$(dirname "$0")/.." && pwd)'] }));
  add(4, SH('rg -n "demo" scripts/dev-linuxapp.sh scripts/run-mac.sh', { out: ['scripts/run-mac.sh:41:  --demo → scripted conversation', 'scripts/dev-linuxapp.sh:118: start [--release] [--drive SCRIPT]'] }));
  add(5, SH('scripts/dev-linuxapp.sh status', { out: ['running · rss 412 MB · windows 1'] }));
  add(6, { fam: 'say', tool: 'Said', text: 'Building it from the existing film rig: Linux app in --demo on a private 4K display, plus the iOS demo tour, cut to “Walk”.' });
  add(7, SH('ffmpeg -i ' + FLAC + ' -af astats -f null -', { key: '203-pantera-walk.flac', why: 'Measure the track so the cuts can lock to it.', out: ['Overall RMS level dB: −14.2', 'Peak level dB: −0.3'] }));
  add(7, SH('python3 scripts/beats.py ' + FLAC, { key: '203-pantera-walk.flac', out: ['tempo 115.0 (half-time 57.5)', 'first riff onset 8.75 s'] }));
  add(8, SH('python3 scripts/beats.py --grid 8.75 --bars 16', { out: ['16 bars → 33.4 s'] }));
  add(9, SH('scripts/dev-linuxapp.sh start --release --drive demo.drive', { out: ['started pid 38214 on :9'] }));
  add(10, SH('scripts/dev-linuxapp.sh shot out/demo/01.png', { out: ['out/demo/01.png 3840×2160'] }));
  add(11, SH("scripts/dev-linuxapp.sh drive '2000:open=1;4000:splits'", { out: ['ok'] }));
  add(12, { fam: 'say', tool: 'Said', text: 'Song mapped (~115 BPM half-time, riff hits at 8.75 s); building the Linux release while I check the iOS footage.' });
  add(13, SH('scripts/install-linuxapp.sh', { out: ['compiling TailscodeLinux 212 s', 'Installed Tailscode 1.79'] }));
  add(13, { fam: 'sense', tool: 'Read', status: 'ok', arg: 'docs/marketing-2026-10.md', out: ['## Preview video', '60 s, beat-synced'] });
  add(14, { fam: 'delegate', tool: 'Skill', status: 'ok', arg: 'frames-cli', out: ['Launching skill: frames-cli'] });
  add(15, { fam: 'sense', tool: 'Read', status: 'ok', arg: 'scripts/film.sh', key: 'film.sh', out: ['204 lines read'] });
  add(16, SH('frames doctor', { out: ['frames 0.9.2 · bezels ok'] }));
  add(17, SH('ffprobe -v error -show_streams ios-tour/walk.mov', { out: ['codec_name=hevc', 'width=2622', 'height=1206', 'r_frame_rate=60/1'] }));
  add(18, { fam: 'think', tool: 'Thinking', text: 'The iOS tour is 60 fps and the Linux capture is 30. Resample the tour once, then cut both to the riff at 8.75 s.' });
  add(19, { fam: 'sense', tool: 'Read', status: 'ok', arg: 'out/demo/cut-list.json', key: 'cut-list.json', out: ['{ "riff": 8.75, "cuts": 22 }'] });
  add(20, { fam: 'act', tool: 'Edit', status: 'ok', arg: 'out/demo/cut-list.json', key: 'cut-list.json', diff: [4, 1], out: ['The file cut-list.json has been updated.'],
    lines: [{ k: 'ctx', o: 1, n: 1, t: '{' }, { k: 'del', o: 2, t: '  "riff": 0,' }, { k: 'add', n: 2, t: '  "riff": 8.75,' }, { k: 'add', n: 3, t: '  "fps": 30,' }, { k: 'add', n: 4, t: '  "audio": null,' }, { k: 'add', n: 5, t: '  "tour": "ios-30.mp4",' }, { k: 'ctx', o: 3, n: 6, t: '  "cuts": 22' }, { k: 'ctx', o: 4, n: 7, t: '}' }] });
  add(21, SH('ffmpeg -i ios-tour/walk.mov -vf fps=30 -c:v libx264 out/demo/ios-30.mp4', { out: ['frame= 1260 fps=96 q=-1.0 size= 18432kB time=00:00:42.00 bitrate=3595.1kbits/s'] }));
  add(22, SH('ffmpeg -f concat -i out/demo/cut-list.txt -i ' + FLAC + ' -map 1:a -shortest out/demo/tailscode-demo.mp4', {
    status: 'fail', recovered: true, retriedAt: 27, key: 'ffmpeg mux', keyKind: 'cmd', exit: 1,
    out: ['Input #0, concat, from \'out/demo/cut-list.txt\':', '  Stream #0:0: Video: h264 (High), yuv420p, 2160x3840, 30 fps', 'Input #1, flac, from \'' + FLAC + '\':', '  Duration: 00:05:36.12, bitrate: 912 kb/s', "Stream map '1:a' matches no streams.", "To ignore this, add a trailing '?' to the map.", 'Error opening output files: Invalid argument'] }));
  add(23, { fam: 'act', tool: 'Edit', status: 'ok', arg: 'out/demo/cut-list.json', key: 'cut-list.json', diff: [1, 1], out: ['The file cut-list.json has been updated.'],
    lines: [{ k: 'ctx', o: 3, n: 3, t: '  "audio": null,' }, { k: 'del', o: 4, t: '  "audio": null,' }, { k: 'add', n: 4, t: '  "audio": "203-pantera-walk.flac",' }] });
  add(24, SH('ffmpeg -f concat -i out/demo/cut-list.txt -i ' + FLAC + ' -map 1:a -shortest out/demo/tailscode-demo.mp4', { key: 'ffmpeg mux', keyKind: 'cmd', exit: 0, out: ['video:19.4MiB audio:1.4MiB subtitle:0KiB other streams:0KiB', 'muxing overhead: 0.4%'] }));
  add(25, SH('ffprobe -v error -show_entries format=duration out/demo/tailscode-demo.mp4', { out: ['62.04'] }));
  add(26, { fam: 'delegate', tool: 'Task', status: 'ok', arg: 'Watch the cut and confirm the first tap lands on the riff at 8.75 s', spawn: 'reviewer · 5 tools · expands in place', out: ['First tap at 8.74 s. The riff lands on it.'] });
  return s;
})();
(function () {
  const B = T_BIG;
  B[2].why = 'The cut has to be exactly as long as the song, so read its length first.';
  B[3].why = 'Learn how the rig is driven before writing anything new.';
  B[17].why = 'The film script is the one that already knows how to cut.';
  B[21].why = 'The cut list has to name the riff before anything is encoded.';
  B[22].why = 'Put the riff and the clip order in the cut list.';
  B[23].why = 'Resample the tour once so both sources share a frame rate.';
  B[24].why = 'Join the clips and lay the track under them.';
  B[25].why = 'The cut list was missing the audio entry; add it and run the same command again.';
  B[26].why = 'Same command, now with the audio entry in place.';
  B[27].why = 'Confirm the length matches the track before reviewing it.';
  B[28].why = 'A second pair of eyes on the first tap, which is the claim the whole video rests on.';
})();
const BIG_TURN = {
  id: 'big', family: 'fable', effort: 4, dur: '8m 25s', outcome: 'settled',
  prompt: 'Make a product demonstration using mock data but the real apps .mp4 i can share on twitter. use ' + FLAC + ' as the background track.',
  answer: ['Done. The demo is at out/demo/tailscode-demo.mp4: 62 s, 3840×2160 at 30 fps, with Pantera’s “Walk” playing from the first second to the last.', 'The first tap in the iOS tour lands exactly on the riff at 8.75 s, and the Linux app plays through its split-pane tour after it. Everything on screen is mock data in the real apps.'],
  provenance: ['out/demo/tailscode-demo.mp4', 'cut-list.json'],
  steps: T_BIG
};

const T_LIVE = {
  id: 'live', family: 'sonnet', effort: 3, dur: '3m 52s', outcome: 'running',
  prompt: 'Make a product demonstration using mock data but the real apps .mp4 i can share on twitter.',
  steps: [0, 1, 2, 3, 6, 7, 8, 14, 15, 17, 20, 21, 22].map(i => Object.assign({}, T_BIG[i]))
};
T_LIVE.steps.forEach((s, i) => { s.msg = i + 1; });
T_LIVE.steps.push(SH('ffmpeg -i ios-tour/walk.mov -vf fps=30 -c:v libx264 -crf 18 -preset slow out/demo/ios-30.mp4', {
  status: 'run', msg: 14, at: '22:01:37',
  why: 'The iOS tour is 60 fps and the Linux capture is 30. Resample the tour once, then cut both to the riff at 8.75 s.',
  out: [
    "Input #0, mov,mp4,m4a,3gp,3g2,mj2, from 'ios-tour/walk.mov':",
    '  Duration: 00:01:02.04, bitrate: 38211 kb/s',
    '  Stream #0:0: Video: hevc (Main), 2622x1206, 60 fps',
    'Stream mapping: #0:0 -> #0:0 (hevc -> h264 (libx264))',
    'frame=  412 fps= 96 q=22.0 size=  4352kB time=00:00:13.73',
    'frame=  596 fps= 98 q=22.0 size=  7168kB time=00:00:19.86',
    'frame=  781 fps= 99 q=21.0 size= 10240kB time=00:00:26.03',
    'frame=  968 fps=100 q=21.0 size= 13312kB time=00:00:32.26'] }));
const T_WAIT = Object.assign({}, T_LIVE, { id: 'wait' });
T_WAIT.steps = T_LIVE.steps.slice(0, 13).concat([
  SH('scripts/install-linuxapp.sh', { status: 'wait', msg: 14, at: '22:01:37', why: 'The cut needs the Linux app with the split-pane tour installed on this machine, so build and install it first.', out: [] })
]);

const ZONE_LABEL = { think: 'PLAN', sense: 'SENSE', act: 'ACT', shell: 'SHELL', delegate: 'DELEGATE', say: 'SAY' };
const ZORDER = ['think', 'sense', 'act', 'shell', 'delegate', 'say'];
const ZONE_VERB = { think: 'thinking', sense: 'reading', act: 'editing', shell: 'running', delegate: 'delegating', say: 'writing' };
const TURNS = { calm: T_CALM, fix: T_FIX, big: BIG_TURN, live: T_LIVE, wait: T_WAIT };

const T_STATES = {
  id: 'states', family: 'sonnet', effort: 3, dur: '4m 10s', outcome: 'running', prompt: 'Every row state',
  steps: [
    { fam: 'think', tool: 'Thinking', status: 'ok', msg: 1, at: '10:00:00', text: 'The tour is 60 fps and the capture is 30; resample once, then cut both to the riff.' },
    { fam: 'sense', tool: 'Read', status: 'ok', msg: 2, at: '10:00:04', arg: 'out/demo/cut-list.json', out: ['12 lines read'], key: 'cut-list.json' },
    { fam: 'sense', tool: 'Grep', status: 'ok', msg: 2, at: '10:00:04', arg: 'riff  TailscodeCore/Sources/TailscodeCore/Neural', out: ['3 matches'] },
    { fam: 'sense', tool: 'Read', status: 'ok', msg: 2, at: '10:00:04', arg: 'TailscodeCore/Sources/TailscodeCore/Neural/NeuralTimeline.swift', out: ['212 lines read'] },
    { fam: 'shell', tool: 'Bash', status: 'fail', recovered: true, retriedAt: 7, msg: 3, at: '10:00:20', arg: 'swift build -c release 2>&1 | tail -20', key: 'swift build', keyKind: 'cmd', out: ['error: switch must be exhaustive'] },
    { fam: 'say', tool: 'Said', status: 'ok', msg: 4, at: '10:01:02', text: 'The build wants one more case; adding it and building again.' },
    { fam: 'shell', tool: 'Bash', status: 'ok', msg: 5, at: '10:01:40', arg: 'swift build -c release 2>&1 | tail -20', key: 'swift build', keyKind: 'cmd', out: ['Build complete! (212.4s)'] },
    { fam: 'shell', tool: 'Bash', status: 'fail', msg: 6, at: '10:04:55', arg: 'scripts/parity.sh --check', out: ['parity: 2 gaps'] },
    { fam: 'shell', tool: 'Bash', status: 'stopped', msg: 7, at: '10:05:10', arg: 'scripts/install-linuxapp.sh', out: [] },
    { fam: 'shell', tool: 'Bash', status: 'wait', msg: 8, at: '10:05:30', arg: 'rm -rf build-mac', out: [] },
    { fam: 'shell', tool: 'Bash', status: 'run', msg: 9, at: '10:05:41', arg: 'ffmpeg -i ios-tour/walk.mov -vf fps=30 out/demo/ios-30.mp4', out: ['frame=  412'] }
  ]
};
const T_HUGE = (function () {
  const out = [];
  for (let c = 0; c < 6; c++) T_BIG.forEach(s => { const n = Object.assign({}, s, { msg: s.msg + c * 30 }); if (c) { delete n.key; delete n.retriedAt; n.recovered = false; if (n.status === 'fail') n.status = c % 2 ? 'fail' : 'ok'; } out.push(n); });
  return { id: 'huge', family: 'fable', effort: 4, dur: '51m 10s', outcome: 'settled', prompt: 'Rebuild every client and re-record the whole demo.', steps: out };
})();
TURNS.states = T_STATES; TURNS.huge = T_HUGE;
