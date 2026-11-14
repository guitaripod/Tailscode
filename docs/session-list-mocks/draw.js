document.documentElement.dataset.theme = location.hash.includes('light') ? 'light' : 'dark'
if (location.hash.includes('linux')) document.documentElement.dataset.skin = 'linux'

const S = (d, w = 12) => `<svg viewBox="0 0 16 16" width="${w}" height="${w}" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round">${d}</svg>`
const BADGE = {
  work: `<span style="color:var(--accent)">${S('<circle cx="8" cy="8" r="6.6" stroke-opacity=".38"/><circle cx="8" cy="8" r="3.6" fill="currentColor" stroke="none"/>')}</span>`,
  bg: `<span style="color:var(--accent)">${S('<circle cx="8" cy="8" r="6"/><path d="M8 4.6V8l2.4 1.5"/>')}</span>`,
  ask: `<span style="color:var(--warn)">${S('<circle cx="8" cy="8" r="6.4"/><path d="M6.4 5.6v4.8M9.6 5.6v4.8"/>')}</span>`,
  stall: `<span style="color:var(--warn)">${S('<circle cx="8" cy="8" r="6"/><path d="M8 4.6V8l2.4 1.5"/>')}</span>`,
  q: `<span style="color:var(--warn)">${S('<circle cx="8" cy="8" r="6.4"/><path d="M6.3 6.3a1.8 1.8 0 1 1 2.6 1.6c-.6.4-.9.8-.9 1.4"/><circle cx="8" cy="11.4" r=".5" fill="currentColor"/>')}</span>`,
  fail: `<span style="color:var(--bad)">${S('<circle cx="8" cy="8" r="6.6" fill="currentColor" stroke="none"/><path d="M5.7 5.7l4.6 4.6M10.3 5.7l-4.6 4.6" stroke="var(--side)" stroke-width="1.7"/>')}</span>`,
  off: `<span style="color:var(--ink3)">${S('<path d="M2.5 6.5a8 8 0 0 1 11 0M5 9.2a4.4 4.4 0 0 1 6 0"/><circle cx="8" cy="12" r=".7" fill="currentColor"/><path d="M3 2.5l10 11"/>')}</span>`,
  dot: '<i class="dot"></i>',
  idle: '·',
  none: '',
}
if (document.documentElement.dataset.skin === 'linux') {
  const g = (c, t) => `<span class="tg" style="color:var(--${c})">${t}</span>`
  Object.assign(BADGE, { work: g('accent', '●'), bg: g('accent', '◔'), stall: g('warn', '◔'), ask: g('warn', '⏸'), q: g('warn', '?'), fail: g('bad', '✗'), off: g('ink3', '⚠'), dot: g('accent', '●') })
}
const MARK = {
  pin: S('<path d="M5.4 2.2h5.2l-.7 4.1 2.1 2.3H4l2.1-2.3z" fill="currentColor" stroke-width="1.2"/><path d="M8 8.8v5"/>', 10),
  save: S('<path d="M4.2 2.4h7.6v11.2L8 10.9l-3.8 2.7z" fill="currentColor" stroke-width="1.1"/>', 10),
  clock: S('<circle cx="8" cy="8" r="6"/><path d="M8 4.8V8l2 1.3"/>', 10),
}
const VERBS = [
  S('<path d="M5.4 2.2h5.2l-.7 4.1 2.1 2.3H4l2.1-2.3z"/><path d="M8 8.8v5"/>', 12),
  S('<path d="M4.2 2.4h7.6v11.2L8 10.9l-3.8 2.7z"/>', 12),
  S('<rect x="2" y="3" width="12" height="3.2" rx=".8"/><path d="M3.2 6.2v6.4h9.6V6.2M6.4 9h3.2"/>', 12),
  S('<circle cx="3.6" cy="8" r=".9" fill="currentColor"/><circle cx="8" cy="8" r=".9" fill="currentColor"/><circle cx="12.4" cy="8" r=".9" fill="currentColor"/>', 12),
]

function rainbow(word) {
  const n = word.length
  const light = document.documentElement.dataset.theme === 'light' ? '78% 42%' : '88% 66%'
  return [...word].map((c, i) => `<span style="color:hsl(${Math.round(i * 300 / (n - 1))} ${light})">${c}</span>`).join('')
}
function chip(r) {
  const hue = { Opus: 'var(--opus)', Fable: 'var(--fable)', Sonnet: 'var(--sonnet)' }[r.m] || 'var(--ink2)'
  const heat = { xhigh: 'var(--hot)', high: 'var(--warm)', medium: 'var(--ink2)' }[r.e]
  const effort = r.e === 'ultracode' ? rainbow(r.e) : `<span style="color:${heat}">${r.e}</span>`
  return `<span class="chip"><span style="color:${hue}">${r.m}</span> ${effort}</span>`
}

const ROWS = [
  { sec: 'needs', t: 'Cut the 2.4 release branch', st: 'ask', ask: ['Wants to run', 'git push origin release/2.4'], proj: 'pulse-server', host: 'studio', m: 'Opus', e: 'xhigh', age: '3m' },
  { sec: 'working', t: 'Fix the flaky WebSocket reconnect test', st: 'work', step: 'Running swift test --filter Reconnect', proj: 'pulse-server', host: 'studio', m: 'Opus', e: 'ultracode', age: '12s', sel: true },
  { sec: 'working', t: 'Backtest the pricing model', st: 'bg', step: 'cargo test --release · for 4m', proj: 'acme-pricing', host: 'workshop', m: 'Opus', e: 'high', age: '4m', pinned: true },
  { sec: 'pinned', t: 'Dark mode for the settings screen', unread: true, said: 'Dark mode is in for Settings: every row reads from the palette now, and the two hard-coded greys are gone.', proj: 'pulse-ios', host: 'studio', m: 'Opus', e: 'ultracode', age: '54m', pinned: true },
  { sec: 'saved', t: 'Migrate CI to self-hosted runners', proj: 'pulse-infra', host: 'studio', m: 'Opus', e: 'ultracode', age: '6d', saved: true },
  { sec: 'saved', t: 'Hunt the memory leak in ImagePipeline', proj: 'acme-ios', host: 'workshop', m: 'Opus', e: 'xhigh', age: '19d', saved: true },
  { sec: 'today', t: 'Redesign the composer and its send button', unread: true, said: 'Three directions are on the board; the docked one keeps Send under the thumb.', proj: 'pulse-ios', host: 'studio', m: 'Opus', e: 'ultracode', age: '41m' },
  { sec: 'today', t: 'Write the v2.3 release notes', proj: 'acme-api', host: 'studio', m: 'Fable', e: 'ultracode', age: '1h' },
  { sec: 'today', t: 'Ship the pricing page A/B test', unread: true, st: 'fail', failed: true, proj: 'acme-web', host: 'studio', m: 'Opus', e: 'high', age: '1h' },
  { sec: 'today', t: 'Explain the auth token refresh flow', proj: 'pulse-server', host: 'studio', m: 'Opus', e: 'xhigh', age: '1h' },
  { sec: 'today', t: 'Refactor the auth module to async/await', proj: 'acme-api', host: 'studio', m: 'Opus', e: 'ultracode', age: '2h' },
  { sec: 'yesterday', t: 'What is eating my GPU memory?', proj: 'demo', host: 'workshop', m: 'Sonnet', e: 'high', age: '1d' },
  { sec: 'yesterday', t: 'Add the jitter bound test', proj: 'acme-api', host: 'studio', m: 'Opus', e: 'xhigh', age: '1d' },
  { sec: 'week', t: 'Benchmark the new tokenizer', proj: 'acme-ml', host: 'workshop', m: 'Opus', e: 'high', age: '4d' },
]

function oldRow(r) {
  const pills = []
  if (r.st === 'ask') pills.push('<span class="pill need">NEEDS YOU</span>')
  if (r.st === 'work') pills.push('<span class="pill live">LIVE</span>')
  if (r.st === 'bg') pills.push('<span class="pill live">BACKGROUND</span>')
  if (r.st === 'fail') pills.push('<span class="pill fail">FAILED</span>')
  if (r.pinned) pills.push('<span class="pill pin">PINNED</span>')
  if (r.saved) pills.push('<span class="pill sav">SAVED</span>')
  if (r.unread && !['ask', 'work', 'bg', 'fail'].includes(r.st)) pills.push('<span class="udot">●</span>')
  const second = r.step
    ? `${chip(r)}<span class="where step" style="color:var(--accent)">${r.step}</span>`
    : `${chip(r)}<span class="where">${r.proj} <i>· ${r.host}</i></span>`
  return `<div class="row ${r.unread ? 'unread' : ''} ${r.sel ? 'sel' : ''}"><div class="st">${BADGE[r.st] || BADGE.idle}</div><div class="tx"><div class="l1"><span class="t">${r.t}</span>${pills.join('')}</div><div class="l3">${second}<span class="age">${r.age}</span></div></div></div>`
}

function newsLine(r, opts) {
  if (r.askText) return '<div class="l2 ask two">Which headline should the page lead with, the price or the trial?</div>'
  if (r.ask) return `<div class="l2 ask">${r.ask[0]} <span class="obj">${r.ask[1]}</span></div>`
  if (r.stalled) return `<div class="l2 ask">${r.step}</div>`
  if (r.step) return `<div class="l2 step">${r.step}</div>`
  if (r.failed) return '<div class="l2 bad">Last turn failed</div>'
  if (r.offline) return `<div class="l2">Last heard ${r.age} ago</div>`
  if (r.unread) return `<div class="l2 ${opts.one ? '' : 'two'}">${r.said || 'Finished'}</div>`
  return ''
}

function newRow(r, opts = {}) {
  const home = { pinned: 'pinned', saved: 'saved' }
  const marks = []
  if (r.pinned && r.sec !== home.pinned) marks.push(`<span class="mk">${MARK.pin}</span>`)
  if (r.saved && r.sec !== home.saved) marks.push(`<span class="mk">${MARK.save}</span>`)
  if (r.scheduled) marks.push(`<span class="mk">${MARK.clock}</span>`)
  const state = r.marked ? '<span class="tg" style="color:var(--accent)">✓</span>' : r.st ? BADGE[r.st] : r.unread ? BADGE.dot : BADGE.none
  const verbs = r.hov ? `<div class="verbs">${VERBS.map(v => `<span>${v}</span>`).join('')}</div>` : ''
  const age = r.hov ? '' : `<span class="age">${r.age}</span>`
  const fade = r.unread || r.st ? '' : ' style="--chipfade:var(--readchip,1)"'
  const lit = ['ask', 'q', 'stall'].includes(r.st) ? 'need' : ['work', 'bg'].includes(r.st) ? 'live' : ''
  return `<div class="row ${lit} ${r.unread ? 'unread' : ''} ${r.sel ? 'sel' : ''} ${r.hov ? 'hov' : ''} ${r.offline ? 'off' : ''} ${r.marked ? 'marked' : ''}"${fade}><div class="st">${state}</div><div class="tx"><div class="l1"><span class="t">${r.t}</span>${marks.join('')}</div>${newsLine(r, opts)}<div class="l3"><span class="where">${r.proj} <i>· ${r.host}</i></span>${chip(r)}${age}</div></div>${verbs}</div>`
}

const OLD_SECTIONS = [['needs', 'NEEDS YOU'], ['working', 'WORKING'], ['pinned', 'PINNED'], ['saved', 'SAVED'], ['recent', 'RECENT']]
const NEW_SECTIONS = [['needs', 'Needs you'], ['working', 'Working'], ['pinned', 'Pinned'], ['saved', 'Saved'], ['today', 'Today'], ['yesterday', 'Yesterday'], ['week', 'Previous 7 days']]

function oldSidebar(rows = ROWS) {
  const recent = new Set(['today', 'yesterday', 'week'])
  return `<div class="side old">` + OLD_SECTIONS.map(([key, title]) => {
    const members = rows.filter(r => key === 'recent' ? recent.has(r.sec) : r.sec === key)
    if (!members.length) return ''
    const count = key === 'recent' ? 1800 : members.length
    return `<div class="hd"><span>${title}</span><span class="n">${count}</span></div>` + members.map(oldRow).join('')
  }).join('') + '</div>'
}

function newSidebar(rows = ROWS, opts = {}) {
  return `<div class="side" style="${opts.style || ''}">` + NEW_SECTIONS.map(([key, title]) => {
    const members = rows.filter(r => r.sec === key)
    if (!members.length) return ''
    const fresh = members.filter(r => r.unread).length
    const tally = key === 'needs' || key === 'working' ? `<span class="n">${members.length}</span>` : ''
    const news = fresh && key !== 'needs' && key !== 'working' ? `<span class="new">${fresh} new</span>` : ''
    return `<div class="hd ${key === 'needs' ? 'needs' : ''}"><span>${title}</span>${news}${tally}</div>` + members.map(r => newRow(r, opts)).join('')
  }).join('') + (opts.more ? `<div class="more">${opts.more}</div>` : '') + '</div>'
}

function fig(caption, sub, body, foot = '') {
  return `<div class="fig"><div class="cap">${caption}</div><div class="sub">${sub}</div>${body}${foot ? `<div class="tot">${foot}</div>` : ''}</div>`
}
