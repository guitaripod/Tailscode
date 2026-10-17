const P=params();
const ZC=Hero.ZC;
const FAM2STATE={think:'thinking',sense:'reading',act:'editing',shell:'running',say:'writing',delegate:'delegating'};
const MACFAIL=[
 {fam:'think',tool:'Thinking',status:'ok',msg:1,at:'09:12:02',text:'The Mac client builds on the macbook over the tailnet. Sync the tree, then run the install script there.'},
 {fam:'shell',tool:'Bash',status:'ok',msg:2,at:'09:12:09',arg:'rsync -a --delete ./ macbook:~/Tailscode/',out:['sent 41.2M bytes']},
 {fam:'shell',tool:'Bash',status:'fail',msg:3,at:'09:12:43',arg:'ssh macbook ./scripts/install-macapp.sh',out:['ssh: connect to host macbook port 22: Operation timed out']}
];
const TURNS=[
 {prompt:'Fix the Linux build: it stops in TranscriptRows.',steps:BUILD_FIX,dur:'6m 29s',model:{family:'sonnet',effort:3},outcome:'settled',answer:['Fixed. The build stopped on two switches that did not answer the new Compaction and Note cases. Both do now, the Mac manifest answers the same capability, and the parity check reports no gaps.','Tailscode 1.79 is installed on this machine (pid 41872).']},
 {prompt:'Install the Mac build on the macbook.',steps:MACFAIL,dur:'0m 41s',model:{family:'haiku',effort:2},outcome:'failed',card:{title:'The turn failed',text:'ssh macbook timed out after 30 s. Nothing was installed on the Mac, and the tree on the macbook is unchanged.'}},
 {prompt:'Make a product demonstration using mock data but the real apps .mp4 i can share on twitter. use /mnt/nvme8tb/Music/Pantera-The_Complete_Albums_1990-2000-24BIT-REMASTERED-WEB-FLAC-2016-RUIDOS/203-pantera-walk.flac as the background track starting from the beginning and playing for how long the demo video is.',steps:TURN,dur:'8m 25s',model:{family:'fable',effort:4},outcome:'settled',answer:['Done. The demo is at out/demo/tailscode-demo.mp4: 62 s, 3840×2160 at 30 fps, with Pantera\'s "Walk" playing from the first second to the last.','The first tap in the iOS tour lands exactly on the riff at 8.75 s, and the Linux app plays through its split-pane tour after it, cut by out/demo/cut-list.json. Everything on screen is mock data in the real apps.']}
];
const body=document.getElementById('cbody'),chat=document.getElementById('chat'),statusEl=document.getElementById('status'),perf=document.getElementById('perf');
const reduce=window.matchMedia&&matchMedia('(prefers-reduced-motion: reduce)').matches;
let hero=null,nv=null,openIdx=-1,mode='done',themeKey='matrix',hotZone=null,raf=0,workStart=0,fps=0,lastFrame=0,loopRunning=false,streamTimer=0,stage=null,nodesHost=null,tickerEl=null,scrubEl=null,scrubT=0;
const dive={s:1,cen:[320,210]};
function clamp(v,a,b){return Math.max(a,Math.min(b,v));}
function stateById(id){return Hero.STATES.find(s=>s.id===id);}
function famHex(t){return Hero.FAMILIES[t.model.family];}
function eyeCss(t){const th=Hero.THEMES[themeKey];return t.outcome==='failed'?th.danger:famHex(t);}

function sumLine(t){
  const st=t.steps,d=Neural.diffTally(st),fails=st.filter(s=>s.status==='fail'&&!s.recovered).length,healed=st.filter(s=>s.status==='fail'&&s.recovered).length;
  const think=st.filter(s=>s.fam==='think').length,say=st.filter(s=>s.fam==='say').length;
  return {cnt:Neural.toolCount(st)+' tools',mix:t.dur+(think?' · '+think+' thought'+(think>1?'s':''):'')+(say?' · '+say+' note'+(say>1?'s':''):'')+(fails?' · failed':healed?' · '+healed+' failed, then passed':''),dif:d[0]||d[1]?`<span class="a">+${d[0]}</span> <span class="d">−${d[1]}</span>`:''};
}
const PROV=/([\w.\/-]+\/[\w.\/-]+|[\w-]+\.(?:mp4|swift|json|flac|sh))/;
function answerHtml(t){
  if(t.card)return `<div class="fcard"><b>${t.card.title}</b><span>${t.card.text}</span><span class="act">Try again</span></div>`;
  return t.answer.map(p=>'<p>'+p.split(' ').map(w=>{const clean=w.replace(/[.,;:"]+$/,'').replace(/^"/,'');const prov=PROV.test(clean)&&clean.length>6;return `<span class="w${prov?' prov':''}"${prov?` data-m="${clean.replace(/"/g,'')}"`:''}>${w.replace(/</g,'&lt;')}</span>`;}).join(' ')+'</p>').join('');
}
function buildLines(){
  body.innerHTML='';
  TURNS.forEach((t,i)=>{
    const s=sumLine(t),el=document.createElement('section');el.className='turn';el.dataset.i=i;
    const col=eyeCss(t),ring=t.outcome==='failed'?'shell':null;
    el.innerHTML=`<div class="prompt"></div><div class="work" id="work${i}"><button class="wline" type="button"><span class="chev">▸</span><span class="gl">${Neural.glyph(t.steps,{size:28,eyeColor:col,activeZone:ring,ringColor:col})}</span><span class="cnt">${s.cnt}</span><span class="mix">${s.mix}</span><span class="dif">${s.dif}</span><span class="rows" role="button" tabindex="0" aria-pressed="false">Rows</span></button><ol class="rowsl"></ol><div class="wbody"></div></div><article class="answer">${answerHtml(t)}</article>`;
    el.querySelector('.prompt').textContent=t.prompt;
    el.querySelector('.rowsl').innerHTML=t.steps.map((x,k)=>`<li>${Neural.shapeSvg(x.fam,16)}<span class="no">${k+1}</span><span class="tl${x.status==='fail'?' bad':''}">${x.tool}</span><span class="ar">${(x.arg||x.text||'').replace(/</g,'&lt;')}</span></li>`).join('');
    body.appendChild(el);
    const w=el.querySelector('.work');
    w.querySelector('.wline').addEventListener('click',e=>{if(e.target.classList.contains('rows'))return;if(openIdx===i)closeBrain();else openBrain(i);});
    const rb=w.querySelector('.rows');
    const tr=ev=>{ev.stopPropagation();const on=!w.querySelector('.rowsl').classList.contains('show');w.querySelector('.rowsl').classList.toggle('show',on);rb.setAttribute('aria-pressed',on);};
    rb.addEventListener('click',tr);rb.addEventListener('keydown',ev=>{if(ev.key==='Enter'||ev.key===' '){ev.preventDefault();tr(ev);}});
    el.querySelectorAll('.prov').forEach(p=>{
      p.addEventListener('mouseenter',()=>provOn(i,p.dataset.m));p.addEventListener('mouseleave',()=>provOff());
      p.addEventListener('click',()=>{if(openIdx!==i)openBrain(i);provOn(i,p.dataset.m);});
    });
  });
}
function provOn(i,token){
  if(openIdx!==i||!nv)return;
  const ids=[];TURNS[i].steps.forEach((s,k)=>{if((s.arg&&s.arg.indexOf(token)>=0)||(s.out&&s.out.join(' ').indexOf(token)>=0))ids.push(k);});
  nv.setSet(ids);
  const zs=new Set(ids.map(k=>TURNS[i].steps[k].fam));hotZone=null;hero.st.provZones=zs;request();
}
function provOff(){if(nv){nv.setSet([]);}if(hero)hero.st.provZones=null;request();}

function applyTheme(k){
  themeKey=k;if(hero)hero.st.theme=k;const th=Hero.THEMES[k],r=document.documentElement.style;
  r.setProperty('--bg',th.bg);r.setProperty('--panel',th.light?'#fffaf3':th.bg);r.setProperty('--panel2',th.light?'#f2e9e1':th.bg);r.setProperty('--ink',th.ink);r.setProperty('--ink2',th.ink2);r.setProperty('--ink3',th.ink2+'99');r.setProperty('--accent',th.accent);r.setProperty('--accent2',th.accent);r.setProperty('--info',th.info);r.setProperty('--special',th.special);r.setProperty('--warn',th.warn);r.setProperty('--danger',th.danger);r.setProperty('--rule2',th.ink2+'55');r.setProperty('--rule',th.ink2+'33');
  document.querySelectorAll('.th').forEach(b=>b.setAttribute('aria-pressed',b.dataset.t===k));
  if(stage)stageTheme(stage,th);
  if(body.children.length){const keep=openIdx;buildLines();if(keep>=0){const w=document.getElementById('work'+keep);openIdx=-1;openBrain(keep);}}
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

function words(i){return [...body.querySelectorAll('.turn')[i].querySelectorAll('.answer .w')];}
function showWords(i,n){words(i).forEach((w,k)=>{w.style.opacity=k<n?1:0;});}
function setStatus(st){
  if(!st||st.id==='settled'||st.id==='idle'){statusEl.className='status';statusEl.innerHTML='<span class="sd" style="opacity:.5"></span>idle';return;}
  statusEl.className='status'+(st.tone==='live'?' live':'');
  statusEl.innerHTML='<span class="sd" style="background:var(--'+({live:'accent',attention:'warn',danger:'danger',quiet:'ink3'}[st.tone])+')"></span>'+st.head.replace(/^\S+\s/,'');
}
function openBrain(i){
  if(openIdx>=0)closeBrain(true);
  openIdx=i;const w=document.getElementById('work'+i);w.classList.add('open');w.querySelector('.chev').textContent='▾';
  const wb=w.querySelector('.wbody');wb.appendChild(stage);wb.appendChild(tickerEl);wb.appendChild(scrubEl);
  dive.s=1;dive.cen=[320,210];diveAnim=null;
  mountNodes(TURNS[i].steps);
  mode='done';nv.settle();setStatus(stateById(TURNS[i].outcome==='failed'?'failed':'settled'));
  const sc=scrubEl.querySelector('input');sc.value=1000;
  request();
}
function closeBrain(silent){
  if(openIdx<0)return;
  const w=document.getElementById('work'+openIdx);w.classList.remove('open');w.querySelector('.chev').textContent='▸';
  const park=document.getElementById('park');park.appendChild(stage);park.appendChild(tickerEl);park.appendChild(scrubEl);
  openIdx=-1;mode='done';hotZone=null;
  if(!silent)setStatus(null);
}
function currentState(now){
  const t=TURNS[openIdx];
  if(mode==='working'||mode==='scrub'){
    const tt=mode==='working'?(now-workStart)/1000:scrubT;
    let a=-1;nv.fire.forEach((f,i)=>{if(f<=tt)a=i;});
    const fam=a>=0?t.steps[a].fam:'think';
    return {st:stateById(FAM2STATE[fam]),t:tt};
  }
  return {st:stateById(t.outcome==='failed'?'failed':'settled'),t:(now-workStart)/1000};
}
let lastDraw=0;
function frame(now){
  raf=0;if(!hero||openIdx<0){loopRunning=false;renderPerf();return;}
  if(!diveAnim&&mode!=='scrub'&&now-lastDraw<30){raf=requestAnimationFrame(frame);return;}
  lastDraw=now;
  const t=TURNS[openIdx];
  const cs=currentState(now);
  if(mode==='working'&&cs.t>nv.endT+.3)finishLive();
  if(mode==='working'||mode==='scrub'){nv.paint(cs.t);}
  const f=Hero.frameFor(reduce?Object.assign({},cs.st,{motion:'still'}):cs.st,mode==='scrub'?cs.t+.0001:cs.t,themeKey,{family:t.model.family,ctxFill:.42,ctxEst:false});
  hero.st.theme=themeKey;
  for(let i=0;i<f.inten.length;i++)hero.st.inten[i]=f.inten[i];
  hero.st.toneOv=f.tone;hero.st.sweep=f.sweep;hero.st.sweepAmt=f.sweepAmt;hero.st.sweepTone=f.sweepTone;hero.st.crunch=f.crunch;hero.st.time=cs.t;
  const e=Hero.effortSpec(t.model.effort);hero.st.effort=e.effort;hero.st.hollow=e.hollow;hero.st.rainbow=e.rainbow;
  hero.st.ripple=mode==='working'||mode==='scrub'?1:0;
  if(mode==='working'||mode==='scrub'){let a=-1;nv.fire.forEach((x,i)=>{if(x<=cs.t)a=i;});if(a>=0){const c=ZC[t.steps[a].fam];hero.st.act=[c[0]/640,1-c[1]/420];}}
  if(mode==='working'){
    let cap='Thinking…';t.steps.forEach((s,i)=>{if(s.fam==='say'&&nv.fire[i]<=cs.t)cap=s.text;});
    if(tickerEl.dataset.cap!==cap){tickerEl.dataset.cap=cap;tickerEl.innerHTML='<span class="tk"></span><span class="tx"></span>';tickerEl.querySelector('.tx').textContent=cap;}
    setStatus(cs.st);
  }
  if(hotZone&&mode==='done'){const zi=Hero.ZORD.indexOf(hotZone);for(let i=0;i<6;i++)hero.st.inten[i]=.3;hero.st.inten[zi]=1.2;hero.st.inten[6]=.6;}
  if(hero.st.provZones&&mode==='done'){for(let i=0;i<6;i++)hero.st.inten[i]=hero.st.provZones.has(Hero.ZORD[i])?1.15:.22;hero.st.inten[6]=.5;}
  const diving=stepDive(now);hero.draw();
  const dt=now-lastFrame;if(dt>0&&dt<500)fps=fps*.8+(1000/dt)*.2;lastFrame=now;
  loopRunning=mode==='working'||mode==='scrub'||diving;
  if(loopRunning)raf=requestAnimationFrame(frame);else fps=0;
  renderPerf();
}
function request(){if(!hero||openIdx<0)return;if(!raf){lastFrame=performance.now();raf=requestAnimationFrame(frame);}}
function renderPerf(){perf.innerHTML=`<span><b>13</b> textures · ${hero.W}×${hero.H} · one open brain</span><span>frames drawn <b>${hero.st.frames}</b></span><span class="${loopRunning?'live':''}">${loopRunning?'drawing · '+Math.round(fps)+' fps':'idle · draws nothing'}</span><span>${openIdx<0?'no brain open':'open: turn '+(openIdx+1)}</span>`;}
function setPress(id){['s-live','s-done','s-line'].forEach(k=>document.getElementById(k).setAttribute('aria-pressed',k===id));}
function finishLive(){
  mode='done';nv.settle();tickerEl.innerHTML='';tickerEl.dataset.cap='';setStatus(stateById('settled'));setPress('s-done');
  const total=words(openIdx).length;let n=0;clearInterval(streamTimer);showWords(openIdx,0);
  streamTimer=setInterval(()=>{n+=2;showWords(openIdx,n);if(n>=total)clearInterval(streamTimer);},60);
}
function lastGood(){for(let i=TURNS.length-1;i>=0;i--)if(TURNS[i].outcome==='settled')return i;return 0;}
function latestLive(){
  clearInterval(streamTimer);const last=TURNS.length-1;if(openIdx!==last)openBrain(last);
  showWords(last,0);mode='working';workStart=performance.now();nv.settle();setPress('s-live');
  if(reduce){mode='done';nv.settle();showWords(last,999);setPress('s-done');}
  request();
}
function latestDone(){clearInterval(streamTimer);const last=TURNS.length-1;if(openIdx!==last)openBrain(last);mode='done';nv.settle();showWords(last,999);setStatus(stateById('settled'));setPress('s-done');workStart=performance.now();request();}
function latestLine(){clearInterval(streamTimer);closeBrain();showWords(TURNS.length-1,999);setPress('s-line');setStatus(null);}
function setWidth(phone){chat.classList.toggle('phone',phone);document.getElementById('w-desk').setAttribute('aria-pressed',!phone);document.getElementById('w-phone').setAttribute('aria-pressed',phone);if(openIdx>=0){const i=openIdx;closeBrain(true);openBrain(i);}}

(async function(){
  const park=document.createElement('div');park.id='park';park.style.display='none';document.body.appendChild(park);
  stage=document.createElement('div');stage.className='hstage';stage.innerHTML='<div class="inner"><canvas id="cInt"></canvas></div><div class="nodes"></div><canvas id="cFront"></canvas>';
  nodesHost=stage.querySelector('.nodes');tickerEl=document.createElement('div');tickerEl.className='ticker';tickerEl.setAttribute('aria-live','polite');
  scrubEl=document.createElement('div');scrubEl.className='scrub';scrubEl.innerHTML='<button type="button" class="pl" aria-label="Replay">▶</button><input type="range" min="0" max="1000" value="1000" aria-label="Scrub through the turn"><span class="sl"></span>';
  park.appendChild(stage);park.appendChild(tickerEl);park.appendChild(scrubEl);
  try{hero=await Hero.create({assets:ASSETS,interior:stage.querySelector('#cInt'),front:stage.querySelector('#cFront')});}
  catch(e){body.insertAdjacentHTML('afterbegin','<p style="color:var(--ink2)">WebGL2 is needed to draw this artboard: '+String(e.message).replace(/</g,'&lt;')+'</p>');return;}
  const sc=scrubEl.querySelector('input'),sl=scrubEl.querySelector('.sl');
  sc.addEventListener('input',()=>{mode='scrub';scrubT=sc.value/1000*(nv.endT-.4);const t=TURNS[openIdx];const a=nv.fire.reduce((m,f,i)=>f<=scrubT?i:m,-1);sl.textContent=a>=0&&t.steps[a].at?t.steps[a].at:'';request();});
  sc.addEventListener('change',()=>{if(+sc.value>=995){mode='done';nv.settle();}request();});
  scrubEl.querySelector('.pl').addEventListener('click',()=>{if(openIdx<0)return;clearInterval(streamTimer);mode='working';workStart=performance.now();nv.settle();setPress('s-live');request();});
  buildLines();
  document.querySelectorAll('.th').forEach(b=>b.onclick=()=>applyTheme(b.dataset.t));
  document.getElementById('s-live').onclick=latestLive;document.getElementById('s-done').onclick=latestDone;document.getElementById('s-line').onclick=latestLine;
  document.getElementById('w-desk').onclick=()=>setWidth(false);document.getElementById('w-phone').onclick=()=>setWidth(true);
  applyTheme(P.get('theme')||'matrix');
  if(P.get('width')==='phone')setWidth(true);
  const st=P.get('state');
  if(st==='line')latestLine();else if(st==='live'){latestLive();if(P.get('t')!==null)workStart=performance.now()-parseFloat(P.get('t'))*1000;}else if(P.get('open')){openBrain(parseInt(P.get('open'),10));workStart=performance.now();showWords(openIdx,999);}else{latestDone();}
  showWords(TURNS.length-1,st==='live'?0:999);
  if(P.get('hover')!==null&&nv)nv.setHot(parseInt(P.get('hover'),10)-1);
  if(P.get('prov')&&nv){const p=document.querySelector('.prov[data-m*="'+P.get('prov')+'"]');if(p)provOn(openIdx,p.dataset.m);}
  if(P.get('rows')==='1'){document.querySelectorAll('.work .rows')[0].click();}
  renderPerf();window.__hero=hero;window.__heroReady=true;
})();
