const fs = require('fs');
const path = require('path');
const OUT = __dirname;

const r2 = (n) => Math.round(n * 100) / 100;

const TOK = {
  'mac-dark': {
    face: 'dark', canvas: '#091521', stage: '#091521', bar: '#091521', ink: '#d9dee8', ink2: 'rgba(217,222,232,.68)', ink3: 'rgba(217,222,232,.44)',
    line: 'rgba(255,255,255,.09)', chip: 'rgba(255,255,255,.075)', chipb: 'rgba(255,255,255,.14)', segOn: 'rgba(255,255,255,.17)',
    dock: 'rgba(30,31,33,.95)', dockLine: 'rgba(255,255,255,.10)', field: 'rgba(255,255,255,.035)', fieldLine: 'rgba(255,255,255,.42)',
    accent: '#5fdaa3', onAccent: '#05271b', danger: '#ff8a94', cap: 'rgba(11,18,29,.93)', capLine: 'rgba(255,255,255,.10)', dot: '#4ade80',
    shadow: '0 6px 22px rgba(0,0,0,.35)'
  },
  'mac-light': {
    face: 'light', canvas: '#f5f9fc', stage: '#f5f9fc', bar: '#f5f9fc', ink: '#17212b', ink2: 'rgba(23,33,43,.70)', ink3: 'rgba(23,33,43,.46)',
    line: 'rgba(0,0,0,.09)', chip: 'rgba(0,0,0,.055)', chipb: 'rgba(0,0,0,.09)', segOn: 'rgba(255,255,255,.95)',
    dock: 'rgba(252,251,252,.96)', dockLine: 'rgba(0,0,0,.10)', field: 'rgba(0,0,0,.02)', fieldLine: 'rgba(0,0,0,.34)',
    accent: '#286b45', onAccent: '#ffffff', danger: '#c8323f', cap: 'rgba(247,249,252,.95)', capLine: 'rgba(0,0,0,.10)', dot: '#2a9d57',
    shadow: '0 6px 22px rgba(20,30,40,.16)'
  },
  'linux-dark': {
    face: 'dark', canvas: '#0e1b2a', stage: '#0b1622', bar: '#0e1b2a', ink: '#d5dce6', ink2: 'rgba(213,220,230,.72)', ink3: 'rgba(213,220,230,.46)',
    line: '#24374d', chip: '#16263a', chipb: '#1d3048', segOn: '#1d3048',
    dock: '#14233a', dockLine: '#24374d', field: '#0a1521', fieldLine: '#2f6a58',
    accent: '#4fd6a0', onAccent: '#052418', danger: '#ff8a94', cap: '#142236', capLine: '#2b4058', dot: '#4fd6a0',
    shadow: 'none'
  }
};

const ICON = {
  download: 'M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4M7 10l5 5 5-5M12 15V3',
  share: 'M4 12v8a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-8M16 6l-4-4-4 4M12 2v13',
  copy: 'M9 9h11v11H9zM5 15H4a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1h10a1 1 0 0 1 1 1v1',
  expand: 'M15 3h6v6M9 21H3v-6M21 3l-7 7M3 21l7-7',
  again: 'M23 4v6h-6M1 20v-6h6M3.5 9a9 9 0 0 1 14.8-3.4L23 10M1 14l4.7 4.4A9 9 0 0 0 20.5 15',
  edit: 'M12 20h9M16.5 3.5a2.1 2.1 0 0 1 3 3L7 19l-4 1 1-4z',
  film: 'M4 4h16v16H4zM7 4v16M17 4v16M4 12h16',
  trash: 'M3 6h18M8 6V4h8v2M19 6l-1 14H6L5 6',
  chev: 'M6 9l6 6 6-6',
  sliders: 'M4 21v-7M4 10V3M12 21v-9M12 8V3M20 21v-5M20 12V3M1 14h6M9 8h6M17 16h6',
  plus: 'M12 5v14M5 12h14',
  play: 'M7 4l13 8-13 8z'
};
const ic = (n, s = 14, sw = 2) =>
  `<svg width="${s}" height="${s}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="${sw}" stroke-linecap="round" stroke-linejoin="round"><path d="${ICON[n]}"/></svg>`;

const WORDS = 'a lighthouse on a cliff at dusk, waves breaking below, last light on the lamp room';
const SHELF = [1, 2, 3, 4, 5, 6, 7, 8];

function studioLayout({ w, h, tb = 44 }) {
  const bh = h - tb;
  const narrow = w < 960;
  const short = h < 760;
  const rail = !narrow;
  const dockH = short ? 88 : 124;
  const railW = 112;
  const Lw = rail ? w - railW : w;
  const stripH = rail ? 0 : 88;
  const dockTop = bh - 16 - dockH;
  const stripTop = rail ? null : dockTop - 8 - stripH;
  const stageTop = 4;
  const stageBottom = rail ? dockTop - 12 : stripTop - 8;
  const stageX = 12;
  const stageW = rail ? Lw - 16 : w - 24;
  const stageH = stageBottom - stageTop;
  const capTop = 36, capBot = 24, side = 24;
  const availH = stageH - capTop - capBot;
  const availW = stageW - 2 * side;
  let ph = Math.min(availH, availW / 1.5);
  const pw = ph * 1.5;
  const px = stageX + (stageW - pw) / 2;
  const py = stageTop + capTop + (availH - ph) / 2;
  return { w, h, tb, bh, narrow, short, rail, dockH, railW, Lw, stripH, dockTop, stripTop, stageTop, stageBottom, stageX, stageW, stageH, pw, ph, px, py, dockX: stageX, dockW: stageW };
}

function studioHTML({ kind, theme, w, h, tb = 44 }) {
  const L = studioLayout({ w, h, tb });
  const lx = kind === 'linux';
  const bodyTop = tb;
  const verbs = lx
    ? [['download', 'Save…'], ['copy', 'Copy'], ['expand', 'Open'], ['again', 'Again', 1], ['plus', 'Use as reference'], ['play', 'Animate this']]
    : [['download', 'Save'], ['share', 'Share'], ['copy', 'Copy'], ['expand', 'Open'], ['again', 'Again'], ['edit', 'Edit this', 1], ['film', 'Animate this'], ['trash', 'Discard', 2]];
  const verbsHTML = verbs.map(([i, t, k]) => `<span class="v${k === 1 ? ' hi' : ''}${k === 2 ? ' bad' : ''}">${ic(i, 14, 1.9)}${t}</span>`).join('');
  const capText = lx
    ? `${WORDS} · Qwen · 1728×1152 · 25 steps · #2477689473 · Today`
    : `${WORDS} · Qwen · 1728×1152 · 11 s · 25 steps · #2477689473`;
  const chips = lx
    ? [['Engine', 'Quality', 1], ['Aspect', '3:2', 1], ['Size', '2 MP', 1], ['Detail', 'Standard', 1], ['', 'Cutout', 0], ['Avoid', '…', 1], ['Seed', 'rolls', 0], ['', 'Add a reference', 1], ['', 'How to describe a picture', 1]]
    : [['', 'Qwen', 1], ['', 'Landscape', 1], ['', '2 MP', 1], ['', 'Standard', 1], ['', 'Cutout', 0], ['', 'Avoid…', 1], ['', 'Seed rolls', 1], ['', 'Add a reference', 1]];
  const chipsHTML = chips.map(([a, b, d]) => `<span class="chip">${a ? `<i>${a}</i>` : ''}<b>${b}</b>${d ? `<em>${lx ? '▾' : ic('chev', 11, 2.2)}</em>` : ''}</span>`).join('');
  const est = lx ? '' : 'about 11 s on arch';

  const tiles = [];
  const need = L.rail ? Math.ceil((L.bh - 32) / 96) + 1 : 8;
  for (let i = 0; i < need; i++) tiles.push(SHELF[i % SHELF.length]);

  const dockIn = L.short
    ? `<div class="start" style="left:14px;top:16px">${ic('plus', 18, 1.6)}<small>Start from</small></div>
       <div class="field" style="left:84px;top:16px;width:${L.dockW - 84 - 14 - 12 - 150 - 12 - 108}px;height:56px"><span>${WORDS}</span></div>
       <div class="setbtn" style="left:${L.dockW - 14 - 150 - 12 - 108}px;top:28px;width:108px">${ic('sliders', 14, 1.8)}Settings</div>
       <div class="gen" style="left:${L.dockW - 14 - 150}px;top:22px;width:150px">Generate <small>⌘↩</small></div>`
    : `<div class="start" style="left:14px;top:14px">${ic('plus', 18, 1.6)}<small>Start from</small></div>
       <div class="field" style="left:84px;top:14px;width:${L.dockW - 84 - 14 - 150 - 12}px;height:56px"><span>${WORDS}</span>
         <div class="enh">✦ Enhance ${lx ? '▾' : ic('chev', 11, 2.2)}</div></div>
       <div class="gen" style="left:${L.dockW - 14 - 150}px;top:20px;width:150px">Generate <small>⌘↩</small></div>
       <div class="chips" style="left:14px;top:82px;width:${L.dockW - 28}px">${chipsHTML}<span class="est">${est}</span></div>`;

  const railHTML = L.rail
    ? `<div class="rail" style="left:${L.Lw}px;top:0;width:${L.railW}px;height:${L.bh}px">
         <div class="rl">${lx ? 'On arch' : 'SHELF'}</div>
         ${tiles.map((n, i) => `<img class="tile${i === 0 ? ' sel' : ''}" src="assets/shelf-${n}.jpg" style="left:12px;top:${32 + i * 96}px">`).join('')}
       </div>`
    : `<div class="strip" style="left:12px;top:${L.stripTop}px;width:${L.w - 24}px;height:${L.stripH}px">
         ${tiles.map((n, i) => `<img class="tile s${i === 0 ? ' sel' : ''}" src="assets/shelf-${n}.jpg" style="left:${8 + i * 80}px;top:8px">`).join('')}
       </div>`;

  const lanes = lx
    ? `<div class="seg"><span class="on">image</span><span>video</span></div>`
    : `<div class="seg"><span class="on">Image</span><span>Video</span></div>`;
  const pill = lx
    ? `<div class="pill"><i class="dot"></i>arch<span class="sep">·</span>Quality ready<span class="sep">·</span>ComfyUI 0.36.0 <em>▾</em></div>`
    : `<div class="pill"><i class="dot"></i><b>arch</b><span class="m">Quality ready</span><span class="sep">·</span><span class="m">ComfyUI 0.36.0</span><em>${ic('chev', 11, 2.2)}</em></div>`;

  return `<div class="studio ${kind} ${TOK[kind + '-' + theme].face}" style="width:${w}px;height:${h}px">
    <div class="tb" style="height:${tb}px">${lanes}${pill}<div class="tbr"><span class="q">${lx ? 'queue 0' : 'Queue 0'}</span><span class="done">Done</span></div></div>
    <div class="body" style="top:${bodyTop}px;height:${L.bh}px">
      <div class="stage" style="left:${L.stageX}px;top:${L.stageTop}px;width:${L.stageW}px;height:${L.stageH}px">
        <div class="cap" style="width:${L.stageW - 48}px;left:24px">${capText}</div>
      </div>
      <img class="pic" src="assets/lighthouse.jpg" style="left:${r2(L.px)}px;top:${r2(L.py)}px;width:${r2(L.pw)}px;height:${r2(L.ph)}px">
      <div class="verbs" style="left:${L.stageX + L.stageW / 2}px;top:${L.stageBottom - 12 - 36}px">${verbsHTML}</div>
      ${railHTML}
      <div class="dock" style="left:${L.dockX}px;top:${L.dockTop}px;width:${L.dockW}px;height:${L.dockH}px">${dockIn}</div>
    </div>
  </div>`;
}

function studioCSS(prefix = '') {
  return `
.studio{position:absolute;overflow:hidden;background:var(--canvas);color:var(--ink);font-family:-apple-system,"SF Pro Text",system-ui,sans-serif;font-size:12.5px;-webkit-font-smoothing:antialiased}
.studio *{box-sizing:border-box}
.studio .tb{position:absolute;left:0;top:0;width:100%;background:var(--bar)}
.studio .seg{position:absolute;left:16px;top:8px;height:28px;width:148px;border-radius:14px;background:var(--chip);display:flex;padding:2px}
.studio .seg span{flex:1;display:flex;align-items:center;justify-content:center;font-weight:500;color:var(--ink2);border-radius:12px}
.studio .seg span.on{background:var(--segOn);color:var(--ink);box-shadow:0 1px 3px rgba(0,0,0,.18)}
.studio .pill{position:absolute;left:50%;top:7px;transform:translateX(-50%);height:30px;padding:0 14px;border-radius:15px;background:var(--chip);display:flex;align-items:center;gap:7px;white-space:nowrap;font-variant-numeric:tabular-nums;box-shadow:inset 0 0 0 1px var(--line)}
.studio .pill b{font-weight:600}.studio .pill .m{color:var(--ink2);font-size:12px}.studio .pill .sep{color:var(--ink3)}.studio .pill em{font-style:normal;color:var(--ink3);display:flex}
.studio .dot{width:8px;height:8px;border-radius:50%;background:var(--dot);flex:none}
.studio .tbr{position:absolute;right:14px;top:7px;height:30px;display:flex;align-items:center;gap:12px}
.studio .q{color:var(--ink2);font-size:12px;font-variant-numeric:tabular-nums}
.studio .done{height:28px;padding:0 15px;border-radius:14px;background:var(--chipb);display:flex;align-items:center;font-weight:600}
.studio .body{position:absolute;left:0;width:100%;overflow:hidden}
.studio .stage{position:absolute;background:var(--stage);border-radius:16px;box-shadow:inset 0 0 0 1px var(--line)}
.studio .cap{position:absolute;top:10px;height:18px;text-align:center;font-size:12px;color:var(--ink2);white-space:nowrap;overflow:hidden;text-overflow:ellipsis;font-variant-numeric:tabular-nums}
.studio .pic{position:absolute;border-radius:12px;object-fit:cover;display:block}
.studio .verbs{position:absolute;transform:translateX(-50%);height:36px;border-radius:18px;display:flex;align-items:center;padding:0 6px;gap:1px;background:var(--cap);box-shadow:inset 0 0 0 1px var(--capLine),var(--shadow);font-weight:500;white-space:nowrap}
.studio .verbs .v{height:28px;padding:0 11px;display:flex;align-items:center;gap:6px;border-radius:14px}
.studio .verbs .v.hi{background:var(--accent);color:var(--onAccent);font-weight:600}.studio .verbs .v.bad{color:var(--danger)}
.studio .rail{position:absolute}.studio .rl{position:absolute;left:14px;top:8px;font-size:10.5px;letter-spacing:.08em;font-weight:600;color:var(--ink3)}
.studio .tile{position:absolute;width:88px;height:88px;border-radius:14px;object-fit:cover;display:block}
.studio .tile.sel{box-shadow:0 0 0 2px var(--canvas),0 0 0 4px var(--accent)}
.studio .strip{position:absolute;overflow:hidden;border-radius:14px;background:var(--chip)}
.studio .tile.s{width:72px;height:72px;border-radius:11px}
.studio .dock{position:absolute;border-radius:20px;background:var(--dock);box-shadow:inset 0 0 0 1px var(--dockLine),var(--shadow)}
.studio .dock>*{position:absolute}
.studio .start{width:56px;height:56px;border-radius:12px;border:1.5px dashed var(--ink3);display:flex;flex-direction:column;align-items:center;justify-content:center;color:var(--ink3);gap:1px}
.studio .start small{font-size:9.5px;white-space:nowrap}
.studio .field{border-radius:12px;box-shadow:inset 0 0 0 1px var(--fieldLine);background:var(--field);padding:9px 12px;font-size:14px;line-height:1.3;overflow:hidden}
.studio .field span{display:block;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.studio .enh{position:absolute;right:8px;bottom:6px;height:24px;padding:0 9px;border-radius:12px;background:var(--chipb);display:flex;align-items:center;gap:5px;font-size:12px;font-weight:500}
.studio .gen{height:44px;border-radius:22px;background:var(--accent);color:var(--onAccent);display:flex;align-items:center;justify-content:center;gap:8px;font-weight:600;font-size:13px}
.studio .gen small{font-size:10.5px;opacity:.8;font-weight:500}
.studio .setbtn{height:32px;border-radius:16px;background:var(--chipb);display:flex;align-items:center;justify-content:center;gap:7px;font-weight:500}
.studio .chips{height:28px;display:flex;align-items:center;gap:8px;white-space:nowrap}
.studio .chip{height:28px;padding:0 11px;border-radius:14px;background:var(--chip);display:flex;align-items:center;gap:5px;font-weight:500}
.studio .chip i{font-style:normal;color:var(--ink3);font-weight:400}.studio .chip b{font-weight:500}.studio .chip em{font-style:normal;color:var(--ink3);display:flex}
.studio .est{margin-left:auto;color:var(--ink3);font-size:11.5px}
.studio.linux{font-family:"JetBrains Mono","IBM Plex Mono","SF Mono",Menlo,monospace;font-size:11.5px}
.studio.linux .seg{border-radius:4px;width:128px;background:transparent;box-shadow:inset 0 0 0 1px var(--line);padding:0;top:9px;height:26px}
.studio.linux .seg span{border-radius:3px}.studio.linux .seg span.on{background:var(--segOn);box-shadow:none}
.studio.linux .pill{border-radius:999px;top:8px;height:28px;background:var(--field);gap:6px;font-size:11.5px}
.studio.linux .done{border-radius:4px;background:transparent;box-shadow:inset 0 0 0 1px var(--capLine);height:26px;font-weight:500}
.studio.linux .stage{border-radius:10px;box-shadow:none}
.studio.linux .pic{border-radius:6px}
.studio.linux .verbs{border-radius:999px;height:34px;font-weight:400;box-shadow:inset 0 0 0 1px var(--capLine)}
.studio.linux .verbs .v{border-radius:999px;height:26px;padding:0 9px}
.studio.linux .rl{font-size:11.5px;letter-spacing:0;font-weight:400;color:var(--ink2);text-transform:none}
.studio.linux .tile{border-radius:6px}.studio.linux .tile.sel{box-shadow:0 0 0 2px var(--accent)}
.studio.linux .dock{border-radius:10px;box-shadow:inset 0 0 0 1px var(--dockLine)}
.studio.linux .start{border-radius:6px}.studio.linux .field{border-radius:6px;font-size:13px}
.studio.linux .enh{border-radius:999px;font-size:11px;background:var(--chip)}
.studio.linux .gen{border-radius:999px;height:42px;font-weight:500;font-size:12.5px}
.studio.linux .chip{border-radius:999px;font-size:11.5px;background:var(--chip);box-shadow:inset 0 0 0 1px var(--line)}
.studio.linux .chip b{font-weight:700}
`;
}

function tokVars(key) {
  const t = TOK[key];
  return Object.entries(t).filter(([k]) => k !== 'face').map(([k, v]) => `--${k}:${v}`).join(';');
}

const LIGHTS = `<div class="lights"><i style="background:#ff5f57"></i><i style="background:#febc2e"></i><i style="background:#28c840"></i></div>`;
const LIGHTS_CSS = `.lights{position:absolute;left:18.5px;top:19px;display:flex;gap:9px;z-index:30}.lights i{display:block;width:14px;height:14px;border-radius:50%;box-shadow:inset 0 0 0 .5px rgba(0,0,0,.28)}`;

function macDarkChat(W, H) {
  const patch = W !== 1440
    ? `<div style="position:absolute;left:1180px;top:0;width:260px;height:52px;background:#091521"></div>
       <div style="position:absolute;right:0;top:0;width:260px;height:52px;background:url(assets/mac-dark-chat.jpg) -1180px 0/1440px 900px no-repeat"></div>`
    : '';
  const fill = W > 1440 || H > 900
    ? `<div style="position:absolute;left:1440px;top:0;right:0;bottom:0;background:#091521"></div><div style="position:absolute;left:0;top:900px;right:0;bottom:0;background:#091521"></div>`
    : '';
  return `<div class="chat" style="background:#091521">
    <img src="assets/mac-dark-chat.jpg" style="position:absolute;left:0;top:0;width:1440px;height:900px">
    ${fill}${W !== 1440 && W > 1440 ? patch : ''}${W < 1440 ? patch : ''}
  </div>`;
}

function macLightChat(W, H) {
  return `<div class="chat" style="background:#f5f9fc">
    <img src="assets/desk-light-chat.jpg" style="position:absolute;left:0;top:7.8px;width:1600px;height:900px">
    <div style="position:absolute;left:0;top:0;width:258px;height:52px;background:#eaf0f7;border-bottom:1px solid #d3dae1"></div>
    <div style="position:absolute;left:258px;top:0;right:0;height:52px;background:#f5f9fc;border-bottom:1px solid #dde3ea"></div>
    <div style="position:absolute;left:96px;top:11px;width:78px;height:30px;border-radius:15px;background:rgba(0,0,0,.05);box-shadow:inset 0 0 0 1px rgba(0,0,0,.05)"><i style="position:absolute;left:14px;top:8px;width:14px;height:14px;border:1.6px solid rgba(23,33,43,.55);border-radius:4px"></i><i style="position:absolute;left:48px;top:8px;width:14px;height:14px;border:1.6px solid rgba(23,33,43,.55);border-radius:4px"></i></div>
    <div style="position:absolute;left:275px;top:9px;font:600 13.5px -apple-system,system-ui;color:#17212b">Fix the flaky WebSocket reconnect test</div>
    <div style="position:absolute;left:275px;top:27px;font:11.5px -apple-system,system-ui;color:rgba(23,33,43,.55)">studio · Claude Code</div>
    <div style="position:absolute;right:16px;top:9px;width:262px;height:34px;border-radius:17px;background:rgba(0,0,0,.05)">
      ${[0, 1, 2, 3, 4].map((i) => `<i style="position:absolute;left:${16 + i * 46}px;top:10px;width:14px;height:14px;border:1.6px solid rgba(23,33,43,.5);border-radius:${i % 2 ? 4 : 7}px"></i>`).join('')}
    </div>
  </div>`;
}

function linuxChat(theme) {
  const f = theme === 'dark' ? 'desk-dark-chat.jpg' : 'desk-light-chat.jpg';
  return `<div class="chat"><img src="assets/${f}" style="position:absolute;left:0;top:0;width:1920px;height:1080px"></div>`;
}

function dimV(x, y1, y2, label, side = 'r', color = '#ff4fd8') {
  const lx = side === 'r' ? x + 8 : x - 8;
  const anchor = side === 'r' ? 'start' : 'end';
  return `<g stroke="${color}" stroke-width="1.5" fill="none"><line x1="${x}" y1="${y1}" x2="${x}" y2="${y2}"/><line x1="${x - 5}" y1="${y1}" x2="${x + 5}" y2="${y1}"/><line x1="${x - 5}" y1="${y2}" x2="${x + 5}" y2="${y2}"/></g>
  <g font-family="ui-monospace,Menlo,monospace" font-size="11.5" font-weight="600"><text x="${lx}" y="${(y1 + y2) / 2 + 4}" text-anchor="${anchor}" fill="${color}" stroke="#000" stroke-width="3" paint-order="stroke">${label}</text></g>`;
}
function dimH(y, x1, x2, label, above = true, color = '#ff4fd8') {
  const ty = above ? y - 7 : y + 17;
  return `<g stroke="${color}" stroke-width="1.5" fill="none"><line x1="${x1}" y1="${y}" x2="${x2}" y2="${y}"/><line x1="${x1}" y1="${y - 5}" x2="${x1}" y2="${y + 5}"/><line x1="${x2}" y1="${y - 5}" x2="${x2}" y2="${y + 5}"/></g>
  <g font-family="ui-monospace,Menlo,monospace" font-size="11.5" font-weight="600"><text x="${(x1 + x2) / 2}" y="${ty}" text-anchor="middle" fill="${color}" stroke="#000" stroke-width="3" paint-order="stroke">${label}</text></g>`;
}
function tag(x, y, label, color = '#ffd24a', anchor = 'start') {
  return `<g font-family="ui-monospace,Menlo,monospace" font-size="11.5" font-weight="600"><text x="${x}" y="${y}" text-anchor="${anchor}" fill="${color}" stroke="#000" stroke-width="3" paint-order="stroke">${label}</text></g>`;
}

/**
 * Build one window composite.
 * o: {kind:'mac'|'linux', theme, W, H, scrim, sheetOpacity, travel, titleClear, cap, hairline, overlay(svg inside window), lightsBright}
 */
function windowHTML(o) {
  const { kind, theme, W, H } = o;
  const titleClear = o.titleClear ?? (kind === 'mac' ? 52 : 53);
  const top = Math.max(36, titleClear + 8);
  const sideIn = W < 700 ? 0 : 24;
  const sw = Math.min(W - 2 * sideIn, o.cap ?? 1752);
  const left = (W - sw) / 2;
  const sh = H - top;
  const key = `${kind}-${theme}`;
  const chat = kind === 'mac' ? (theme === 'dark' ? macDarkChat(W, H) : macLightChat(W, H)) : linuxChat(theme);
  const radius = kind === 'mac' ? 26 : 10;
  const sheetTop = o.sheetTopRadius ?? (kind === 'mac' ? 14 : 8);
  const scrim = o.scrim ?? 0.38;
  const studio = studioHTML({ kind, theme, w: sw, h: sh });
  const hair = o.hairline ? 'box-shadow:0 -1px 0 rgba(255,255,255,.16),0 -10px 36px rgba(0,0,0,.5);' : '';
  const trans = o.travel ? `transform:translateY(${o.travel}px);` : '';
  const op = o.sheetOpacity != null ? `opacity:${o.sheetOpacity};` : '';
  const lights = kind === 'mac' ? LIGHTS : '';
  return {
    html: `<div class="win ${kind} ${theme}" style="width:${W}px;height:${H}px;border-radius:${radius}px;${tokVars(key)}">
      ${chat}
      <div class="scrim" style="background:rgba(0,0,0,${scrim})"></div>
      ${o.ghost ? `<div class="ghost" style="left:${left}px;top:${top}px;width:${sw}px;height:${sh}px;border-radius:${sheetTop}px ${sheetTop}px 0 0"></div>` : ''}
      <div class="sheet" style="left:${left}px;top:${top}px;width:${sw}px;height:${sh}px;border-radius:${sheetTop}px ${sheetTop}px 0 0;${trans}${op}${hair}">${studio}</div>
      ${lights}
      ${o.overlay || ''}
    </div>`,
    geom: { top, left, sw, sh, W, H, titleClear, sideIn }
  };
}

const WIN_CSS = `
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:-apple-system,system-ui,sans-serif}
.win{position:relative;overflow:hidden;box-shadow:0 0 0 1px rgba(255,255,255,.14),0 30px 80px rgba(0,0,0,.5),0 6px 18px rgba(0,0,0,.35);background:var(--canvas)}
.win.light{box-shadow:0 0 0 1px rgba(0,0,0,.18),0 30px 80px rgba(20,30,40,.30),0 6px 18px rgba(20,30,40,.18)}
.chat{position:absolute;inset:0;overflow:hidden}
.scrim{position:absolute;inset:0}
.sheet{position:absolute;overflow:hidden;background:var(--canvas)}
.ghost{position:absolute;border:1.5px dashed #ffd24a;pointer-events:none;z-index:5}
.win svg.ov{position:absolute;left:0;top:0;pointer-events:none;z-index:40;overflow:visible}
${LIGHTS_CSS}
${studioCSS()}
`;

function page({ title, W, H, theme, inner, pad = 56, extraRight = 0, extraBottom = 0, bg, extraCSS = '', head = '' }) {
  const pageBg = bg ?? (theme === 'dark' ? '#17171b' : '#cdd1d8');
  return `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>${title}</title>
<style>
${WIN_CSS}
html,body{background:${pageBg}}
#frame{position:relative;width:${W + pad * 2 + extraRight}px;height:${H + pad * 2 + extraBottom}px;background:${pageBg}}
#frame>.win{position:absolute;left:${pad}px;top:${pad}px}
${extraCSS}
</style></head><body><div id="frame">${inner}</div></body></html>`;
}

function write(name, html) {
  fs.writeFileSync(path.join(OUT, name + '.html'), html);
}

const mocks = {};

(function build() {
  const W = 1440, H = 900;

  const open = (theme) => {
    const w = windowHTML({ kind: 'mac', theme, W, H });
    return page({ title: `Studio sheet — Mac ${theme}, open`, W, H, theme, inner: w.html });
  };
  write('mac-dark-open', open('dark'));
  write('mac-light-open', open('light'));

  {
    const p = 0.55;
    const e = 1 - Math.pow(1 - p, 3);
    const top = 60, sh = H - top;
    const total = 0.28 * sh;
    const remain = total * (1 - e);
    const scrimA = 0.38 * p;
    const w = windowHTML({ kind: 'mac', theme: 'dark', W, H, scrim: scrimA, travel: r2(remain), sheetOpacity: p, ghost: true });
    const pad = 56, gutter = 340;
    const ox = pad + W + 20;
    const g = w.geom;
    const ov = `<svg class="ov" width="${W + pad * 2 + gutter}" height="${H + pad * 2}" style="left:${-pad}px;top:${-pad}px" viewBox="0 0 ${W + pad * 2 + gutter} ${H + pad * 2}">
      <g stroke="#ffd24a" stroke-width="1.2" fill="none"><line x1="${pad + g.left + g.sw / 2}" y1="${pad + g.top}" x2="${ox - 4}" y2="${pad + g.top}" stroke-dasharray="3 4"/><line x1="${pad + g.left + g.sw}" y1="${pad + g.top + remain}" x2="${ox - 4}" y2="${pad + g.top + remain}" stroke-dasharray="3 4"/></g>
      ${dimV(ox + 2, pad + g.top, pad + g.top + remain, `${r2(remain)} pt remaining`, 'r', '#ff4fd8')}
    </svg>`;
    const side = `<div class="notes" style="left:${pad + W + 24}px;top:${pad + 120}px;width:${gutter - 40}px">
      <h4>t = 176 ms of 320</h4><p>progress 0.55 · ease-out-cubic<br>e = 1 − (1 − 0.55)³ = ${r2(e)}</p>
      <h4>travel</h4><p>0.28 × ${sh} pt = ${r2(total)} pt total<br>remaining = ${r2(total)} × (1 − ${r2(e)}) = <b>${r2(remain)} pt</b><br><span class="d">yellow dashed = the rest position</span></p>
      <h4>scrim alpha</h4><p>38 % × 0.55 (linear) = <b>${r2(scrimA * 100)} %</b></p>
      <h4>sheet opacity</h4><p>0.55 linear. The doc says “fading in” but not which curve: on the eased curve it would already be 0.91 and the fade would be invisible.</p>
    </div>`;
    // the overlay svg must not be clipped by the window; render it outside .win
    const htmlOut = page({
      title: 'Studio sheet — Mac dark, mid-open', W, H, theme: 'dark', pad, extraRight: gutter,
      inner: w.html + `<svg class="ov2" width="${W + pad * 2 + gutter}" height="${H + pad * 2}" style="position:absolute;left:0;top:0;pointer-events:none;z-index:60" viewBox="0 0 ${W + pad * 2 + gutter} ${H + pad * 2}">${ov.replace(/^<svg[^>]*>/, '').replace('</svg>', '')}</svg>` + side,
      extraCSS: `.notes{position:absolute;color:#cfd3dc;font:12px ui-monospace,Menlo,monospace;line-height:1.5}.notes h4{color:#ffd24a;font-size:12px;margin:18px 0 4px;font-weight:700}.notes p{color:#aab0bc}.notes b{color:#fff}.notes .d{color:#ffd24a}`
    });
    write('mac-mid-open', htmlOut);
  }

  {
    const pad = 150, gutter = 190;
    const g0 = windowHTML({ kind: 'mac', theme: 'dark', W, H });
    const g = g0.geom;
    const X = pad, Y = pad;
    const L = studioLayout({ w: g.sw, h: g.sh });
    const sx = X + g.left, sy = Y + g.top;
    const svg = `<svg width="${W + pad * 2 + gutter}" height="${H + pad * 2}" style="position:absolute;left:0;top:0;pointer-events:none;z-index:60" viewBox="0 0 ${W + pad * 2 + gutter} ${H + pad * 2}">
      <rect x="${X}" y="${Y}" width="${W}" height="${g.top}" fill="rgba(255,210,74,.10)" stroke="#ffd24a" stroke-width="1" stroke-dasharray="4 4"/>
      <rect x="${X}" y="${Y + g.top}" width="${g.left}" height="${g.sh}" fill="rgba(255,210,74,.12)"/>
      <rect x="${X + g.left + g.sw}" y="${Y + g.top}" width="${g.left}" height="${g.sh}" fill="rgba(255,210,74,.12)"/>
      ${tag(X, Y - 12, 'visible context strip: 60 pt tall = 6.7 % of the window height; side strips 24 pt', '#ffd24a')}
      ${dimV(X - 30, Y, Y + 52, 'title bar 52', 'l', '#7dd3fc')}
      ${dimV(X - 30, Y + 60, Y + H, `sheet ${g.sh}`, 'l', '#7dd3fc')}
      ${dimV(X + W + 14, Y, Y + 60, 'top inset 60 = 52 + 8', 'r', '#ff4fd8')}
      ${dimV(X + W + 14, Y + H - 40, Y + H, 'bottom 0 (flush)', 'r', '#ff4fd8')}
      ${dimH(Y + 420, X, X + 24, '24', true, '#ff4fd8')}
      ${dimH(Y + 420, X + W - 24, X + W, '24', true, '#ff4fd8')}
      ${dimH(Y + H + 34, X + g.left, X + g.left + g.sw, `sheet width ${g.sw} = 1440 − 2 × 24`, false, '#7dd3fc')}
      ${dimV(sx + 300, sy, sy + 44, 'toolbar 44', 'r', '#ff4fd8')}
      <path d="M ${sx} ${sy + 14} A 14 14 0 0 1 ${sx + 14} ${sy}" fill="none" stroke="#ff4fd8" stroke-width="3"/>
      ${tag(X - 8, sy + 4, 'r 14 →', '#ff4fd8', 'end')}
      ${dimV(sx + 50, sy + 44 + L.stageTop, sy + 44 + L.stageBottom, `stage ${r2(L.stageH)}`, 'r', '#5fdaa3')}
      ${tag(X + W + 14, Y + 220, 'scrim: black 38 %', '#ffd24a')}
      ${tag(X + W + 14, Y + 236, 'over everything the', '#ffd24a')}
      ${tag(X + W + 14, Y + 250, 'sheet does not cover', '#ffd24a')}
      ${tag(X + W + 14, Y + H - 70, 'window corner r 26', '#a3a3a3')}
      ${tag(X + W + 14, Y + H - 56, '(assumed)', '#a3a3a3')}
    </svg>`;
    write('geometry', page({ title: 'Studio sheet — geometry', W, H, theme: 'dark', pad, extraRight: gutter, inner: g0.html + svg }));
  }

  {
    const cols = [
      ['30 %', 0.30, false],
      ['38 % (the doc)', 0.38, false],
      ['45 %', 0.45, false],
      ['38 % + 1-pt hairline and a soft shadow on the sheet’s top edge', 0.38, true]
    ];
    const strips = cols.map(([label, a, hair]) => {
      const w = windowHTML({ kind: 'mac', theme: 'dark', W, H, scrim: a, hairline: hair });
      return `<div class="lab">${label}</div><div class="strip">${w.html}</div>`;
    }).join('');
    const thumbs = cols.slice(0, 3).map(([label, a]) => {
      const w = windowHTML({ kind: 'mac', theme: 'dark', W, H, scrim: a });
      return `<div class="lab">${label} — whole window at 50 %</div><div class="thumb"><div class="inner">${w.html}</div></div>`;
    }).join('');
    const pad = 40;
    const totalW = 1440 + 60 + 720 + pad * 2;
    const totalH = 1600;
    const html = `<!doctype html><html><head><meta charset="utf-8"><title>Studio sheet — scrim variants</title><style>
${WIN_CSS}
html,body{background:#17171b}
#frame{position:relative;width:${totalW}px;height:${totalH}px;background:#17171b;color:#cfd3dc}
.col1{position:absolute;left:${pad}px;top:${pad}px;width:1440px}.col2{position:absolute;left:${pad + 1440 + 60}px;top:${pad}px;width:720px}
.lab{font:600 13px ui-monospace,Menlo,monospace;color:#ffd24a;margin:0 0 8px}
.strip{position:relative;width:1440px;height:300px;overflow:hidden;margin-bottom:26px;border-radius:6px}
.strip .win{position:absolute;left:0;top:0;box-shadow:none}
.thumb{position:relative;width:720px;height:450px;margin-bottom:22px}.thumb .inner{position:absolute;left:0;top:0;width:1440px;height:900px;transform:scale(.5);transform-origin:0 0}
.thumb .win{box-shadow:none}
</style></head><body><div id="frame"><div class="col1">${strips}</div><div class="col2">${thumbs}</div></div></body></html>`;
    write('scrim-variants', html);
  }

  {
    const w = windowHTML({ kind: 'linux', theme: 'dark', W: 1920, H: 1080 });
    write('linux-dark-open', page({ title: 'Studio sheet — Linux dark, open', W: 1920, H: 1080, theme: 'dark', inner: w.html }));
  }

  {
    const w = windowHTML({ kind: 'mac', theme: 'dark', W: 960, H: 640 });
    write('narrow-960', page({ title: 'Studio sheet — 960 × 640 recomposition', W: 960, H: 640, theme: 'dark', inner: w.html }));
  }

  {
    const w = windowHTML({ kind: 'mac', theme: 'dark', W: 2560, H: 1440 });
    write('wide-2560', page({ title: 'Studio sheet — 2560 × 1440', W: 2560, H: 1440, theme: 'dark', inner: w.html }));
  }
})();

module.exports = { windowHTML, page, WIN_CSS, studioLayout, write, OUT, dimV, dimH, tag };
