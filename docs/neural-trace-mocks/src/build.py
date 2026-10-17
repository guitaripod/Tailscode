import sys, json
from pathlib import Path

here = Path(__file__).parent
out = Path(sys.argv[1])
out.mkdir(parents=True, exist_ok=True)

css = (here / "base.css").read_text()
engine = (here / "engine.js").read_text()
data = (here / "data.js").read_text()

PAGE_CSS = """
.page{max-width:1080px;margin:0 auto;padding:18px 16px 44px}
.bar{display:flex;align-items:center;justify-content:space-between;gap:12px;flex-wrap:wrap;margin-bottom:14px}
.eyebrow{letter-spacing:.2em;font-size:11px;color:var(--accent)}
.tools{display:flex;gap:8px}
.runline{display:flex;align-items:center;gap:10px;flex-wrap:wrap;margin:0 0 12px;color:var(--ink2)}
.runline .chev{color:var(--ink3);font-size:11px}
.runline .cnt{color:var(--accent);font-weight:700}
.runline .mix{color:var(--ink3)}
.runline .dif .a{color:var(--accent)}
.runline .dif .d{color:var(--danger)}
.runline .note{color:var(--ink3)}
.stage{border:1px solid var(--rule);border-radius:14px;background:linear-gradient(180deg,var(--panel),var(--bg))}
.nv-scroll{border-radius:14px}
.steps{list-style:none;margin:12px 0 0;padding:0;display:none;flex-direction:column;gap:4px}
.steps button{display:flex;align-items:center;gap:9px;width:100%;text-align:left;padding:6px 10px;min-height:44px;font-size:12px}
.steps .no{color:var(--ink3);min-width:18px}
.steps .tl{color:var(--ink)}
.steps .ar{color:var(--ink3);overflow:hidden;text-overflow:ellipsis;white-space:nowrap;flex:1}
.steps .bad{color:var(--danger)}
@media (max-width:560px){.steps{display:flex}}
.foot{color:var(--ink3);font-size:11.5px;margin:14px 0 0;max-width:78ch}
.foot b{color:var(--ink2);font-weight:600}
@media (max-width:560px){.page{padding:14px 12px 36px}.zl{display:none}}
"""

LEGEND_JS = """
function legend(el){
  el.innerHTML=Neural.ORDER.map(f=>{const m=Neural.FAM[f];return `<li class="f-${f}">${Neural.shapeSvg(f,20)}<span>${m.label}</span><small>${m.sub}</small></li>`;}).join('');
}
function stepList(el,steps,nv){
  el.innerHTML=steps.map((s,i)=>`<li><button type="button" data-i="${i}">${Neural.shapeSvg(s.fam,18)}<span class="no">${i+1}</span><span class="tl${s.status==='fail'?' bad':''}">${s.tool}</span><span class="ar">${(s.arg||s.text||'').replace(/</g,'&lt;')}</span></button></li>`).join('');
  el.querySelectorAll('button').forEach(b=>b.onclick=()=>nv.setHot(parseInt(b.dataset.i,10)));
}
function mixHex(h,t){const c=[1,3,5].map(i=>parseInt(h.slice(i,i+2),16));return '#'+c.map(v=>Math.round(v+(255-v)*t).toString(16).padStart(2,'0')).join('');}
function stageTheme(el,th){
  const f=h=>th.light?mixHex(h,.45):h,s=el.style;
  s.setProperty('--accent',f(th.accent));s.setProperty('--accent2',f(th.accent));s.setProperty('--info',f(th.info));s.setProperty('--special',f(th.special));s.setProperty('--warn',f(th.warn));s.setProperty('--danger',f(th.danger));
  s.setProperty('--ink',th.light?'#e6e1ee':th.ink);s.setProperty('--ink2',th.light?'#b8b2c9':th.ink2);s.setProperty('--ink3',th.light?'#8d87a3':th.ink2+'99');
  s.setProperty('--panel',th.light?'#0a1210':th.bg);s.setProperty('--rule2',th.light?'#4a5b57':th.ink2+'55');s.setProperty('--rule',th.light?'#26332f':th.ink2+'33');
}
function params(){return new URLSearchParams(location.search);}
function applyTheme(){const t=params().get('theme');if(t)document.documentElement.setAttribute('data-theme',t);}
function runLine(el,steps,live){
  const d=Neural.diffTally(steps);
  const fails=steps.filter(s=>s.status==='fail').length;
  el.innerHTML=`<span class="chev">▸</span><span class="gl">${Neural.glyph(steps,{live})}</span><span class="cnt">${Neural.toolCount(steps)} tools</span><span class="mix">${Neural.toolMix(steps)}</span>`
    +(d[0]||d[1]?`<span class="dif"><span class="a">+${d[0]}</span> <span class="d">−${d[1]}</span></span>`:'')
    +(fails?`<span class="note">${fails} failed, then passed</span>`:'');
}
"""


def page(letter, name, body, script):
    return f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{letter} · {name}</title>
<style>{css}{PAGE_CSS}</style></head>
<body>
{body}
<script>{data}{engine}{LEGEND_JS}{script}</script>
</body></html>
"""


def stage_page(letter, name, layout, foot):
    body = f"""<main class="page">
<header class="bar"><span class="eyebrow">{letter} · {name.upper()}</span>
<div class="tools"><button id="replay" type="button">▶ Replay</button><button id="live" type="button" aria-pressed="false">Live tip</button></div></header>
<div class="runline" id="line"></div>
<section class="stage nv-scroll" id="stage"></section>
<ul class="legend" id="legend"></ul>
<ol class="steps" id="steps" aria-label="Steps"></ol>
<p class="foot">{foot}</p>
</main>"""
    script = f"""
applyTheme();
const P=params();
const steps=BUILD_FIX;
runLine(document.getElementById('line'),steps,P.get('live')==='1');
legend(document.getElementById('legend'));
const stage=document.getElementById('stage');
const nv=Neural.mount(stage,{{steps,layout:'{layout}',live:P.get('live')==='1',label:'Fix a failing build, 14 steps'}});
const live=document.getElementById('live');
if(P.get('live')==='1')live.setAttribute('aria-pressed','true');
stepList(document.getElementById('steps'),steps,nv);
document.getElementById('replay').onclick=()=>nv.play();
live.onclick=()=>{{const on=live.getAttribute('aria-pressed')!=='true';live.setAttribute('aria-pressed',on);nv.setLive(on);}};
if(P.get('t')!==null)nv.paint(parseFloat(P.get('t')));
if(P.get('replay')==='1')nv.play();
if(P.get('hover')!==null)nv.setHot(parseInt(P.get('hover'),10)-1);
"""
    return page(letter, name, body, script)


foot_a = ("<b>Where</b> is the kind of work: a fixed anatomy, so the shape of a turn reads before a word of it does. "
          "Order is the numbered path and the replay. Wires are only what the transcript shows: one step after another, calls made together in one message, "
          "and a dashed tie where two steps touched the same file or ran the same command.")
foot_b = ("<b>When</b> is the left-to-right axis, so retries, fan-outs and a build that failed then passed read as what they are. "
          "Same five lanes and shapes as the cortex, laid on time instead of on a head. Dashed ties underneath join steps on the same file or command.")

(out / "A.html").write_text(stage_page("A", "Cortex", "cortex", foot_a))
(out / "B.html").write_text(stage_page("B", "Lanes", "lanes", foot_b))

c_body = """<main class="page" id="doc">
<header class="bar"><span class="eyebrow">C · IN THE TRANSCRIPT</span>
<div class="tools"><button id="m-today" type="button" aria-pressed="false">Today ●</button><button id="m-brain" type="button" aria-pressed="true">Brain glyph</button></div></header>
<div class="turn">
<div class="prompt">Make a product demonstration using mock data but the real apps .mp4 i can share on twitter. use /mnt/nvme8tb/Music/Pantera-The_Complete_Albums_1990-2000-24BIT-REMASTERED-WEB-FLAC-2016-RUIDOS/203-pantera-walk.flac as the background track starting from the beginning and playing for how long the demo video is.</div>
<div class="run" data-run="r1"></div>
<p class="prose">Building it from the existing film rig: Linux app in <code>--demo</code> on a private 4K display, plus the iOS demo tour, cut to "Walk".</p>
<div class="run" data-run="r2"></div>
<p class="prose">Song mapped (~115 BPM half-time, riff hits at 8.75 s); building the Linux release while I check the iOS footage.</p>
<div class="run" data-run="r3"></div>
<div class="run live" data-run="r4"></div>
</div>
<p class="foot">Hover a line (or focus it and press Enter, or tap on a phone) and the plate opens over the transcript without moving a row. The dot is the line's old status light; the glyph is the same light carrying <b>which zones the run lit</b>. History is drawn once and holds still; only the live run breathes.</p>
</main>
<div class="plate" id="plate" hidden><div class="plate-hd" id="plate-hd"></div><div class="plate-body" id="plate-body"></div><div class="plate-ft">hover a node · click pins it · esc closes</div></div>"""

c_css = """
.turn{border:1px solid var(--rule);border-radius:14px;background:var(--bg);padding:16px 18px 10px;position:relative}
.prompt{border-left:3px solid var(--accent);padding:2px 0 2px 14px;color:var(--ink);font-size:15px;line-height:1.55;margin-bottom:12px}
.prose{font:16px/1.5 ui-sans-serif,"Inter","Noto Sans",system-ui,sans-serif;color:var(--ink2);margin:10px 0}
.prose.pad{min-height:12px;margin:0}
.prose code{font:14px ui-monospace,"Noto Sans Mono",monospace;color:var(--info)}
.run{display:flex;align-items:center;gap:9px;height:24px;cursor:default;border-radius:6px;padding:0 4px;margin:0 -4px;color:var(--ink2);font-size:12.5px;white-space:nowrap}
.run:hover,.run.open{background:color-mix(in srgb,var(--accent) 7%,transparent)}
.run:focus-visible{outline:2px solid var(--accent);outline-offset:1px}
.run .chev{color:var(--ink3);font-size:11px;width:10px}
.run .cnt{color:var(--accent);font-weight:700}
.run .mix{color:var(--ink3)}
.run .dot{width:14px;display:none;text-align:center;color:var(--accent2);font-size:13px;line-height:1}
.run .dot.hollow{color:var(--info)}
.run .gl{width:34px}
.mode-today .run .dot{display:inline-block}
.mode-today .run .gl{display:none}
.run.live .dot{animation:swell 2.4s ease-in-out infinite}
.plate{position:absolute;z-index:20;width:540px;max-width:calc(100vw - 24px);background:var(--panel);border:1px solid var(--rule2);border-radius:14px;box-shadow:0 18px 50px rgba(0,0,0,.55);overflow:hidden}
.plate[hidden]{display:none}
.plate-hd{display:flex;align-items:center;gap:9px;padding:8px 12px;border-bottom:1px solid var(--rule);font-size:12.5px}
.plate-hd .cnt{color:var(--accent);font-weight:700}
.plate-hd .mix{color:var(--ink3)}
.plate-hd .dif .a{color:var(--accent)}
.plate-hd .dif .d{color:var(--danger)}
.plate-body{position:relative;padding:2px 6px 0;background:linear-gradient(180deg,var(--panel2),var(--panel))}
.plate-body .nv-svg{min-width:0}
.plate-ft{padding:6px 12px 8px;color:var(--ink3);font-size:10.5px;border-top:1px solid var(--rule)}
.plate .tip{width:270px}
.plate .num{font-size:12px}
.plate .zl{font-size:12px}
.plate .tipdot{r:4.5px}
@media (max-width:560px){.prompt{font-size:13px}.run{font-size:11.5px}}
"""

c_script = """
applyTheme();
const P=params();
const doc=document.getElementById('doc');
if(P.get('mode')==='today'){document.body.classList.add('mode-today');}
const mt=document.getElementById('m-today'),mb=document.getElementById('m-brain');
function setMode(today){document.body.classList.toggle('mode-today',today);mt.setAttribute('aria-pressed',today);mb.setAttribute('aria-pressed',!today);}
setMode(P.get('mode')==='today');
mt.onclick=()=>setMode(true);mb.onclick=()=>setMode(false);

const plate=document.getElementById('plate'),plateBody=document.getElementById('plate-body'),plateHd=document.getElementById('plate-hd');
let openRun=null,nv=null,closeTimer=0,openTimer=0,pinnedRun=null;

document.querySelectorAll('.run').forEach(el=>{
  const key=el.dataset.run,steps=DEMO_RUNS[key],live=el.classList.contains('live');
  const d=Neural.diffTally(steps);
  el.tabIndex=0;el.setAttribute('role','button');
  el.setAttribute('aria-label',`${Neural.toolCount(steps)} tools, ${Neural.toolMix(steps)}`);
  el.innerHTML=`<span class="chev">▸</span><span class="dot${live?' hollow':''}">${live?'◌':'●'}</span><span class="gl">${Neural.glyph(steps,{live,size:28})}</span><span class="cnt">${Neural.toolCount(steps)} tools</span><span class="mix">${Neural.toolMix(steps)}</span>`;
  el.addEventListener('pointerenter',()=>{clearTimeout(closeTimer);clearTimeout(openTimer);openTimer=setTimeout(()=>open(el,key,live),pinnedRun?0:140);});
  el.addEventListener('pointerleave',()=>{clearTimeout(openTimer);scheduleClose();});
  el.addEventListener('focus',()=>open(el,key,live));
  el.addEventListener('click',()=>{pinnedRun=pinnedRun===el?null:el;open(el,key,live);});
  el.addEventListener('keydown',ev=>{if(ev.key==='Enter'||ev.key===' '){ev.preventDefault();pinnedRun=pinnedRun===el?null:el;open(el,key,live);}if(ev.key==='Escape')close(true);});
});
plate.addEventListener('pointerenter',()=>clearTimeout(closeTimer));
plate.addEventListener('pointerleave',scheduleClose);
document.addEventListener('keydown',ev=>{if(ev.key==='Escape')close(true);});
document.addEventListener('click',ev=>{if(!plate.contains(ev.target)&&!ev.target.closest('.run'))close(true);});

function scheduleClose(){clearTimeout(closeTimer);if(pinnedRun)return;closeTimer=setTimeout(()=>close(false),250);}
function close(force){if(force)pinnedRun=null;plate.hidden=true;if(openRun)openRun.classList.remove('open');openRun=null;}
function open(el,key,live){
  if(openRun===el&&!plate.hidden)return;
  if(openRun)openRun.classList.remove('open');
  openRun=el;el.classList.add('open');
  const steps=DEMO_RUNS[key],d=Neural.diffTally(steps);
  plateHd.innerHTML=`<span class="gl">${Neural.glyph(steps,{live})}</span><span class="cnt">${Neural.toolCount(steps)} tools</span><span class="mix">${Neural.toolMix(steps)}</span>`+(d[0]||d[1]?`<span class="dif"><span class="a">+${d[0]}</span> <span class="d">−${d[1]}</span></span>`:'');
  plate.hidden=false;
  nv=Neural.mount(plateBody,{steps,layout:'cortex',live,eye:live?'live':'done',r:15,spacing:37,label:`${key} steps`});
  const er=el.getBoundingClientRect(),dr=doc.getBoundingClientRect(),pw=plate.offsetWidth,ph=plate.offsetHeight;
  let x=er.left-dr.left+34;
  x=Math.max(8,Math.min(x,dr.width-pw-8));
  let y=er.bottom-dr.top+6;
  if(er.bottom+ph+16>window.innerHeight&&er.top-ph-16>0) y=er.top-dr.top-ph-6;
  plate.style.left=x+'px';plate.style.top=y+'px';
  if(P.get('replay')==='1')nv.play();
  const hv=P.get('hover');
  if(hv!==null&&P.get('run')===key)nv.setHot(parseInt(hv,10)-1);
}
plate.style.position='absolute';
doc.style.position='relative';
doc.appendChild(plate);
const want=P.get('open');
if(want){const el=document.querySelector(`.run[data-run="${want}"]`);if(el){pinnedRun=el;open(el,want,el.classList.contains('live'));}}
"""

(out / "C.html").write_text(
    f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>C · In the transcript</title>
<style>{css}{PAGE_CSS}{c_css}</style></head>
<body>
{c_body}
<script>{data}{engine}{LEGEND_JS}{c_script}</script>
</body></html>
"""
)
print("built", [p.name for p in out.glob("*.html")])

d_body = """<main class="page" id="doc">
<header class="bar"><span class="eyebrow">D · THE WHOLE TURN</span>
<div class="tools"><button id="s-live" type="button" aria-pressed="false">Live</button><button id="s-done" type="button" aria-pressed="true">Done</button><button id="s-line" type="button" aria-pressed="false">Collapsed</button><button id="s-big" type="button" aria-pressed="false">Long turn</button></div></header>
<div class="turn">
<div class="prompt">Make a product demonstration using mock data but the real apps .mp4 i can share on twitter. use /mnt/nvme8tb/Music/Pantera-The_Complete_Albums_1990-2000-24BIT-REMASTERED-WEB-FLAC-2016-RUIDOS/203-pantera-walk.flac as the background track starting from the beginning and playing for how long the demo video is.</div>
<section class="work" id="work">
<button class="wline" id="wline" type="button" aria-expanded="true"><span class="chev" id="chev">▾</span><span class="gl" id="wgl"></span><span class="cnt" id="wcnt"></span><span class="mix" id="wmix"></span><span class="dif" id="wdif"></span><span class="rows" id="rows" role="button" tabindex="0">Rows</span></button>
<div class="wbody" id="wbody">
<div class="hero" id="hero"></div>
<ol class="steps all" id="steps" aria-label="Every step" hidden></ol>
<div class="ticker" id="ticker" aria-live="polite"></div>
<ul class="legend" id="legend"></ul>
</div>
</section>
<article class="answer" id="answer"></article>
</div>
<p class="foot">Everything before the final message is one brain: the thoughts, every tool and the notes the agent wrote on the way. While it works the latest note replaces itself on one line under the brain, then the answer streams onto the empty page below. Afterwards the brain collapses to the single line at the top of the card; older turns stay collapsed.</p>
</main>"""

d_css = """
.turn{border:1px solid var(--rule);border-radius:14px;background:var(--bg);padding:16px 18px 14px}
.prompt{border-left:3px solid var(--accent);padding:2px 0 2px 14px;color:var(--ink);font-size:15px;line-height:1.55;margin-bottom:14px}
.work{border:1px solid var(--rule);border-radius:14px;background:linear-gradient(180deg,var(--panel),var(--bg));overflow:hidden;transition:none}
.wline{display:flex;align-items:center;gap:10px;width:100%;padding:8px 14px;background:none;border:0;border-bottom:1px solid var(--rule);border-radius:0;color:var(--ink2);font:inherit;font-size:12.5px;cursor:pointer;text-align:left;white-space:nowrap;overflow:hidden}
.wline:hover{background:color-mix(in srgb,var(--accent) 5%,transparent)}
.wline .chev{color:var(--ink3);font-size:11px;width:10px}
.wline .gl{width:34px}
.wline .cnt{color:var(--accent);font-weight:700}
.wline .mix{color:var(--ink3);overflow:hidden;text-overflow:ellipsis}
.wline .dif .a{color:var(--accent)}
.wline .dif .d{color:var(--danger)}
.wline .rows{margin-left:auto;padding:2px 9px;border:1px solid var(--rule2);border-radius:99px;color:var(--ink2);font-size:11px}
.wline .rows:hover,.wline .rows[aria-pressed="true"]{border-color:var(--accent);color:var(--accent)}
.work.collapsed{border-color:transparent;background:none}
.work.collapsed .wline{border-bottom:0;padding:2px 0;height:24px}
.work.collapsed .wbody{display:none}
.hero{position:relative;padding:4px 10px 0}
.hero .nv-svg{min-width:0;max-width:820px;margin:0 auto}
.ticker{display:flex;align-items:center;gap:9px;min-height:30px;padding:2px 18px 6px;color:var(--ink2);font:15px/1.4 ui-sans-serif,"Inter","Noto Sans",system-ui,sans-serif}
.ticker:empty{min-height:8px}
.ticker .tk{width:7px;height:7px;border-radius:50%;background:var(--accent);flex:none;animation:swell 2.4s ease-in-out infinite}
.ticker .tx{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.work .legend{padding:0 18px 12px;margin:0}
.steps.all{display:flex;flex-direction:column;padding:8px 12px 4px;margin:0}
.steps.all[hidden]{display:none}
.answer{font:16px/1.65 ui-sans-serif,"Inter","Noto Sans",system-ui,sans-serif;color:var(--ink);margin:16px 0 0;min-height:150px}
.answer p{margin:0 0 12px}
.answer .w{opacity:1}
.answer.hold .w{opacity:0}
@media (max-width:560px){.prompt{font-size:13px}.wline .mix{display:none}.work .legend{display:none}}
@media (prefers-reduced-motion:reduce){.ticker .tk{animation:none}}
"""

d_script = """
applyTheme();
const P=params();
let steps=TURN,nv=null,raf=0,big=false,streamTimer=0;
const work=document.getElementById('work'),hero=document.getElementById('hero'),ticker=document.getElementById('ticker'),answer=document.getElementById('answer'),rowsEl=document.getElementById('rows'),stepsEl=document.getElementById('steps');
const reduce=window.matchMedia&&matchMedia('(prefers-reduced-motion: reduce)').matches;
legend(document.getElementById('legend'));

answer.innerHTML=TURN_ANSWER.map(p=>'<p>'+p.split(' ').map(w=>'<span class="w">'+w.replace(/</g,'&lt;')+'</span>').join(' ')+'</p>').join('');
const words=[...answer.querySelectorAll('.w')];

function secs(a){const p=a.split(':').map(Number);return p[0]*3600+p[1]*60+p[2];}
function summary(){
  const d=secs(steps[0].at)-0;
  const span=big?1860:secs(steps[steps.length-1].at)-secs(steps[0].at);
  const m=Math.floor(span/60),s=String(span%60).padStart(2,'0');
  const think=steps.filter(x=>x.fam==='think').length,say=steps.filter(x=>x.fam==='say').length,dif=Neural.diffTally(steps);
  document.getElementById('wcnt').textContent=Neural.toolCount(steps)+' tools';
  document.getElementById('wmix').textContent=`${m}m ${s}s · ${think} thoughts · ${say} notes`;
  document.getElementById('wdif').innerHTML=dif[0]||dif[1]?`<span class="a">+${dif[0]}</span> <span class="d">−${dif[1]}</span>`:'';
  document.getElementById('wgl').innerHTML=Neural.glyph(steps,{size:28});
}
function mountBrain(){
  const groups=new Set(steps.map(s=>s.msg)).size;
  nv=Neural.mount(hero,{steps,layout:'cortex',say:true,r:big?7:9,spacing:big?21:25,step:Math.min(0.42,16/groups),eye:'done',label:'Everything the agent did before answering'});
  Neural.stepList?0:0;
  stepList(stepsEl,steps,nv);
  summary();
}
function showAnswer(n){words.forEach((w,i)=>{w.style.opacity=i<n?1:0;});}
function stopAll(){cancelAnimationFrame(raf);clearInterval(streamTimer);ticker.innerHTML='';}
function setPressed(id){['s-live','s-done','s-line'].forEach(k=>document.getElementById(k).setAttribute('aria-pressed',k===id));}
function setCollapsed(c){work.classList.toggle('collapsed',c);document.getElementById('chev').textContent=c?'▸':'▾';document.getElementById('wline').setAttribute('aria-expanded',!c);}
function done(){stopAll();setCollapsed(false);nv.settle();showAnswer(words.length);setPressed('s-done');}
function line(){stopAll();setCollapsed(true);showAnswer(words.length);setPressed('s-line');}
function streamAnswer(){
  let n=0;showAnswer(0);
  streamTimer=setInterval(()=>{n+=2;showAnswer(n);if(n>=words.length)clearInterval(streamTimer);},60);
}
function live(){
  stopAll();setCollapsed(false);setPressed('s-live');showAnswer(0);
  if(reduce){nv.settle();showAnswer(words.length);return;}
  const says=steps.map((s,i)=>({i,s})).filter(x=>x.s.fam==='say');
  const t0=performance.now();
  function frame(now){
    const t=(now-t0)/1000;
    nv.paint(t);
    let cap='Thinking…';
    says.forEach(x=>{if(t>=nv.fire[x.i])cap=x.s.text;});
    if(ticker.dataset.cap!==cap){ticker.dataset.cap=cap;ticker.innerHTML='<span class="tk"></span><span class="tx"></span>';ticker.querySelector('.tx').textContent=cap;}
    if(t<nv.endT+0.3){raf=requestAnimationFrame(frame);}
    else{nv.settle();ticker.innerHTML='';ticker.dataset.cap='';streamAnswer();}
  }
  raf=requestAnimationFrame(frame);
}
function rebuild(){stopAll();hero.querySelectorAll('.nv-svg,.tip').forEach(n=>n.remove());mountBrain();}

document.getElementById('s-live').onclick=live;
document.getElementById('s-done').onclick=done;
document.getElementById('s-line').onclick=line;
document.getElementById('s-big').onclick=function(){big=!big;this.setAttribute('aria-pressed',big);steps=big?TURN_BIG:TURN;rebuild();done();};
document.getElementById('wline').addEventListener('click',ev=>{if(ev.target===rowsEl)return;stopAll();setCollapsed(!work.classList.contains('collapsed'));showAnswer(words.length);setPressed(work.classList.contains('collapsed')?'s-line':'s-done');});
function toggleRows(ev){ev.stopPropagation();const on=stepsEl.hidden;stepsEl.hidden=!on;hero.hidden=on;rowsEl.setAttribute('aria-pressed',on);}
rowsEl.addEventListener('click',toggleRows);
rowsEl.addEventListener('keydown',ev=>{if(ev.key==='Enter'||ev.key===' '){ev.preventDefault();toggleRows(ev);}});

if(P.get('big')==='1'){big=true;steps=TURN_BIG;document.getElementById('s-big').setAttribute('aria-pressed',true);}
mountBrain();
const st=P.get('state');
if(st==='line')line();
else if(st==='live'){live();if(P.get('t')!==null){cancelAnimationFrame(raf);nv.paint(parseFloat(P.get('t')));showAnswer(0);const cap=steps.filter((s,i)=>s.fam==='say'&&nv.fire[i]<=parseFloat(P.get('t'))).pop();ticker.innerHTML='<span class="tk"></span><span class="tx"></span>';ticker.querySelector('.tx').textContent=cap?cap.text:'Thinking…';}}
else done();
if(P.get('hover')==='gang'&&nv.leaders.length)nv.setHot(nv.leaders[0]);
else if(P.get('hover')!==null)nv.setHot(parseInt(P.get('hover'),10)-1);
if(P.get('rows')==='1')toggleRows({stopPropagation(){}});
"""

(out / "D.html").write_text(
    f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>D · The whole turn</title>
<style>{css}{PAGE_CSS}{d_css}</style></head>
<body>
{d_body}
<script>{data}{engine}{LEGEND_JS}{d_script}</script>
</body></html>
"""
)
print("built D")

import base64, io, os
from PIL import Image

LDIR = Path(os.environ.get("LDIR", str(here.parent / "blender" / "out" / "L2")))
NEST = Path(os.environ.get("NEST", str(here.parent / "blender" / "out" / "nest.png")))


def data_uri(path, lossless):
    im = Image.open(path)
    if im.mode not in ("RGB", "RGBA"):
        im = im.convert("RGB")
    if im.mode == "I;16":
        im = im.convert("RGB")
    buf = io.BytesIO()
    if lossless:
        im.save(buf, "WEBP", lossless=True, quality=100, method=6)
    else:
        im.save(buf, "WEBP", quality=88, method=6, alpha_quality=100)
    return "data:image/webp;base64," + base64.b64encode(buf.getvalue()).decode()


def e_assets():
    a = {}
    for k in ("chassis", "interior", "glass"):
        a[k] = data_uri(LDIR / f"{k}.png", False)
    for k in ("mask_i1", "mask_i2", "mask_i3", "mask_c", "mask_d"):
        a[k] = data_uri(LDIR / f"{k}.png", True)
    for k in ("bloom_i1", "bloom_i2", "bloom_i3", "bloom_c", "bloom_d"):
        a[k] = data_uri(LDIR / f"{k}.png", True)
    return a


e_body = """<main class="page" id="doc">
<header class="bar"><span class="eyebrow">E · THE HERO</span>
<div class="tools"><button class="th" data-t="matrix" aria-pressed="true">Matrix</button><button class="th" data-t="rose" aria-pressed="false">Rosé Pine</button><button class="th" data-t="tokyo" aria-pressed="false">Tokyo Night</button></div></header>
<div class="bar sub"><div class="tools"><button id="m-idle" aria-pressed="true">At rest</button><button id="m-work" aria-pressed="false">Working</button><button id="m-done" aria-pressed="false">Done</button></div><div class="crumb" id="crumb"></div></div>
<section class="hstage" id="stage">
<div class="inner" id="inner"><canvas id="cInt"></canvas><img id="nest" alt=""></div>
<div class="nodes" id="nodes"></div>
<canvas id="cFront"></canvas>
<div class="hint" id="hint">hover a node · click a zone name to dive · double-click the Task node to go into the subagent · esc surfaces</div>
</section>
<div class="perf" id="perf"></div>
<ul class="legend" id="legend"></ul>
<p class="foot">Rendered once in Blender, drawn by a shader. Eleven textures carry the whole look: the chassis, the interior and the dome's glass, four masks that say where each zone, the fibres, the stars, the seams and the eye glow, and their bloom. The shader tints the masks from the theme's own slots, so one asset serves every theme and every state; the bloom is a pre-blurred quarter-size copy of each mask, two more lookups. At rest it draws once and then draws nothing. The nodes live between the interior and the glass, so they sit inside the dome.</p>
</main>"""

e_css = """
.sub{margin-top:-4px}
.crumb{color:var(--ink2);font-size:12px}
.crumb b{color:var(--accent);font-weight:600}
.hstage{position:relative;max-width:980px;margin:0 auto;aspect-ratio:640/420;border-radius:18px;overflow:hidden;background:var(--bg);border:1px solid var(--rule)}
.hstage canvas{position:absolute;inset:0;width:100%;height:100%;display:block}
.inner{position:absolute;inset:0;z-index:1;will-change:transform}
.inner canvas{z-index:0}
.inner img{position:absolute;opacity:0;pointer-events:none;transition:opacity .25s}
.nodes{position:absolute;inset:0;z-index:auto}
.nodes .nv-svg{position:absolute;inset:0;width:100%;height:100%;min-width:0;z-index:2;will-change:transform}
.nodes .tip{z-index:6}
#cFront{z-index:3;pointer-events:none}
.hint{position:absolute;left:14px;bottom:10px;z-index:7;color:var(--ink3);font-size:10.5px;letter-spacing:.02em;pointer-events:none}
.zl{cursor:pointer;pointer-events:all}
.zl:hover{fill:var(--ink)}
.perf{max-width:980px;margin:10px auto 0;color:var(--ink3);font-size:11px;display:flex;flex-wrap:wrap;gap:4px 18px}
.perf b{color:var(--ink2);font-weight:600}
.perf .live{color:var(--accent)}
.legend{max-width:980px;margin-left:auto;margin-right:auto}
.foot{max-width:980px;margin-left:auto;margin-right:auto}
@media (max-width:560px){.hint{display:none}.nodes .tip.dock{position:absolute;left:8px;right:8px;bottom:8px;top:auto;width:auto;margin:0}}
"""

e_script = """
const P=params();
const stage=document.getElementById('stage'),inner=document.getElementById('inner'),nodesHost=document.getElementById('nodes'),nest=document.getElementById('nest'),crumb=document.getElementById('crumb'),perf=document.getElementById('perf');
legend(document.getElementById('legend'));
let hero=null,nv=null,steps=TURN,mode='idle',themeKey='matrix',dive={s:1,to:1,from:1,t0:0,dur:0,cen:[320,210]},hotZone=null,raf=0,t0=performance.now(),workStart=0,sub=false,lastFrame=0,fps=0,loopRunning=false;
const ZC=Neural.ZONES;
const ZI={think:0,sense:1,act:2,shell:3,delegate:4,say:5};
const reduce=window.matchMedia&&matchMedia('(prefers-reduced-motion: reduce)').matches;
function clamp(v,a,b){return Math.max(a,Math.min(b,v));}
function ease(t){return t<.5?4*t*t*t:1-Math.pow(-2*t+2,3)/2;}

function applyTheme(k){
  themeKey=k;if(hero)hero.st.theme=k;const th=Hero.THEMES[k];const r=document.documentElement.style;
  r.setProperty('--bg',th.bg);r.setProperty('--panel',th.bg);r.setProperty('--ink',th.ink);r.setProperty('--ink2',th.ink2);r.setProperty('--ink3',th.ink2+'99');
  r.setProperty('--accent',th.accent);r.setProperty('--accent2',th.accent);r.setProperty('--info',th.info);r.setProperty('--special',th.special);r.setProperty('--danger',th.danger);r.setProperty('--rule2',th.ink2+'55');r.setProperty('--rule',th.ink2+'33');
  document.querySelectorAll('.th').forEach(b=>b.setAttribute('aria-pressed',b.dataset.t===k));
  stageTheme(stage,th);
  request();
}

function mountNodes(list){
  steps=list;
  nodesHost.querySelectorAll('.nv-svg,.tip').forEach(n=>n.remove());
  const groups=new Set(list.map(s=>s.msg)).size;
  nv=Neural.mount(nodesHost,{steps:list,layout:'cortex',bare:true,say:true,r:10,spacing:{def:28,say:24},step:Math.min(.5,14/groups),eye:'done',label:'Everything the agent did before answering',onHot:(s)=>{hotZone=s?s.fam:null;request();}});
  const svg=nodesHost.querySelector('.nv-svg');
  svg.style.transformOrigin='50% 50%';
  svg.querySelectorAll('.zl').forEach(t=>{t.setAttribute('tabindex','0');t.setAttribute('role','button');t.addEventListener('click',()=>diveTo(t.dataset.zone));t.addEventListener('keydown',e=>{if(e.key==='Enter')diveTo(t.dataset.zone);});});
  list.forEach((s,i)=>{if(s.tool==='Task'){svg.querySelectorAll('.n')[i].addEventListener('dblclick',()=>enterSub());}});
  nv.settle();
  applyDive();
}
function crumbs(){crumb.innerHTML=sub?'<b>Turn</b> › reviewer · '+Neural.toolCount(SUB)+' tools':'';}

function setPressed(id){['m-idle','m-work','m-done'].forEach(k=>document.getElementById(k).setAttribute('aria-pressed',k===id));}
function setMode(m){
  mode=m;setPressed({idle:'m-idle',working:'m-work',done:'m-done'}[m]);
  if(m==='working'){workStart=performance.now();} else {nv.settle();}
  request();
}
function applyDive(){
  const s=dive.s,c=dive.cen;const cx=c[0]/640,cy=c[1]/420;
  inner.style.transformOrigin=(cx*100)+'% '+(cy*100)+'%';inner.style.transform='scale('+s+')';
  const svg=nodesHost.querySelector('.nv-svg');if(svg){svg.style.transformOrigin=(cx*100)+'% '+(cy*100)+'%';svg.style.transform='scale('+s+')';}
  if(hero){hero.st.cen=[cx,1-cy];hero.st.sc=1+(s-1)*1.7;hero.st.sg=1+(s-1)*1.25;hero.st.fade=clamp(1-(s-1.5)/1.1,0,1);}
}
function diveTo(zone,s2){
  const c=ZC[zone];dive.cen=[c[0],c[1]];startDive(dive.s,s2||(zone==='say'?3.4:2.6),520);
}
function surface(){startDive(dive.s,1,480);}
function startDive(from,to,dur){dive.from=from;dive.to=to;dive.t0=performance.now();dive.dur=reduce?1:dur;request();}
function stepDive(now){
  if(dive.dur===0)return false;
  const t=clamp((now-dive.t0)/dive.dur,0,1);dive.s=dive.from+(dive.to-dive.from)*ease(t);
  if(t>=1){dive.dur=0;dive.s=dive.to;}
  applyDive();
  const nestOn=dive.cen===nestCen&&dive.s>2.0;nest.style.opacity=nestOn?1:0;
  return dive.dur!==0;
}
let nestCen=null;
function enterSub(){
  if(sub)return;
  const c=ZC.delegate;dive.cen=[c[0],c[1]];nestCen=dive.cen;
  nest.style.opacity=0;
  startDive(dive.s,3.33,900);
  setTimeout(()=>{sub=true;dive.cen=[320,210];dive.dur=0;dive.s=1;nest.style.opacity=0;mountNodes(SUB);crumbs();setMode('done');request();},reduce?10:960);
}
function exitSub(){if(!sub)return;sub=false;dive.cen=[320,210];dive.dur=0;dive.s=1;mountNodes(TURN);crumbs();setMode('done');}
document.addEventListener('keydown',e=>{if(e.key==='Escape'){if(sub)exitSub();else surface();}});
crumb.addEventListener('click',()=>exitSub());

function targets(now){
  const base=Array(10).fill(.5);base[6]=.55;base[7]=.6;base[8]=.3;base[9]=.5;
  let act=null;
  if(mode==='working'){
    const t=(now-workStart)/1000;
    let a=-1;steps.forEach((s,i)=>{if(nv.fire[i]<=t)a=i;});
    act=a>=0?steps[a].fam:null;
    if(t>nv.endT+.3){mode='done';nv.settle();setPressed('m-done');}
    nv.paint(t);
    for(let i=0;i<6;i++)base[i]=.32;
    if(act)base[ZI[act]]=1.05+.2*Math.sin(t*5.2);
    base[9]=.55+.45*(.5+.5*Math.sin(t*2.6));
    hero.st.ripple=1;hero.st.time=t;if(act){const c=ZC[act];hero.st.act=[c[0]/640,1-c[1]/420];}
  }else{hero.st.ripple=0;if(mode==='done')base[9]=.7;}
  if(hotZone&&mode!=='working'){for(let i=0;i<6;i++)base[i]=.3;base[ZI[hotZone]]=1.2;base[6]=.6;}
  return base;
}
function frame(now){
  raf=0;
  const tg=targets(now);let moving=mode==='working';
  const inten=hero.st.inten;
  for(let i=0;i<10;i++){const d=tg[i]-inten[i];if(Math.abs(d)>.004){inten[i]+=d*.18;moving=true;}else inten[i]=tg[i];}
  const diving=stepDive(now);
  hero.draw();
  const dt=now-lastFrame;if(dt>0&&dt<500)fps=fps*.8+(1000/dt)*.2;lastFrame=now;
  loopRunning=moving||diving;
  if(loopRunning)raf=requestAnimationFrame(frame);else{fps=0;}
  renderPerf();
}
function request(){if(!hero)return;if(!raf){lastFrame=performance.now();raf=requestAnimationFrame(frame);}}
function renderPerf(){
  perf.innerHTML=`<span><b>11</b> textures · ${hero.W}×${hero.H}</span><span>decoded <b>${(hero.bytes/1048576).toFixed(1)} MB</b> · ≈${(hero.bytes/1048576/8).toFixed(1)} MB as ASTC</span><span>frames drawn <b>${hero.st.frames}</b></span><span class="${loopRunning?'live':''}">${loopRunning?'drawing · '+Math.round(fps)+' fps':'idle · draws nothing'}</span><span>last submit <b>${(hero.st.cost||0).toFixed(2)} ms</b> (this machine, software GL)</span>`;
}

(async function(){
  try{
    hero=await Hero.create({assets:ASSETS,interior:document.getElementById('cInt'),front:document.getElementById('cFront')});
  }catch(e){stage.insertAdjacentHTML('beforeend','<div style="position:absolute;inset:0;display:grid;place-items:center;color:var(--ink2)">WebGL2 is needed to draw this artboard: '+String(e.message).replace(/</g,'&lt;')+'</div>');return;}
  nest.src=NEST_IMG;nest.style.left=(ZC.delegate[0]/640*100-15)+'%';nest.style.top=(ZC.delegate[1]/420*100-15)+'%';nest.style.width='30%';
  mountNodes(TURN);applyTheme(P.get('theme')||'matrix');crumbs();
  document.querySelectorAll('.th').forEach(b=>b.onclick=()=>applyTheme(b.dataset.t));
  document.getElementById('m-idle').onclick=()=>{setMode('idle');};
  document.getElementById('m-work').onclick=()=>{nv.settle();setMode('working');};
  document.getElementById('m-done').onclick=()=>{setMode('done');};
  if(P.get('mode')==='done')setMode('done');
  if(P.get('mode')==='working'){setMode('working');if(P.get('t')!==null){workStart=performance.now()-parseFloat(P.get('t'))*1000;}}
  if(P.get('dive')){const z=P.get('dive');dive.cen=[ZC[z][0],ZC[z][1]];dive.s=parseFloat(P.get('s')||'2.4');dive.dur=0;applyDive();}
  if(P.get('sub')==='1'){sub=true;mountNodes(SUB);crumbs();}
  if(P.get('hover')!==null)nv.setHot(parseInt(P.get('hover'),10)-1);
  request();renderPerf();window.__hero=hero;window.__heroReady=true;
})();
"""

try:
    assets = e_assets()
    nest_uri = data_uri(NEST, False) if NEST.exists() else ""
    (out / "E.html").write_text(
        f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>E · The hero</title>
<style>{css}{PAGE_CSS}{e_css}</style></head>
<body>
{e_body}
<script>const ASSETS={json.dumps(assets)};const NEST_IMG={json.dumps(nest_uri)};{data}{engine}{(here / 'hero2.js').read_text()}{LEGEND_JS}{e_script}</script>
</body></html>
"""
    )
    print("built E", (out / "E.html").stat().st_size // 1024, "KB")
except FileNotFoundError as ex:
    print("E skipped:", ex)


f_body = """<main class="page fpage">
<div class="ctl">
<div class="tools"><button class="th" data-t="matrix" aria-pressed="true">Matrix</button><button class="th" data-t="rose" aria-pressed="false">Rosé Pine</button><button class="th" data-t="tokyo" aria-pressed="false">Tokyo Night</button></div>
<div class="tools"><button id="s-live" aria-pressed="false">Live</button><button id="s-done" aria-pressed="true">Done</button><button id="s-line" aria-pressed="false">Collapsed</button></div>
<div class="tools"><button id="w-desk" aria-pressed="true">Desktop</button><button id="w-phone" aria-pressed="false">Phone</button></div>
</div>
<div class="chat" id="chat">
<header class="chead"><span class="hamb">≡</span><span class="ttl">Make a product demonstration using mock data…</span><span class="status" id="status"></span></header>
<div class="cbody" id="cbody"></div>
<footer class="composer"><div class="cin">Message the agent</div><span class="mpill"><i class="dot"></i><span class="bars"><b></b><b></b><b></b><b class="off"></b><b class="off"></b></span></span><span class="send">↑</span></footer>
</div>
<div class="perf" id="perf"></div>
<p class="foot">The layout of a conversation with the brain. Older turns are one line each (the glyph, the count, how long, what changed); only one brain is ever open, and opening another closes the first, so a long chat holds one pair of canvases. The latest turn opens while it works, then settles under its question with the answer below, and collapses to its line whenever you want the page back. The header's status line says what is happening, the dock stays for questions, and the composer is untouched.</p>
</main>"""

f_css = """
.fpage{max-width:1180px}
.ctl{display:flex;flex-wrap:wrap;gap:10px 22px;justify-content:space-between;margin-bottom:14px}
.chat{margin:0 auto;max-width:860px;border:1px solid var(--rule);border-radius:18px;background:var(--bg);overflow:hidden;transition:max-width .25s}
.chat.phone{max-width:390px}
.chead{display:flex;align-items:center;gap:12px;padding:10px 16px;border-bottom:1px solid var(--rule);color:var(--ink2);font-size:12.5px}
.chead .hamb{color:var(--ink3);font-size:16px}
.chead .ttl{flex:1;text-align:center;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;color:var(--ink3)}
.chead .status{min-width:150px;text-align:right;color:var(--ink2);white-space:nowrap;overflow:hidden;text-overflow:ellipsis;max-width:34%}
.chat.phone .chead .status{display:none}
.chead .status .sd{display:inline-block;width:7px;height:7px;border-radius:50%;background:var(--accent);margin-right:7px;vertical-align:1px}
.chead .status.live .sd{animation:swell 2.4s ease-in-out infinite}
.cbody{padding:18px 20px 8px}
.chat.phone .cbody{padding:14px 12px 6px}
.turn{margin-bottom:22px}
.prompt{border-left:3px solid var(--accent);padding:2px 0 2px 14px;color:var(--ink);font-size:14.5px;line-height:1.55;margin-bottom:10px}
.chat.phone .prompt{font-size:13px}
.work{margin:2px 0 8px}
.wline{display:flex;align-items:center;gap:10px;width:100%;padding:3px 4px;margin:0 -4px;background:none;border:0;border-radius:7px;color:var(--ink2);font:inherit;font-size:12.5px;cursor:pointer;text-align:left;white-space:nowrap;overflow:hidden}
.wline:hover{background:color-mix(in srgb,var(--accent) 7%,transparent)}
.wline .chev{color:var(--ink3);font-size:11px;width:10px}
.wline .gl{width:34px}
.wline .cnt{color:var(--accent);font-weight:700}
.wline .mix{color:var(--ink3);overflow:hidden;text-overflow:ellipsis}
.wline .dif .a{color:var(--accent)}
.wline .dif .d{color:var(--danger)}
.wline .rows{margin-left:auto;padding:1px 9px;border:1px solid var(--rule2);border-radius:99px;color:var(--ink2);font-size:11px}
.wline .rows:hover,.wline .rows[aria-pressed="true"]{border-color:var(--accent);color:var(--accent)}
.chat.phone .wline .mix{display:none}
.work.open{border:1px solid var(--rule);border-radius:14px;background:linear-gradient(180deg,var(--panel),var(--bg));overflow:hidden;margin:6px 0 10px}
.work.open .wline{margin:0;border-radius:0;padding:8px 14px;border-bottom:1px solid var(--rule);width:100%}
.wbody{display:none}
.work.open .wbody{display:block}
.rowsl{list-style:none;margin:0;padding:6px 8px;display:none;flex-direction:column;gap:2px}
.rowsl.show{display:flex}
.rowsl li{display:flex;align-items:center;gap:9px;padding:3px 6px;font-size:11.5px;color:var(--ink3);white-space:nowrap;overflow:hidden}
.rowsl .no{min-width:18px}
.rowsl .tl{color:var(--ink)}
.rowsl .tl.bad{color:var(--danger)}
.rowsl .ar{overflow:hidden;text-overflow:ellipsis}
.hstage{position:relative;margin:0;aspect-ratio:640/420;overflow:hidden;background:var(--bg)}
.hstage canvas{position:absolute;inset:0;width:100%;height:100%;display:block}
.inner{position:absolute;inset:0;z-index:1;will-change:transform}
.nodes{position:absolute;inset:0;z-index:auto}
.nodes .nv-svg{position:absolute;inset:0;width:100%;height:100%;min-width:0;z-index:2;will-change:transform}
.nodes .tip{z-index:6}
#cFront{z-index:3;pointer-events:none}
.zl{cursor:pointer;pointer-events:all}
.ticker{display:flex;align-items:center;gap:9px;min-height:28px;padding:2px 16px 8px;color:var(--ink2);font:14px/1.4 ui-sans-serif,"Inter","Noto Sans",system-ui,sans-serif}
.ticker:empty{min-height:6px}
.ticker .tk{width:7px;height:7px;border-radius:50%;background:var(--accent);flex:none;animation:swell 2.4s ease-in-out infinite}
.ticker .tx{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.answer{font:15.5px/1.65 ui-sans-serif,"Inter","Noto Sans",system-ui,sans-serif;color:var(--ink);margin:12px 0 0}
.answer p{margin:0 0 10px}
.composer{display:flex;align-items:center;gap:10px;padding:10px 14px 14px}
.cin{flex:1;border:1px solid var(--rule2);border-radius:99px;padding:9px 16px;color:var(--ink3);font-size:13px;background:var(--panel)}
.mpill{display:inline-flex;align-items:center;gap:7px;border:1px solid var(--rule2);border-radius:99px;padding:7px 11px;background:var(--panel)}
.mpill .dot{width:9px;height:9px;border-radius:50%;background:var(--info)}
.mpill .bars{display:inline-flex;gap:2px;align-items:flex-end}
.mpill .bars b{display:block;width:3px;background:var(--accent);border-radius:1px}
.mpill .bars b:nth-child(1){height:5px}.mpill .bars b:nth-child(2){height:7px}.mpill .bars b:nth-child(3){height:9px}.mpill .bars b:nth-child(4){height:11px}.mpill .bars b:nth-child(5){height:13px}
.mpill .bars b.off{opacity:.25}
.send{width:34px;height:34px;border-radius:50%;display:grid;place-items:center;background:var(--accent);color:var(--bg);font-weight:700}
.chat.phone .mpill{display:none}
.perf{max-width:860px;margin:10px auto 0;color:var(--ink3);font-size:11px;display:flex;flex-wrap:wrap;gap:4px 18px}
.perf b{color:var(--ink2);font-weight:600}
.perf .live{color:var(--accent)}
.foot{max-width:860px;margin-left:auto;margin-right:auto}
.nodes .tip.dock{position:absolute;left:8px;right:8px;bottom:8px;top:auto;width:auto;margin:0}
"""

f_script = """
const P=params();
const ZC=Neural.ZONES,ZI={think:0,sense:1,act:2,shell:3,delegate:4,say:5};
const TURNS=[
 {prompt:'Fix the Linux build: it stops in TranscriptRows.',steps:BUILD_FIX,dur:'6m 29s',answer:['Fixed. The build stopped on two switches that did not answer the new Compaction and Note cases. Both do now, the Mac manifest answers the same capability, and the parity check reports no gaps.','Tailscode 1.79 is installed on this machine (pid 41872).']},
 {prompt:'Is the frames CLI ready for the screenshots?',steps:DEMO_RUNS.r3,dur:'1m 12s',answer:['Yes. frames 0.9.2 finds its bezels, and the tour footage is 2622×1206 at 60 fps, which fits the iPhone frame without scaling.']},
 {prompt:'Make a product demonstration using mock data but the real apps .mp4 i can share on twitter. use /mnt/nvme8tb/Music/Pantera-The_Complete_Albums_1990-2000-24BIT-REMASTERED-WEB-FLAC-2016-RUIDOS/203-pantera-walk.flac as the background track starting from the beginning and playing for how long the demo video is.',steps:TURN,dur:'8m 25s',answer:TURN_ANSWER}
];
const body=document.getElementById('cbody'),chat=document.getElementById('chat'),statusEl=document.getElementById('status'),perf=document.getElementById('perf');
const reduce=window.matchMedia&&matchMedia('(prefers-reduced-motion: reduce)').matches;
let hero=null,nv=null,openIdx=-1,mode='done',themeKey='matrix',hotZone=null,raf=0,workStart=0,fps=0,lastFrame=0,loopRunning=false,streamTimer=0,stage=null,nodesHost=null,tickerEl=null;
const dive={s:1,cen:[320,210]};
function clamp(v,a,b){return Math.max(a,Math.min(b,v));}

function sumLine(t){
  const st=t.steps,d=Neural.diffTally(st),fails=st.filter(s=>s.status==='fail').length;
  const think=st.filter(s=>s.fam==='think').length,say=st.filter(s=>s.fam==='say').length;
  return {cnt:Neural.toolCount(st)+' tools',mix:t.dur+(think?' · '+think+' thought'+(think>1?'s':''):'')+(say?' · '+say+' note'+(say>1?'s':''):'')+(fails?' · '+fails+' failed, then passed':''),dif:d[0]||d[1]?`<span class="a">+${d[0]}</span> <span class="d">−${d[1]}</span>`:''};
}
TURNS.forEach((t,i)=>{
  const s=sumLine(t),el=document.createElement('section');el.className='turn';el.dataset.i=i;
  el.innerHTML=`<div class="prompt"></div><div class="work" id="work${i}"><button class="wline" type="button"><span class="chev">▸</span><span class="gl">${Neural.glyph(t.steps,{size:28})}</span><span class="cnt">${s.cnt}</span><span class="mix">${s.mix}</span><span class="dif">${s.dif}</span><span class="rows" role="button" tabindex="0" aria-pressed="false">Rows</span></button><ol class="rowsl"></ol><div class="wbody"></div></div><article class="answer">${t.answer.map(p=>'<p>'+p.split(' ').map(w=>'<span class="w">'+w.replace(/</g,'&lt;')+'</span>').join(' ')+'</p>').join('')}</article>`;
  el.querySelector('.prompt').textContent=t.prompt;
  el.querySelector('.rowsl').innerHTML=t.steps.map((x,k)=>`<li>${Neural.shapeSvg(x.fam,16)}<span class="no">${k+1}</span><span class="tl${x.status==='fail'?' bad':''}">${x.tool}</span><span class="ar">${(x.arg||x.text||'').replace(/</g,'&lt;')}</span></li>`).join('');
  body.appendChild(el);
  const w=el.querySelector('.work');
  w.querySelector('.wline').addEventListener('click',e=>{if(e.target.classList.contains('rows'))return;if(openIdx===i)closeBrain();else openBrain(i);});
  const rb=w.querySelector('.rows');
  const tr=ev=>{ev.stopPropagation();const on=!w.querySelector('.rowsl').classList.contains('show');w.querySelector('.rowsl').classList.toggle('show',on);rb.setAttribute('aria-pressed',on);};
  rb.addEventListener('click',tr);rb.addEventListener('keydown',ev=>{if(ev.key==='Enter'||ev.key===' '){ev.preventDefault();tr(ev);}});
});

function applyTheme(k){
  themeKey=k;if(hero)hero.st.theme=k;const th=Hero.THEMES[k],r=document.documentElement.style;
  r.setProperty('--bg',th.bg);r.setProperty('--panel',th.bg);r.setProperty('--ink',th.ink);r.setProperty('--ink2',th.ink2);r.setProperty('--ink3',th.ink2+'99');r.setProperty('--accent',th.accent);r.setProperty('--accent2',th.accent);r.setProperty('--info',th.info);r.setProperty('--special',th.special);r.setProperty('--danger',th.danger);r.setProperty('--rule2',th.ink2+'55');r.setProperty('--rule',th.ink2+'33');
  document.querySelectorAll('.th').forEach(b=>b.setAttribute('aria-pressed',b.dataset.t===k));
  request();
}
function mountNodes(list){
  nodesHost.querySelectorAll('.nv-svg,.tip').forEach(n=>n.remove());
  const groups=new Set(list.map(s=>s.msg)).size;
  nv=Neural.mount(nodesHost,{steps:list,layout:'cortex',bare:true,say:true,r:10,spacing:{def:28,say:24},step:Math.min(.5,14/groups),eye:'done',label:'Everything the agent did before answering',onHot:s=>{hotZone=s?s.fam:null;request();}});
  const svg=nodesHost.querySelector('.nv-svg');svg.style.transformOrigin='50% 50%';
  svg.querySelectorAll('.zl').forEach(t=>{t.setAttribute('tabindex','0');t.setAttribute('role','button');t.addEventListener('click',()=>diveTo(t.dataset.zone));});
  nv.settle();applyDive();
}
function applyDive(){
  const c=dive.cen,cx=c[0]/640,cy=c[1]/420,s=dive.s;
  const inner=stage.querySelector('.inner');inner.style.transformOrigin=(cx*100)+'% '+(cy*100)+'%';inner.style.transform='scale('+s+')';
  const svg=nodesHost.querySelector('.nv-svg');if(svg){svg.style.transformOrigin=(cx*100)+'% '+(cy*100)+'%';svg.style.transform='scale('+s+')';}
  hero.st.cen=[cx,1-cy];hero.st.sc=1+(s-1)*1.7;hero.st.sg=1+(s-1)*1.25;hero.st.fade=clamp(1-(s-1.5)/1.1,0,1);
}
let diveAnim=null;
function diveTo(z){const c=ZC[z];dive.cen=[c[0],c[1]];animateDive(dive.s,z==='say'?3.4:2.6,520);}
function animateDive(a,b,d){diveAnim={a,b,d:reduce?1:d,t0:performance.now()};request();}
function stepDive(now){
  if(!diveAnim)return false;
  const t=clamp((now-diveAnim.t0)/diveAnim.d,0,1),e=t<.5?4*t*t*t:1-Math.pow(-2*t+2,3)/2;
  dive.s=diveAnim.a+(diveAnim.b-diveAnim.a)*e;applyDive();
  if(t>=1){diveAnim=null;return false;}return true;
}
document.addEventListener('keydown',e=>{if(e.key==='Escape')animateDive(dive.s,1,420);});

function setStatus(){
  if(mode==='working'){statusEl.className='status live';statusEl.innerHTML='<span class="sd"></span>working';}
  else{statusEl.className='status';statusEl.innerHTML='<span class="sd" style="opacity:.5"></span>'+(openIdx>=0||true?'idle':'');}
}
function words(i){return [...body.querySelectorAll('.turn')[i].querySelectorAll('.answer .w')];}
function showWords(i,n){words(i).forEach((w,k)=>{w.style.opacity=k<n?1:0;});}

function openBrain(i){
  if(openIdx>=0)closeBrain(true);
  openIdx=i;const w=document.getElementById('work'+i);w.classList.add('open');w.querySelector('.chev').textContent='▾';
  w.querySelector('.wbody').appendChild(stage);
  w.querySelector('.wbody').appendChild(tickerEl);
  dive.s=1;dive.cen=[320,210];diveAnim=null;
  mountNodes(TURNS[i].steps);
  mode='done';nv.settle();setStatus();request();
}
function closeBrain(silent){
  if(openIdx<0)return;
  const w=document.getElementById('work'+openIdx);w.classList.remove('open');w.querySelector('.chev').textContent='▸';
  document.getElementById('park').appendChild(stage);document.getElementById('park').appendChild(tickerEl);
  openIdx=-1;mode='done';hotZone=null;
  if(!silent)setStatus();
}

function targets(now){
  const base=Array(10).fill(.5);base[6]=.55;base[7]=.6;base[8]=.3;base[9]=.5;
  if(mode==='working'){
    const t=(now-workStart)/1000;let a=-1;nv.fire.forEach((f,i)=>{if(f<=t)a=i;});
    const steps=TURNS[openIdx].steps,act=a>=0?steps[a].fam:null;
    if(t>nv.endT+.3){finishLive();}
    nv.paint(t);
    for(let i=0;i<6;i++)base[i]=.32;if(act)base[ZI[act]]=1.05+.2*Math.sin(t*5.2);
    base[9]=.55+.45*(.5+.5*Math.sin(t*2.6));hero.st.ripple=1;hero.st.time=t;if(act){const c=ZC[act];hero.st.act=[c[0]/640,1-c[1]/420];}
    let cap='Thinking…';steps.forEach((s,i)=>{if(s.fam==='say'&&nv.fire[i]<=t)cap=s.text;});
    if(tickerEl.dataset.cap!==cap){tickerEl.dataset.cap=cap;tickerEl.innerHTML='<span class="tk"></span><span class="tx"></span>';tickerEl.querySelector('.tx').textContent=cap;}
  }else{hero.st.ripple=0;base[9]=.7;}
  if(hotZone&&mode!=='working'){for(let i=0;i<6;i++)base[i]=.3;base[ZI[hotZone]]=1.2;base[6]=.6;}
  return base;
}
function finishLive(){mode='done';nv.settle();tickerEl.innerHTML='';tickerEl.dataset.cap='';setStatus();setPress('s-done');let n=0;clearInterval(streamTimer);const total=words(openIdx).length;showWords(openIdx,0);streamTimer=setInterval(()=>{n+=2;showWords(openIdx,n);if(n>=total)clearInterval(streamTimer);},60);}
function frame(now){
  raf=0;if(!hero||openIdx<0){loopRunning=false;renderPerf();return;}
  const tg=targets(now),inten=hero.st.inten;let moving=mode==='working';
  for(let i=0;i<10;i++){const d=tg[i]-inten[i];if(Math.abs(d)>.004){inten[i]+=d*.18;moving=true;}else inten[i]=tg[i];}
  const diving=stepDive(now);hero.draw();
  const dt=now-lastFrame;if(dt>0&&dt<500)fps=fps*.8+(1000/dt)*.2;lastFrame=now;
  loopRunning=moving||diving;if(loopRunning)raf=requestAnimationFrame(frame);else fps=0;
  renderPerf();
}
function request(){if(!hero||openIdx<0)return;if(!raf){lastFrame=performance.now();raf=requestAnimationFrame(frame);}}
function renderPerf(){perf.innerHTML=`<span><b>11</b> textures · ${hero.W}×${hero.H} · one open brain</span><span>frames drawn <b>${hero.st.frames}</b></span><span class="${loopRunning?'live':''}">${loopRunning?'drawing · '+Math.round(fps)+' fps':'idle · draws nothing'}</span><span>${openIdx<0?'no brain open: no canvas in the page flow':'open: turn '+(openIdx+1)}</span>`;}
function setPress(id){['s-live','s-done','s-line'].forEach(k=>document.getElementById(k).setAttribute('aria-pressed',k===id));}

function latestLive(){
  clearInterval(streamTimer);
  const last=TURNS.length-1;if(openIdx!==last)openBrain(last);
  showWords(last,0);mode='working';workStart=performance.now();nv.settle();setStatus();setPress('s-live');
  if(reduce){mode='done';nv.settle();showWords(last,999);setPress('s-done');setStatus();}
  request();
}
function latestDone(){clearInterval(streamTimer);const last=TURNS.length-1;if(openIdx!==last)openBrain(last);mode='done';nv.settle();showWords(last,999);setStatus();setPress('s-done');request();}
function latestLine(){clearInterval(streamTimer);closeBrain();showWords(TURNS.length-1,999);setPress('s-line');setStatus();}
function setWidth(phone){chat.classList.toggle('phone',phone);document.getElementById('w-desk').setAttribute('aria-pressed',!phone);document.getElementById('w-phone').setAttribute('aria-pressed',phone);if(openIdx>=0){const i=openIdx;closeBrain(true);openBrain(i);}}

(async function(){
  const park=document.createElement('div');park.id='park';park.style.display='none';document.body.appendChild(park);
  stage=document.createElement('div');stage.className='hstage';stage.innerHTML='<div class="inner"><canvas id="cInt"></canvas></div><div class="nodes"></div><canvas id="cFront"></canvas>';
  nodesHost=stage.querySelector('.nodes');tickerEl=document.createElement('div');tickerEl.className='ticker';tickerEl.setAttribute('aria-live','polite');
  park.appendChild(stage);park.appendChild(tickerEl);
  try{hero=await Hero.create({assets:ASSETS,interior:stage.querySelector('#cInt'),front:stage.querySelector('#cFront')});}
  catch(e){body.insertAdjacentHTML('afterbegin','<p style="color:var(--ink2)">WebGL2 is needed to draw this artboard: '+String(e.message).replace(/</g,'&lt;')+'</p>');return;}
  document.querySelectorAll('.th').forEach(b=>b.onclick=()=>applyTheme(b.dataset.t));
  document.getElementById('s-live').onclick=latestLive;document.getElementById('s-done').onclick=latestDone;document.getElementById('s-line').onclick=latestLine;
  document.getElementById('w-desk').onclick=()=>setWidth(false);document.getElementById('w-phone').onclick=()=>setWidth(true);
  applyTheme(P.get('theme')||'matrix');
  if(P.get('width')==='phone')setWidth(true);
  const st=P.get('state');
  if(st==='line')latestLine();else if(st==='live'){latestLive();if(P.get('t')!==null)workStart=performance.now()-parseFloat(P.get('t'))*1000;}else if(P.get('open')){openBrain(parseInt(P.get('open'),10));}else latestDone();
  if(P.get('hover')!==null&&nv)nv.setHot(parseInt(P.get('hover'),10)-1);
  if(P.get('rows')==='1'){document.querySelectorAll('.work .rows')[0].click();}
  renderPerf();window.__hero=hero;window.__heroReady=true;
})();
"""

f_script = (here / 'f.js').read_text()
f_css += """
.scrub{display:none;align-items:center;gap:10px;padding:2px 16px 10px}
.work.open .scrub{display:flex}
.scrub .pl{padding:2px 9px;font-size:11px}
.scrub input{flex:1;accent-color:var(--accent)}
.scrub .sl{min-width:62px;color:var(--ink3);font-size:11px;font-variant-numeric:tabular-nums}
.fcard{display:flex;flex-direction:column;gap:6px;border:1px solid color-mix(in srgb,var(--danger) 55%,transparent);border-radius:14px;padding:12px 14px;background:color-mix(in srgb,var(--danger) 8%,transparent);font:14px/1.5 ui-sans-serif,"Inter","Noto Sans",system-ui,sans-serif;color:var(--ink)}
.fcard b{color:var(--danger)}
.fcard .act{align-self:flex-start;margin-top:4px;padding:5px 14px;border-radius:9px;border:1px solid var(--rule2);color:var(--ink);font-size:12.5px}
.answer .prov{border-bottom:1px dashed var(--accent);color:var(--accent);cursor:pointer}
.answer .prov:hover{background:color-mix(in srgb,var(--accent) 14%,transparent)}
"""
f_body = f_body.replace('<button class="th" data-t="tokyo" aria-pressed="false">Tokyo Night</button></div>','<button class="th" data-t="tokyo" aria-pressed="false">Tokyo Night</button><button class="th" data-t="dawn" aria-pressed="false">Dawn</button></div>')
try:
    (out / "F.html").write_text(
        f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>F · The layout</title>
<style>{css}{PAGE_CSS}{f_css}</style></head>
<body>
{f_body}
<script>const ASSETS={json.dumps(assets)};{data}{engine}{(here / 'hero2.js').read_text()}{LEGEND_JS}{f_script}</script>
</body></html>
"""
    )
    print("built F", (out / "F.html").stat().st_size // 1024, "KB")
except NameError as ex:
    print("F skipped:", ex)


g_body = """<main class="page gpage">
<header class="bar"><span class="eyebrow">G · STATES</span>
<div class="tools"><button class="th" data-t="matrix" aria-pressed="true">Matrix</button><button class="th" data-t="rose" aria-pressed="false">Rosé Pine</button><button class="th" data-t="tokyo" aria-pressed="false">Tokyo Night</button><button class="th" data-t="dawn" aria-pressed="false">Rosé Pine Dawn</button></div></header>
<div class="ggrid">
<section class="gleft">
<div id="slot"></div>
<div class="info" id="info"></div>
</section>
<aside class="gright" id="chips"></aside>
</div>
<section class="meters">
<div class="mgroup"><label>Context <output id="ctxo">42%</output></label><input id="ctx" type="range" min="0" max="100" value="42"><label class="chk"><input id="est" type="checkbox"> estimated (~)</label></div>
<div class="mgroup"><label>Effort</label><div class="tools" id="effort"></div></div>
<div class="mgroup"><label>Answered by</label><select id="fam"></select></div>
<div class="mgroup"><label>Voice call</label><div class="tools" id="call"></div></div>
<div class="mgroup"><label class="chk"><input id="rm" type="checkbox"> reduced motion</label></div>
</section>
<div class="perf" id="perf"></div>
<p class="foot">Every state is an <b>ActivityKind</b> the app already has, drawn on the head instead of a new list of states. The tone sets the eye and the active zone (live accent, attention warn, danger, quiet muted), the motion is the activity's own (breath 1.9 s, heartbeat 1.6 s, sweep 1.05 s, still), and the zone that lights is the tool family the header is already naming. A settled turn has no tone of its own, so its eye wears who answered and how hard. Stopped and interrupted turns have no face in the app, so the head stays neutral and the card carries the news.</p>
</main>"""

g_css = """
.gpage{max-width:1180px}
.ggrid{display:grid;grid-template-columns:minmax(0,1fr) 250px;gap:18px;align-items:start}
@media (max-width:860px){.ggrid{grid-template-columns:1fr}}
.gleft .hstage{position:relative;aspect-ratio:640/420;border-radius:18px;overflow:hidden;background:var(--bg);border:1px solid var(--rule)}
.hstage canvas{position:absolute;inset:0;width:100%;height:100%;display:block}
.inner{position:absolute;inset:0;z-index:1}
.nodes{position:absolute;inset:0;z-index:auto}
.nodes .nv-svg{position:absolute;inset:0;width:100%;height:100%;min-width:0;z-index:2}
.nodes .tip{z-index:6}
#cFront{z-index:3;pointer-events:none}
.nodes .tip.dock{position:absolute;left:8px;right:8px;bottom:8px;top:auto;width:auto;margin:0}
.info{margin-top:12px;border:1px solid var(--rule);border-radius:12px;padding:12px 14px;background:var(--panel);display:grid;grid-template-columns:auto 1fr;gap:4px 14px;font-size:12px;line-height:1.5}
.info h3{grid-column:1/-1;margin:0 0 4px;font-size:14px;color:var(--ink);font-weight:600}
.info dt{color:var(--ink3)}
.info dd{margin:0;color:var(--ink2)}
.info dd b{color:var(--ink);font-weight:600}
.gright{display:flex;flex-direction:column;gap:12px}
.gright h4{margin:0 0 6px;font-size:10.5px;letter-spacing:.16em;color:var(--ink3);font-weight:600}
.gright .row{display:flex;flex-wrap:wrap;gap:6px}
.chip{padding:4px 9px;font-size:11.5px;border-radius:99px}
.chip .tn{display:inline-block;width:7px;height:7px;border-radius:50%;margin-right:6px;vertical-align:0}
.chip .tn.live{background:var(--accent)}.chip .tn.attention{background:var(--warn)}.chip .tn.danger{background:var(--danger)}.chip .tn.quiet{background:var(--ink3)}
.meters{display:flex;flex-wrap:wrap;gap:14px 28px;margin-top:16px;padding:12px 14px;border:1px solid var(--rule);border-radius:12px;background:var(--panel);font-size:12px;color:var(--ink2)}
.mgroup{display:flex;align-items:center;gap:10px;flex-wrap:wrap}
.mgroup label{color:var(--ink3);font-size:11px;letter-spacing:.06em}
.mgroup output{color:var(--ink);margin-left:6px}
.mgroup select{font:inherit;color:var(--ink);background:var(--panel2);border:1px solid var(--rule2);border-radius:6px;padding:4px 8px}
.mgroup input[type=range]{width:140px;accent-color:var(--accent)}
.mgroup .tools button{padding:3px 8px;font-size:11px}
.chk{display:flex;align-items:center;gap:6px;cursor:pointer}
.perf{margin:10px 0 0;color:var(--ink3);font-size:11px;display:flex;flex-wrap:wrap;gap:4px 18px}
.perf b{color:var(--ink2);font-weight:600}
.perf .live{color:var(--accent)}
"""

g_script = """
const P=params();
const ZORD=Hero.ZORD,ZC=Hero.ZC;
const slot=document.getElementById('slot'),info=document.getElementById('info'),chipsEl=document.getElementById('chips'),perf=document.getElementById('perf');
let hero=null,nv=null,stage=null,nodesHost=null,orbitEl=null,themeKey='matrix',stateId='settled',raf=0,t0=performance.now(),lastKey='',loop=false,fps=0,lastF=0;
const ctx={ctxFill:.42,ctxEst:false,family:'fable',call:null};
let effortSel='high',reduce=false;
const EFFORT=[['low',1],['medium',2],['high',3],['xhigh',4],['max',5],['ultracode','power'],['server decides','server'],['ember','ember']];
const CALLS=['off','connecting','listening','hearing','degraded','ended'];

function stateById(id){return Hero.STATES.find(s=>s.id===id);}
function baseSteps(){return BUILD_FIX.slice(0,9).map(s=>Object.assign({},s,{status:s.status==='fail'?'ok':s.status,recovered:false}));}
function stepsFor(st){
  const s=baseSteps();
  if(st.id==='failed'){s[5].status='fail';}
  if(st.add)s.push(Object.assign({msg:99,at:'14:05:10'},st.add));
  if(st.stopped)s.push({fam:'shell',tool:'Bash',status:'stopped',msg:99,at:'14:05:10',arg:'swift build -c release'});
  return s;
}
function buildChips(){
  const groups=['Working','Needs you','Quiet','Ended'];
  chipsEl.innerHTML=groups.map(g=>'<div><h4>'+g.toUpperCase()+'</h4><div class="row">'+Hero.STATES.filter(s=>s.group===g).map(s=>`<button class="chip" data-id="${s.id}" aria-pressed="false"><span class="tn ${s.tone}"></span>${s.id==='settled'?'settled turn':s.id}</button>`).join('')+'</div></div>').join('');
  chipsEl.querySelectorAll('.chip').forEach(b=>b.onclick=()=>setState(b.dataset.id));
}
function mountNodes(list){
  nodesHost.querySelectorAll('.nv-svg,.tip').forEach(n=>n.remove());
  const groups=new Set(list.map(s=>s.msg)).size;
  nv=Neural.mount(nodesHost,{steps:list,layout:'cortex',bare:true,say:true,r:10,spacing:{def:28,say:24},step:.4,eye:'done',label:'The head in a state'});
  nv.settle();
  const svg=nodesHost.querySelector('.nv-svg');
  orbitEl=document.createElementNS('http://www.w3.org/2000/svg','circle');orbitEl.setAttribute('class','orbit');orbitEl.setAttribute('r','5');orbitEl.style.display='none';svg.appendChild(orbitEl);
}
function setState(id){
  stateId=id;const st=stateById(id);
  document.querySelectorAll('.chip').forEach(b=>b.setAttribute('aria-pressed',b.dataset.id===id));
  mountNodes(stepsFor(st));
  nodesHost.style.filter=st.dark?'grayscale(1) brightness(.55)':'';
  const th=Hero.THEMES[themeKey];
  const motionName={breath:'breath · 1.9 s, floor .34',heartbeat:'heartbeat · 1.6 s, two beats',sweep:'sweep · 1.05 s',still:'still'}[st.motion];
  info.innerHTML=`<h3>${id==='settled'?'A settled turn':id}</h3><dt>ActivityKind</dt><dd><b>${st.kind}</b></dd><dt>Tone</dt><dd><b>${st.tone}</b></dd><dt>Motion</dt><dd>${motionName}</dd><dt>Zone</dt><dd>${st.zone?st.zone.toUpperCase():'whole head'}</dd><dt>Header says</dt><dd>${st.head}</dd><dt>The head</dt><dd>${st.says}</dd><dt>Reduced motion</dt><dd>${st.motion==='still'?'unchanged':'held still in the same tone; the node glyph and the header still say it'}</dd>`;
  lastKey='';start();
}
function applyFrame(t){
  const st=stateById(stateId);
  const sstate=reduce?Object.assign({},st,{motion:'still'}):st;
  const f=Hero.frameFor(sstate,t,themeKey,ctx);
  hero.st.theme=themeKey;
  for(let i=0;i<f.inten.length;i++)hero.st.inten[i]=f.inten[i];
  hero.st.toneOv=f.tone;
  hero.st.sweep=f.sweep;hero.st.sweepAmt=f.sweepAmt;hero.st.sweepTone=f.sweepTone;hero.st.crunch=f.crunch;
  hero.st.time=t;
  const e=Hero.effortSpec(effortSel==='ultracode'?'power':effortSel==='server decides'?'server':effortSel==='ember'?'ember':EFFORT.find(x=>x[0]===effortSel)[1]);
  hero.st.effort=e.effort;hero.st.hollow=e.hollow;hero.st.rainbow=e.rainbow;
  const fill=f.ctxOverride!=null?f.ctxOverride:ctx.ctxFill;
  hero.st.ctx=Math.round(fill*6*100)/100;
  if(orbitEl){
    if(f.orbit){const a=t*(2*Math.PI/6);orbitEl.style.display='';orbitEl.setAttribute('cx',320+262*Math.cos(a));orbitEl.setAttribute('cy',186+168*Math.sin(a));}
    else orbitEl.style.display='none';
  }
  return st.motion!=='still'&&!reduce||!!ctx.call&&['listening','connecting'].includes(ctx.call);
}
let lastDraw=0;
function frame(now){
  raf=0;
  if(now-lastDraw<30&&lastDraw){raf=requestAnimationFrame(frame);return;}
  lastDraw=now;const t=(now-t0)/1000;
  const moving=applyFrame(t);hero.draw();
  const dt=now-lastF;if(dt>0&&dt<500)fps=fps*.8+(1000/dt)*.2;lastF=now;
  loop=moving;if(moving)raf=requestAnimationFrame(frame);else fps=0;
  renderPerf();
}
function start(){if(!hero)return;if(!raf){lastF=performance.now();raf=requestAnimationFrame(frame);}}
function renderPerf(){perf.innerHTML=`<span>frames drawn <b>${hero.st.frames}</b></span><span class="${loop?'live':''}">${loop?'drawing · '+Math.round(fps)+' fps':'idle · draws nothing'}</span><span>13 textures · ${hero.W}×${hero.H}</span>`;}
function applyTheme(k){
  themeKey=k;const th=Hero.THEMES[k],r=document.documentElement.style;
  r.setProperty('--bg',th.bg);r.setProperty('--panel',th.light?'#fffaf3':th.bg);r.setProperty('--panel2',th.light?'#f2e9e1':th.bg);r.setProperty('--ink',th.ink);r.setProperty('--ink2',th.ink2);r.setProperty('--ink3',th.ink2+'99');r.setProperty('--accent',th.accent);r.setProperty('--accent2',th.accent);r.setProperty('--info',th.info);r.setProperty('--special',th.special);r.setProperty('--warn',th.warn);r.setProperty('--danger',th.danger);r.setProperty('--rule2',th.ink2+'55');r.setProperty('--rule',th.ink2+'33');
  document.querySelectorAll('.th').forEach(b=>b.setAttribute('aria-pressed',b.dataset.t===k));
  if(stage)stageTheme(stage,th);
  lastKey='';start();
}
(async function(){
  stage=document.createElement('div');stage.className='hstage';stage.id='stage';stage.innerHTML='<div class="inner"><canvas id="cInt"></canvas></div><div class="nodes"></div><canvas id="cFront"></canvas>';
  slot.appendChild(stage);nodesHost=stage.querySelector('.nodes');
  try{hero=await Hero.create({assets:ASSETS,interior:stage.querySelector('#cInt'),front:stage.querySelector('#cFront')});}
  catch(e){slot.insertAdjacentHTML('afterbegin','<p style="color:var(--ink2)">WebGL2 is needed to draw this artboard: '+String(e.message).replace(/</g,'&lt;')+'</p>');return;}
  buildChips();
  document.getElementById('effort').innerHTML=EFFORT.map(e=>`<button data-e="${e[0]}" aria-pressed="${e[0]===effortSel}">${e[0]}</button>`).join('');
  document.querySelectorAll('#effort button').forEach(b=>b.onclick=()=>{effortSel=b.dataset.e;document.querySelectorAll('#effort button').forEach(x=>x.setAttribute('aria-pressed',x===b));start();});
  document.getElementById('fam').innerHTML=Object.keys(Hero.FAMILIES).map(k=>`<option value="${k}">${k}</option>`).join('');
  document.getElementById('fam').onchange=e=>{ctx.family=e.target.value;start();};
  document.getElementById('call').innerHTML=CALLS.map(c=>`<button data-c="${c}" aria-pressed="${c==='off'}">${c}</button>`).join('');
  document.querySelectorAll('#call button').forEach(b=>b.onclick=()=>{ctx.call=b.dataset.c==='off'?null:b.dataset.c;document.querySelectorAll('#call button').forEach(x=>x.setAttribute('aria-pressed',x===b));start();});
  document.getElementById('ctx').oninput=e=>{ctx.ctxFill=e.target.value/100;document.getElementById('ctxo').textContent=e.target.value+'%';start();};
  document.getElementById('est').onchange=e=>{ctx.ctxEst=e.target.checked;start();};
  document.getElementById('rm').onchange=e=>{reduce=e.target.checked;start();};
  document.querySelectorAll('.th').forEach(b=>b.onclick=()=>applyTheme(b.dataset.t));
  applyTheme(P.get('theme')||'matrix');
  if(P.get('ctx')){ctx.ctxFill=parseFloat(P.get('ctx'));document.getElementById('ctx').value=ctx.ctxFill*100;document.getElementById('ctxo').textContent=Math.round(ctx.ctxFill*100)+'%';}
  if(P.get('effort')){effortSel=P.get('effort');document.querySelectorAll('#effort button').forEach(x=>x.setAttribute('aria-pressed',x.dataset.e===effortSel));}
  if(P.get('family')){ctx.family=P.get('family');document.getElementById('fam').value=ctx.family;}
  if(P.get('call')){ctx.call=P.get('call');document.querySelectorAll('#call button').forEach(x=>x.setAttribute('aria-pressed',x.dataset.c===ctx.call));}
  if(P.get('rm')==='1'){reduce=true;document.getElementById('rm').checked=true;}
  setState(P.get('state')||'settled');
  if(P.get('t')!==null){t0=performance.now()-parseFloat(P.get('t'))*1000;}
  window.__hero=hero;window.__heroReady=true;
})();
"""

try:
    (out / "G.html").write_text(
        f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>G · States</title>
<style>{css}{PAGE_CSS}{g_css}</style></head>
<body>
{g_body}
<script>const ASSETS={json.dumps(assets)};{data}{engine}{(here / 'hero2.js').read_text()}{LEGEND_JS}{g_script}</script>
</body></html>
"""
    )
    print("built G", (out / "G.html").stat().st_size // 1024, "KB")
except NameError as ex:
    print("G skipped:", ex)


i_body = """<main class="page ipage">
<header class="bar"><span class="eyebrow">I · AWAY</span>
<div class="tools"><button class="th" data-t="matrix" aria-pressed="true">Dark</button><button class="th" data-t="dawn" aria-pressed="false">Light</button></div></header>
<p class="lead">The head when the app is not in front. Four states across the four surfaces the person sees: the Lock Screen card, the Dynamic Island, the notification's long look and Home's row. The head is a static drawing here (an outline, zone dots, an eye), so the Live Activity can draw it with SwiftUI paths and the notification with Core Graphics; nothing needs a shader.</p>
<div class="away" id="away"></div>
<p class="foot"><b>What changes.</b> The Lock Screen and expanded-island icon become the head: the eye is the state's tone, the ringed zone is the tool family the header names, and the dots show what the turn touched. The compact and minimal island keep the tinted symbol, because 14 pt is below a head's floor. The long look draws the head at 46 pt in the notification's tone tile and the buttons follow what can be done (Reply, Try again, Approve and Deny). Home's row keeps its tinted tile and its symbol; the head appears there only on a collapsed turn's line inside the chat, where a scan of a long conversation shows the failed turns by their eye.</p>
</main>"""

i_css = """
.ipage{max-width:1180px}
.lead{color:var(--ink2);max-width:90ch;margin:0 0 16px}
.away{display:grid;grid-template-columns:110px repeat(4,minmax(0,1fr));gap:12px}
.away .colh{font-size:11px;letter-spacing:.14em;color:var(--ink3);padding:0 2px 4px}
.away .colh i{display:inline-block;width:7px;height:7px;border-radius:50%;margin-right:6px}
.away .rowh{font-size:11px;color:var(--ink3);align-self:center;line-height:1.4}
.surf{border-radius:16px;padding:10px;background:#0b0c10;color:#eceef2;font:13px/1.35 -apple-system,"SF Pro Text","Inter","Noto Sans",system-ui,sans-serif;min-height:96px;position:relative}
.light .surf{background:#e9e4de;color:#1d1b25}
.lk{display:flex;gap:11px;align-items:center;background:rgba(48,50,60,.78);border-radius:20px;padding:11px 13px}
.light .lk{background:rgba(255,255,255,.8)}
.lk .tx{flex:1;min-width:0}
.lk .t{font-weight:600;font-size:13px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.lk .c{font-size:11.5px;opacity:.7;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.lk .tm{font-size:11.5px;opacity:.75;font-variant-numeric:tabular-nums}
.gtile{display:grid;place-items:center;border-radius:12px;flex:none}
.isl{background:#000;border-radius:26px;padding:10px 12px;color:#fff}
.isl.compact{display:flex;align-items:center;justify-content:space-between;border-radius:99px;padding:6px 12px;width:150px;margin:0 auto 8px;font-size:11px}
.isl.compact .dotc{width:14px;height:14px;border-radius:50%;display:grid;place-items:center;font-size:9px}
.isl.big{display:flex;gap:10px;align-items:center}
.isl.big .tx{flex:1;min-width:0}
.isl .t{font-weight:600;font-size:12.5px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.isl .c{font-size:11px;opacity:.7;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.nt{background:rgba(48,50,60,.82);border-radius:18px;padding:10px 12px}
.light .nt{background:rgba(255,255,255,.85)}
.nt .app{display:flex;justify-content:space-between;font-size:10.5px;opacity:.65;margin-bottom:6px;letter-spacing:.02em}
.nt .body{display:flex;gap:10px}
.nt .t{font-weight:600;font-size:13px}
.nt .c{font-size:11.5px;opacity:.78;margin-top:2px}
.nt .acts{display:flex;gap:6px;margin-top:9px}
.nt .acts span{flex:1;text-align:center;padding:6px 0;border-radius:9px;background:rgba(120,120,135,.28);font-size:11.5px;font-weight:600}
.nt .acts span.pri{background:var(--accent);color:#04120a}
.hr{display:flex;flex-direction:column;gap:8px}
.hr .r{display:flex;gap:10px;align-items:center;background:rgba(48,50,60,.55);border-radius:14px;padding:8px 10px}
.light .hr .r{background:rgba(255,255,255,.7)}
.hr .r .tx{flex:1;min-width:0}
.hr .r .t{font-weight:600;font-size:12.5px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.hr .r .c{font-size:11px;opacity:.7;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.hr small{display:block;font-size:9.5px;letter-spacing:.14em;opacity:.5;margin:2px 2px 0}
@media (max-width:900px){.away{grid-template-columns:1fr 1fr}.away .rowh,.away .colh.sp{display:none}}
"""

i_script = """
const P=params();
const away=document.getElementById('away');
const TH={matrix:{bg:'#030806',ink:'#d3f7e0',ink2:'#89be9b',accent:'#39ff88',warn:'#f2c14e',danger:'#ff5c7a',light:false},dawn:{bg:'#faf4ed',ink:'#575279',ink2:'#797593',accent:'#56949f',warn:'#ea9d34',danger:'#b4637a',light:true}};
const COLS=[
 {id:'work',name:'WORKING',tone:'live',zone:'sense',steps:BUILD_FIX.slice(0,5),title:'Reading Activity.swift',cap:'Fixing the Linux build · 4 tools',time:'1:12',sym:'●',notice:null,island:'Reading'},
 {id:'ask',name:'NEEDS YOU',tone:'attention',zone:'shell',steps:BUILD_FIX.slice(0,6),title:'Waiting for approval',cap:'Bash: rm -rf build && swift build',time:'3:40',sym:'⏸',notice:{t:'Approve a command?',c:'rm -rf build && swift build -c release',acts:['Deny','Approve'],pri:1},island:'Approval'},
 {id:'fail',name:'FAILED',tone:'danger',zone:'shell',steps:BUILD_FIX.slice(0,6).map((s,i)=>i===5?Object.assign({},s,{recovered:false}):s),title:'Failed',cap:'swift build stopped: switch must be exhaustive',time:'2:31',sym:'✗',notice:{t:'The turn failed',c:'swift build stopped: TranscriptRows.swift:212 switch must be exhaustive',acts:['Try again'],pri:1},island:'Failed'},
 {id:'done',name:'DONE',tone:'done',zone:null,steps:TURN,title:'Done · 8m 25s',cap:'25 tools · edited 2 files · +5 −2',time:'8:25',sym:'●',notice:{t:'Demo video is ready',c:'25 tools in 8m 25s: ran 18 commands, read 3 files, edited 2 files (+5 −2)',acts:['Reply'],pri:0},island:'Done'}
];
function toneVar(c,th){return c.tone==='live'?th.accent:c.tone==='attention'?th.warn:c.tone==='danger'?th.danger:'#d97757';}
function glyph(c,size,th){const col=toneVar(c,th);return Neural.glyph(c.steps,{size:size,eyeColor:col,activeZone:c.zone,ringColor:col});}
function tile(c,size,th){const col=toneVar(c,th);return `<span class="gtile" style="width:${size+12}px;height:${size+4}px;background:color-mix(in srgb,${col} 16%,transparent)">${glyph(c,size,th)}</span>`;}
function render(k){
  const th=TH[k];document.body.classList.toggle('light',th.light);
  const r=document.documentElement.style;r.setProperty('--bg',th.bg);r.setProperty('--ink',th.ink);r.setProperty('--ink2',th.ink2);r.setProperty('--ink3',th.ink2+'99');r.setProperty('--accent',th.accent);r.setProperty('--warn',th.warn);r.setProperty('--danger',th.danger);r.setProperty('--panel',th.light?'#fffaf3':th.bg);r.setProperty('--rule',th.ink2+'33');r.setProperty('--rule2',th.ink2+'55');
  const rows=[
   ['Lock Screen<br>Live Activity',c=>`<div class="surf"><div class="lk">${glyph(c,44,th)}<div class="tx"><div class="t">${c.title}</div><div class="c">${c.cap}</div></div><span class="tm">${c.time}</span></div></div>`],
   ['Dynamic Island<br>compact, expanded',c=>`<div class="surf"><div class="isl compact"><span class="dotc" style="background:color-mix(in srgb,${toneVar(c,th)} 30%,#000);color:${toneVar(c,th)}">${c.sym}</span><span>${c.time}</span></div><div class="isl big">${glyph(c,38,th)}<div class="tx"><div class="t">${c.title}</div><div class="c">${c.cap}</div></div><span class="tm" style="font-size:11px;opacity:.75">${c.time}</span></div></div>`],
   ['Notification<br>long look',c=>c.notice?`<div class="surf"><div class="nt"><div class="app"><span>TAILSCODE</span><span>now</span></div><div class="body">${tile(c,34,th)}<div><div class="t">${c.notice.t}</div><div class="c">${c.notice.c}</div></div></div><div class="acts">${c.notice.acts.map((a,i)=>`<span class="${c.notice.pri&&i===c.notice.acts.length-1?'pri':''}">${a}</span>`).join('')}</div></div></div>`:`<div class="surf"><div style="opacity:.55;font-size:11.5px;padding:14px 8px;line-height:1.45">No notification while it works: the Live Activity carries it.</div></div>`],
   ['Home row<br>today vs a head<br>(compared, not proposed)',c=>`<div class="surf"><div class="hr"><small>TODAY</small><div class="r"><span class="gtile" style="width:30px;height:30px;background:color-mix(in srgb,${toneVar(c,th)} 14%,transparent);color:${toneVar(c,th)};font-size:14px">${c.sym}</span><div class="tx"><div class="t">Fix the Linux build</div><div class="c">${c.title}</div></div></div><small>WITH THE HEAD</small><div class="r">${tile(c,24,th)}<div class="tx"><div class="t">Fix the Linux build</div><div class="c">${c.title}</div></div></div></div></div>`]
  ];
  let h='<div></div>'+COLS.map(c=>`<div class="colh"><i style="background:${toneVar(c,th)}"></i>${c.name}</div>`).join('');
  rows.forEach(([n,f])=>{h+=`<div class="rowh">${n}</div>`+COLS.map(c=>f(c)).join('');});
  away.innerHTML=h;
}
document.querySelectorAll('.th').forEach(b=>b.onclick=()=>{document.querySelectorAll('.th').forEach(x=>x.setAttribute('aria-pressed',x===b));render(b.dataset.t);});
render(P.get('theme')||'matrix');
if(P.get('theme')==='dawn')document.querySelectorAll('.th').forEach(x=>x.setAttribute('aria-pressed',x.dataset.t==='dawn'));
window.__heroReady=true;
"""

(out / "I.html").write_text(
    f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>I · Away</title>
<style>{css}{PAGE_CSS}{i_css}</style></head>
<body>
{i_body}
<script>{data}{engine}{LEGEND_JS}{i_script}</script>
</body></html>
"""
)
print("built I")
