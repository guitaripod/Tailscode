const Neural=(function(){
let uid=0;
const NS='http://www.w3.org/2000/svg';
const FAM={
  think:{label:'PLAN',word:'Thinking',sub:'reasoning',tone:'var(--ink)'},
  sense:{label:'SENSE',word:'Reading',sub:'Read · Grep · Glob · Web',tone:'var(--info)'},
  act:{label:'ACT',word:'Editing',sub:'Edit · Write',tone:'var(--accent)'},
  shell:{label:'SHELL',word:'Running',sub:'Bash',tone:'var(--special)'},
  delegate:{label:'DELEGATE',word:'Delegating',sub:'Task · Skill · Workflow',tone:'var(--ink2)'},
  say:{label:'SAY',word:'Said',sub:'the agent speaking mid-turn',tone:'color-mix(in srgb,var(--accent) 45%,var(--info))'}
};
const CAP=19;
const ORDER=['think','sense','act','shell','delegate'];
const ZONES={think:[456,150],act:[348,104],sense:[204,162],shell:[240,284],delegate:[396,250],say:[520,306]};
const HEAD='M196,412 L196,372 L136,322 L98,268 L80,196 L100,118 L162,56 L258,24 L372,16 L484,40 L556,98 L580,160 L614,184 L620,238 L586,254 L584,296 L544,330 L486,346 L436,352 L384,374 L384,412 Z';
const DOME='M128,212 C112,132 176,72 268,54 C366,38 462,52 512,108 C540,142 534,196 512,234 C494,260 452,268 420,270 L334,298 C296,314 254,322 214,314 C168,302 134,266 128,212 Z';
const LANES={think:84,sense:142,act:200,shell:258,delegate:316};

function S(tag,attrs,parent){
  const e=document.createElementNS(NS,tag);
  for(const k in attrs) e.setAttribute(k,attrs[k]);
  if(parent) parent.appendChild(e);
  return e;
}
function esc(s){return String(s).replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));}
function clamp(v,a,b){return Math.max(a,Math.min(b,v));}
function f(n){return n.toFixed(1);}

function shapeD(fam,r){
  if(fam==='sense'){const k=r*1.2;return `M0,${-k}L${k},0L0,${k}L${-k},0Z`;}
  if(fam==='say'){const w=r*1.3,h=r*.95,c=r*.5;return `M${f(-w+c)},${f(-h)}L${f(w-c)},${f(-h)}Q${f(w)},${f(-h)} ${f(w)},${f(-h+c)}L${f(w)},${f(h-c)}Q${f(w)},${f(h)} ${f(w-c)},${f(h)}L${f(-w*.15)},${f(h)}L${f(-w*.55)},${f(h+r*.65)}L${f(-w*.5)},${f(h)}L${f(-w+c)},${f(h)}Q${f(-w)},${f(h)} ${f(-w)},${f(h-c)}L${f(-w)},${f(-h+c)}Q${f(-w)},${f(-h)} ${f(-w+c)},${f(-h)}Z`;}
  if(fam==='act'){const k=r*.9,c=r*.42;return `M${-k},${-k}L${k-c},${-k}L${k},${-k+c}L${k},${k}L${-k+c},${k}L${-k},${k-c}Z`;}
  if(fam==='shell'){const k=r*1.12;let d='';for(let i=0;i<6;i++){const a=Math.PI/3*i;d+=(i?'L':'M')+f(Math.cos(a)*k)+','+f(Math.sin(a)*k);}return d+'Z';}
  if(fam==='delegate'){const k=r*1.12;let d='';for(let i=0;i<8;i++){const a=Math.PI/4*i+Math.PI/8;d+=(i?'L':'M')+f(Math.cos(a)*k)+','+f(Math.sin(a)*k);}return d+'Z';}
  return `M${-r},0a${r},${r} 0 1,0 ${2*r},0a${r},${r} 0 1,0 ${-2*r},0Z`;
}

function slot(k,sp){
  if(k===0) return [0,0];
  let ring=1,count=6,idx=k-1;
  while(idx>=count){idx-=count;ring++;count=6*ring;}
  const a=(idx/count)*Math.PI*2+(ring%2?Math.PI/6:0)-Math.PI/2;
  return [Math.cos(a)*ring*sp,Math.sin(a)*ring*sp];
}

function route(a,b){
  const dx=b.x-a.x,dy=b.y-a.y,ax=Math.abs(dx),ay=Math.abs(dy);
  if(ax<1||ay<1) return `M${f(a.x)},${f(a.y)}L${f(b.x)},${f(b.y)}`;
  const sx=Math.sign(dx),sy=Math.sign(dy);
  if(ax>=ay) return `M${f(a.x)},${f(a.y)}L${f(a.x+sx*ay)},${f(b.y)}L${f(b.x)},${f(b.y)}`;
  return `M${f(a.x)},${f(a.y)}L${f(b.x)},${f(a.y+sy*ax)}L${f(b.x)},${f(b.y)}`;
}

function analyse(steps){
  const groups=[],byMsg=new Map();
  steps.forEach((s,i)=>{
    s.i=i;
    let g=byMsg.get(s.msg);
    if(!g){g={msg:s.msg,at:s.at,ids:[]};byMsg.set(s.msg,g);groups.push(g);}
    g.ids.push(i);
    s.g=groups.indexOf(g);
  });
  const ties=new Map();
  steps.forEach(s=>{
    if(!s.key) return;
    if(!ties.has(s.key)) ties.set(s.key,{key:s.key,kind:s.keyKind||'path',ids:[]});
    ties.get(s.key).ids.push(s.i);
  });
  const edges=[];
  for(let g=1;g<groups.length;g++){
    const P=groups[g-1].ids,N=groups[g].ids;
    if(P.length>1&&N.length>1){
      const via={via:true,g,ids:P.concat(N)};
      P.forEach(p=>edges.push({a:p,b:via,g,part:0}));
      N.forEach(n=>edges.push({a:via,b:n,g,part:1}));
    }else P.forEach(p=>N.forEach(n=>edges.push({a:p,b:n,g,part:0})));
  }
  return {groups,edges,ties:[...ties.values()].filter(t=>t.ids.length>1)};
}

function parseDome(){
  const t=DOME.match(/[MLCZ]|-?\d+\.?\d*/g),pts=[];let i=0,cur=null;
  while(i<t.length){
    if(t[i]==='M'||t[i]==='L'){cur=[+t[i+1],+t[i+2]];pts.push(cur);i+=3;}
    else if(t[i]==='C'){const c1=[+t[i+1],+t[i+2]],c2=[+t[i+3],+t[i+4]],e=[+t[i+5],+t[i+6]];for(let k=1;k<=24;k++){const u=k/24,v=1-u;pts.push([v*v*v*cur[0]+3*v*v*u*c1[0]+3*v*u*u*c2[0]+u*u*u*e[0],v*v*v*cur[1]+3*v*v*u*c1[1]+3*v*u*u*c2[1]+u*u*u*e[1]]);}cur=e;i+=7;}
    else i++;
  }
  return pts;
}
const DOMEPTS=parseDome();
function inPoly(p,x,y){let c=false;for(let i=0,j=p.length-1;i<p.length;j=i++){if((p[i][1]>y)!==(p[j][1]>y)&&x<(p[j][0]-p[i][0])*(y-p[i][1])/(p[j][1]-p[i][1])+p[i][0])c=!c;}return c;}
const ZONE_SLOTS=(function(){
  const out={};
  Object.keys(ZONES).forEach(z=>{
    const sp=z==='say'?24:28,n=z==='say'?7:19,list=[];
    for(let k=0;k<n;k++){
      const o=slot(k,sp),x=ZONES[z][0]+o[0],y=ZONES[z][1]+o[1];
      const ok=z==='say'?(((x-520)/48)**2+((y-306)/30)**2<=1):[[0,0],[10,0],[-10,0],[0,10],[0,-10]].every(d=>inPoly(DOMEPTS,x+d[0],y+d[1]));
      if(ok)list.push(o);
    }
    out[z]=list;
  });
  return out;
})();

function layoutCortex(steps,spacing,bare){
  const cnt={};
  return steps.map(s=>{
    const n=cnt[s.fam]||0;cnt[s.fam]=n+1;
    if(bare){const list=ZONE_SLOTS[s.fam],o=list[Math.min(n,list.length-1)],c=ZONES[s.fam];return {x:c[0]+o[0],y:c[1]+o[1]};}
    const k=Math.min(n,CAP-1);
    const sp=typeof spacing==='object'?(spacing[s.fam]||spacing.def):spacing;
    const c=ZONES[s.fam],o=slot(k,sp);
    return {x:c[0]+o[0],y:c[1]+o[1]};
  });
}

function layoutLanes(steps,an){
  const x0=124,n=an.groups.length,gap=clamp((860-x0)/Math.max(1,n-1),62,84);
  const pos=steps.map(()=>null);
  an.groups.forEach((g,gi)=>{
    const byFam={};
    g.ids.forEach(i=>{(byFam[steps[i].fam]=byFam[steps[i].fam]||[]).push(i);});
    for(const fam in byFam){
      const ids=byFam[fam];
      ids.forEach((i,k)=>{pos[i]={x:x0+gi*gap+(k-(ids.length-1)/2)*27,y:LANES[fam]};});
    }
  });
  return {pos,gap,x0,width:x0+gap*(n-1)+70};
}

function toolMix(steps){
  const order=[],cnt={};
  steps.filter(s=>s.fam!=='think'&&s.fam!=='say').forEach(s=>{if(!cnt[s.tool]){cnt[s.tool]=0;order.push(s.tool);}cnt[s.tool]++;});
  return order.map(t=>cnt[t]>1?`${t}×${cnt[t]}`:t).join(' ');
}
function toolCount(steps){return steps.filter(s=>s.fam!=='think'&&s.fam!=='say').length;}
function diffTally(steps){
  let a=0,d=0;steps.forEach(s=>{if(s.diff){a+=s.diff[0];d+=s.diff[1];}});return [a,d];
}

function shapeSvg(fam,size){
  const r=size/2-2,c=size/2;
  return `<svg width="${size}" height="${size}" viewBox="0 0 ${size} ${size}" class="f-${fam}" aria-hidden="true"><g transform="translate(${c},${c})"><path d="${shapeD(fam,r*.85)}" fill="color-mix(in srgb,var(--t) 17%,var(--panel))" stroke="var(--t)" stroke-width="1.6" stroke-linejoin="round"/></g></svg>`;
}

function glyph(steps,opt){
  opt=opt||{};
  const size=opt.size||30,cnt={},bad={},last=steps[steps.length-1];
  steps.forEach(s=>{cnt[s.fam]=(cnt[s.fam]||0)+1;if(s.status==='fail'&&!s.recovered)bad[s.fam]=true;});
  let dots='';
  ORDER.concat(['say']).forEach(fam=>{
    const n=cnt[fam];if(!n) return;
    const c=ZONES[fam],r=44+12*Math.min(n,4);
    const live=opt.live&&last&&last.fam===fam?' live':'';
    dots+=`<circle class="gl-d${live}" cx="${c[0]}" cy="${c[1]}" r="${r}" fill="${FAM[fam].tone}" opacity="${f((.62+.1*Math.min(n,4))*(opt.dim?0.4:1))}"/>`;
    if(opt.activeZone===fam) dots+=`<circle cx="${c[0]}" cy="${c[1]}" r="${r+34}" fill="none" stroke="${opt.ringColor||'var(--accent)'}" stroke-width="15"/>`;
    if(bad[fam]) dots+=`<circle cx="${c[0]}" cy="${c[1]}" r="${r+16}" fill="none" stroke="var(--danger)" stroke-width="18"/>`;
  });
  const h=Math.round(size*368/566);
  return `<svg class="gl-svg" viewBox="68 6 566 368" width="${size}" height="${h}" aria-hidden="true"><path class="gl-out" d="${HEAD}"/>${dots}<circle class="gl-eyeg" cx="586" cy="216" r="46" style="fill:${opt.eyeColor||'var(--accent)'};opacity:.28"/><path class="gl-eye${opt.live?' live':''}" style="${opt.eyeColor?'fill:'+opt.eyeColor:''}" d="M538,190 L622,187 L627,238 L546,247Z"/></svg>`;
}

function ganglionCard(fam,members,ids){
  const mix=toolMix(members.map(m=>Object.assign({},m,{fam:'x'})));
  const bad=members.filter(m=>m.status==='fail').length;
  return `<div class="hd">${shapeSvg(fam,20)}<b>${FAM[fam].label} ganglion</b><span class="st ok">${members.length} steps</span></div><div class="arg">${esc(mix)}</div><div class="ft">steps ${ids[0]+1} to ${ids[ids.length-1]+1} · ${bad?bad+' failed · ':''}the zone is full, so the rest gather here; Rows lists every one</div>`;
}

function statusWord(s){return {ok:'done',fail:'failed',run:'running',stopped:'stopped',wait:'waiting for you',stall:'stalled'}[s.status]||'done';}

function cardHtml(s,steps,an){
  const total=steps.length;
  let body='';
  if(s.fam==='think'||s.fam==='say') body+=`<div class="thought">${esc(s.text)}</div>`;
  else{
    body+=`<div class="arg">${esc(s.arg)}</div>`;
    if(s.diff) body+=`<div class="diffstat"><span class="a">+${s.diff[0]}</span> <span class="d">−${s.diff[1]}</span></div>`;
    if(s.out&&s.out.length) body+=`<pre class="${s.status==='fail'?'bad':''}">${esc(s.out.join('\n'))}</pre>`;
    if(s.spawn) body+=`<div class="diffstat">${esc(s.spawn)}</div>`;
  }
  const facts=[];
  const g=an.groups[s.g];
  if(g.ids.length>1) facts.push(`${g.ids.length} calls in one message`);
  else facts.push(`message ${s.g+1}`);
  if(g.at) facts.push(g.at);
  const tie=an.ties.find(t=>t.ids.includes(s.i));
  if(tie){
    const others=tie.ids.filter(i=>i!==s.i).map(i=>i+1);
    facts.push(`<i>${tie.kind==='cmd'?'same command':'same file'}</i> as ${others.join(', ')}`);
  }
  return `<div class="hd">${shapeSvg(s.fam,20)}<b>${esc(s.tool||FAM[s.fam].word)}</b><span class="st ${s.status}">${statusWord(s)}</span></div>${body}<div class="ft">step ${s.i+1} of ${total} · ${facts.join(' · ')}</div>`;
}

function mount(host,opt){
  const steps=opt.steps,layout=opt.layout||'cortex',an=analyse(steps),id=++uid;
  const narrow=host.clientWidth>0&&host.clientWidth<480;
  let pos,vb,r=Math.max(opt.r||11,narrow?17:0),lay=null;
  const spacing=typeof opt.spacing==='object'?opt.spacing:Math.max(opt.spacing||31,narrow?40:0);
  if(layout==='lanes'){lay=layoutLanes(steps,an);pos=lay.pos;vb=[0,0,lay.width,LANES.delegate+an.ties.length*17+70];}
  else{pos=layoutCortex(steps,spacing,!!opt.bare);vb=[0,0,640,420];}
  an.edges.forEach(e=>{
    [e.a,e.b].forEach(v=>{
      if(typeof v==='object'){
        const pts=v.ids.map(i=>pos[i]);
        v.x=pts.reduce((a,p)=>a+p.x,0)/pts.length;
        v.y=pts.reduce((a,p)=>a+p.y,0)/pts.length;
      }
    });
  });
  const at=v=>typeof v==='object'?v:pos[v];

  host.classList.add('nv');
  host.querySelectorAll('.nv-svg,.tip').forEach(n=>n.remove());
  const svg=S('svg',{viewBox:vb.join(' '),class:'nv-svg '+layout,role:'group','aria-label':opt.label||'Agent steps'});
  host.appendChild(svg);
  const defs=S('defs',{},svg);
  const pat=S('pattern',{id:'dots'+id,width:14,height:14,patternUnits:'userSpaceOnUse'},defs);
  S('circle',{cx:1.5,cy:1.5,r:.9,fill:'var(--rule2)'},pat);
  const grad=S('linearGradient',{id:'glass'+id,x1:0,y1:0,x2:0,y2:1},defs);
  S('stop',{offset:0,'stop-color':'var(--ink)','stop-opacity':.07},grad);
  S('stop',{offset:1,'stop-color':'var(--ink)','stop-opacity':0},grad);

  const used={};steps.forEach(s=>used[s.fam]=true);
  const zoneOrder=ORDER.concat(used.say||opt.say?['say']:[]);
  const zoneCount={},gangs={};
  steps.forEach((s,i)=>{const k=zoneCount[s.fam]||0;zoneCount[s.fam]=k+1;if(layout==='cortex'&&k>=(opt.bare?ZONE_SLOTS[s.fam].length:CAP)-1)(gangs[s.fam]=gangs[s.fam]||[]).push(i);});
  for(const fam in gangs)if(gangs[fam].length<2)delete gangs[fam];
  const rep=steps.map((s,i)=>{const g=gangs[s.fam];return g&&g.includes(i)?g[0]:i;});
  const STEP=opt.step||0.62,PD=Math.min(0.42,STEP*0.9);
  host.classList.toggle('many',steps.length>60);
  let eyeEl=null;
  if(layout==='cortex'&&!opt.bare){
    S('ellipse',{class:'aura',cx:340,cy:196,rx:270,ry:170},svg);
    S('path',{class:'hd-out',d:HEAD},svg);
    S('path',{class:'hd-bevel',d:HEAD,transform:'translate(350 214) scale(.968) translate(-350 -214)'},svg);
    [['M196,372 L230,356 L330,356 L384,374'],['M162,56 L190,92'],['M484,40 L470,74'],['M580,160 L546,170 L546,236 L586,254'],['M112,240 L146,240'],['M108,254 L146,254'],['M118,268 L150,268'],['M214,372 L214,412'],['M366,380 L366,412'],['M520,298 L552,298'],['M512,310 L544,310'],['M500,322 L532,322']]
      .forEach(d=>S('path',{class:'hd-seam',d:d[0]},svg));
    [[162,56],[484,40],[580,160],[436,352],[100,118],[136,322],[620,238],[196,372],[384,374]].forEach(p=>S('circle',{class:'hd-riv',cx:p[0],cy:p[1],r:3},svg));
    S('circle',{class:'hd-ear',cx:340,cy:336,r:19},svg);
    S('circle',{class:'hd-ear',cx:340,cy:336,r:9},svg);
    S('path',{class:'visor',d:'M556,204 L606,202 L610,224 L562,230Z'},svg);
    eyeEl=S('path',{class:'eye '+(opt.eye||'done'),d:'M562,210 L600,208 L603,219 L566,223Z'},svg);
    S('path',{class:'dome',d:DOME,style:`fill:url(#dots${id})`},svg);
    S('path',{class:'dome',d:DOME,style:`fill:url(#glass${id});stroke:none`},svg);
    zoneOrder.forEach(fam=>{
      const c=ZONES[fam],g=S('g',{class:'f-'+fam},svg),wr=fam==='say'?[56,38]:[66,58];
      S('ellipse',{class:'well'+(used[fam]?' on':''),cx:c[0],cy:c[1],rx:wr[0],ry:wr[1]},g);
      const t=S('text',{class:'zl'+(used[fam]?' on':''),x:c[0],y:c[1]-wr[1]-8},g);
      t.textContent=FAM[fam].label;
    });
  }else if(layout==='cortex'){
    zoneOrder.forEach(fam=>{
      const c=ZONES[fam],g=S('g',{class:'f-'+fam},svg),wr=fam==='say'?[56,38]:[66,58];
      const t=S('text',{class:'zl'+(used[fam]?' on':''),x:c[0],y:c[1]-wr[1]-8,'data-zone':fam},g);
      t.textContent=FAM[fam].label;
    });
  }else{
    ORDER.forEach(fam=>{
      const y=LANES[fam],g=S('g',{class:'f-'+fam},svg);
      S('line',{class:'rail',x1:96,x2:lay.width-24,y1:y,y2:y},g);
      const t=S('text',{class:'rail-l',x:12,y:y+3.5,style:used[fam]?'fill:var(--t)':''},g);
      t.textContent=FAM[fam].label;
    });
    an.groups.forEach((g,gi)=>{
      const x=lay.x0+gi*lay.gap;
      S('line',{class:'colline',x1:x,x2:x,y1:LANES.think-30,y2:LANES.delegate+26},svg);
      if(g.at){const t=S('text',{class:'tick',x:x,y:LANES.think-40},svg);t.textContent=g.at;}
    });
  }

  const tieLabels=[];
  const tieEls=an.ties.map((t,ti)=>{
    const g=S('g',{class:'tie'},svg);
    const pts=t.ids.map(i=>pos[i]);
    if(layout==='lanes'){
      const y=LANES.delegate+54+ti*17,xs=pts.map(p=>p.x),xa=Math.min(...xs),xb=Math.max(...xs);
      pts.forEach(p=>{S('path',{d:`M${f(p.x)},${f(p.y+r+2)}L${f(p.x)},${y}`},g);S('circle',{cx:f(p.x),cy:y,r:2.6},g);});
      S('path',{d:`M${f(xa)},${y}L${f(xb)},${y}`},g);
      tieLabels.push({x:xb+10,y:y+3.4,text:t.key});
    }else{
      for(let k=1;k<pts.length;k++){
        const a=pts[k-1],b=pts[k],mx=(a.x+b.x)/2,my=(a.y+b.y)/2,dx=b.x-a.x,dy=b.y-a.y,len=Math.hypot(dx,dy)||1;
        const cx=mx-dy/len*len*.28,cy=my+dx/len*len*.28;
        S('path',{d:`M${f(a.x)},${f(a.y)}Q${f(cx)},${f(cy)} ${f(b.x)},${f(b.y)}`},g);
      }
    }
    return g;
  });

  const tieLabelG=S('g',{},svg);
  tieLabels.forEach(l=>{const tx=S('text',{class:'tie-l',x:f(l.x),y:f(l.y)},tieLabelG);tx.textContent=l.text;});
  const seenPaths=new Set();
  const noop={classList:{toggle(){}},style:{}};
  const edgeEls=an.edges.map(e=>{
    const a=at(e.a),b=at(e.b),tgt=typeof e.b==='object'?steps[e.a].fam:steps[e.b].fam,d=route(a,b);
    if(seenPaths.has(d)) return {e,base:noop,pulse:noop,g:noop};
    seenPaths.add(d);
    const g=S('g',{style:`--tt:${FAM[tgt].tone}`},svg);
    const base=S('path',{class:'e',d},g);
    const pulse=S('path',{class:'p',d,pathLength:100},g);
    return {e,base,pulse,g};
  });
  const viaEls=[];
  an.edges.forEach(e=>{
    [e.a,e.b].forEach(v=>{
      if(typeof v==='object'&&!viaEls.find(x=>x.v===v)){
        const c=S('circle',{class:'via',cx:f(v.x),cy:f(v.y),r:3.4,style:`--tt:${FAM[steps[v.ids[v.ids.length-1]].fam].tone}`},svg);
        viaEls.push({v,c});
      }
    });
  });

  let tipEl=null,tipStub=null;
  const nodeEls=steps.map((s,i)=>{
    const p=pos[i];
    const g=S('g',{class:`n f-${s.fam} ${s.status==='fail'?'fail':''} ${s.status==='run'?'run':''} ${s.status==='stopped'?'stopped':''} ${s.status==='wait'?'wait':''} ${s.status==='stall'?'stall':''}`,transform:`translate(${f(p.x)},${f(p.y)})`,tabindex:0,role:'img','aria-label':`Step ${i+1}: ${s.tool||FAM[s.fam].word}, ${statusWord(s)}`},svg);
    const lead=gangs[s.fam]&&gangs[s.fam][0]===i,hidden=gangs[s.fam]&&gangs[s.fam].includes(i)&&!lead;
    if(hidden) g.style.display='none';
    if(s.fam==='think') S('circle',{class:'halo',r:r+4},g);
    S('path',{class:'shape',d:shapeD(lead?'think':s.fam,lead?r*1.45:r)},g);
    if(s.fam==='delegate'&&!lead) S('circle',{class:'inner',r:r*.84},g);
    const num=S('text',{class:'num'},g);num.textContent=lead?'+'+gangs[s.fam].length:(s.mark||i+1);
    if(lead)g.classList.add('gang');
    if(s.status==='fail'){S('path',{class:'mark',d:`M${r*.55},${-r*1.15}l${r*.7},${-r*.7}M${r*1.25},${-r*1.15}l${-r*.7},${-r*.7}`},g);}
    return g;
  });

  tipEl=document.createElement('div');tipEl.className='tip';tipEl.hidden=true;host.appendChild(tipEl);

  const endT=0.4+an.groups.length*STEP+0.9;
  const fire=steps.map(s=>0.4+s.g*STEP+an.groups[s.g].ids.indexOf(s.i)*Math.min(0.07,STEP/6));
  Object.values(gangs).forEach(g=>{const m=Math.min(...g.map(i=>fire[i]));g.forEach(i=>fire[i]=m);});
  edgeEls.forEach(x=>{
    const gt=0.4+x.e.g*STEP;
    if(typeof x.e.b==='object'){x.t1=gt-PD*0.57;x.t0=x.t1-PD*0.8;}
    else if(typeof x.e.a==='object'){x.t1=gt;x.t0=gt-PD*0.57;}
    else{x.t1=gt;x.t0=gt-PD;}
  });

  const reduce=window.matchMedia&&matchMedia('(prefers-reduced-motion: reduce)').matches;
  let live=!!opt.live,raf=0,pinned=-1;

  function paint(t){
    steps.forEach((s,i)=>{
      const on=t>=fire[i],el=nodeEls[i],fl=on?clamp(1-(t-fire[i])/0.6,0,1):0;
      el.classList.toggle('dim',!on);
      el.style.filter=fl>0.03?`drop-shadow(0 0 ${f(3+9*fl)}px var(--t))`:'';
    });
    edgeEls.forEach(x=>{
      const p=(t-x.t0)/(x.t1-x.t0);
      x.base.classList.toggle('lit',p>=1);
      if(p>0&&p<1){x.pulse.style.opacity=1;x.pulse.style.strokeDashoffset=f(10-p*112);}
      else x.pulse.style.opacity=0;
    });
    viaEls.forEach(x=>x.c.classList.toggle('lit',t>=0.4+x.v.g*STEP-PD*0.57));
    tieEls.forEach(g=>{g.style.opacity=t>=endT-0.5?1:0;});
    tieLabelG.style.opacity=t>=endT-0.5?1:0;
    if(eyeEl&&opt.eye!=='fail') eyeEl.setAttribute('class','eye '+(t>=endT?(live?'live':'done'):(t>0.2?'live':'')));
    paintTip(t>=endT);
  }
  function paintTip(done){
    if(tipStub){tipStub.forEach(n=>n.remove());tipStub=null;}
    if(!live||!done) return;
    const lastG=an.groups[an.groups.length-1],ids=lastG.ids,p=pos[ids[ids.length-1]];
    let dx=1,dy=0;
    if(layout==='cortex'){
      const zc=ZONES[steps[ids[ids.length-1]].fam];
      let vx=p.x-zc[0],vy=p.y-zc[1];
      if(Math.hypot(vx,vy)<1){vx=0;vy=1;}
      const l=Math.hypot(vx,vy);dx=vx/l;dy=vy/l;
    }
    const x1=p.x+dx*(r+3),y1=p.y+dy*(r+3),x2=p.x+dx*(r+30),y2=p.y+dy*(r+30);
    const st=S('path',{class:'tipstub',d:`M${f(x1)},${f(y1)}L${f(x2)},${f(y2)}`},svg);
    const dt=S('circle',{class:'tipdot',cx:f(x2),cy:f(y2),r:3.6},svg);
    tipStub=[st,dt];
  }

  function play(){
    cancelAnimationFrame(raf);
    if(reduce){paint(Infinity);return;}
    const t0=performance.now();
    (function step(now){
      const t=(now-t0)/1000;
      paint(t);
      if(t<endT+0.7) raf=requestAnimationFrame(step); else paint(Infinity);
    })(t0);
  }
  function settle(){cancelAnimationFrame(raf);paint(Infinity);}

  function setSet(ids){
    const on=new Set(ids);
    svg.classList.toggle('has-hot',on.size>0);
    nodeEls.forEach((n,k)=>n.classList.toggle('hot',on.has(k)));
    edgeEls.forEach(x=>{
      const ia=typeof x.e.a==='object'?-1:x.e.a,ib=typeof x.e.b==='object'?-1:x.e.b;
      const t=on.size>0&&((ia>=0&&on.has(ia))||(ib>=0&&on.has(ib)));
      x.g.classList.toggle('hot',!!t);x.base.classList.toggle('hot',!!t);
    });
    viaEls.forEach(x=>x.c.classList.toggle('hot',false));
    tieEls.forEach(g=>g.classList.toggle('hot',false));
    tipEl.hidden=true;
  }
  function setHot(i){
    if(opt.onHot)opt.onHot(i>=0?steps[i]:null,i);
    svg.classList.toggle('has-hot',i>=0);
    nodeEls.forEach((n,k)=>n.classList.toggle('hot',k===i));
    edgeEls.forEach(x=>{
      const ia=typeof x.e.a==='object'?-1:x.e.a,ib=typeof x.e.b==='object'?-1:x.e.b;
      const via=typeof x.e.a==='object'?x.e.a:typeof x.e.b==='object'?x.e.b:null;
      const same=v=>v>=0&&i>=0&&rep[v]===rep[i];
      const touches=i>=0&&(same(ia)||same(ib)||(via&&via.ids.some(j=>rep[j]===rep[i])));
      x.g.classList.toggle('hot',!!touches);
      x.base.classList.toggle('hot',!!touches);
    });
    viaEls.forEach(x=>x.c.classList.toggle('hot',i>=0&&x.v.ids.some(j=>rep[j]===rep[i])));
    tieEls.forEach((g,k)=>g.classList.toggle('hot',i>=0&&an.ties[k].ids.some(j=>rep[j]===rep[i])));
    if(i<0){tipEl.hidden=true;return;}
    tipEl.className='tip f-'+steps[i].fam;
    tipEl.innerHTML=gangs[steps[i].fam]&&gangs[steps[i].fam][0]===i?ganglionCard(steps[i].fam,gangs[steps[i].fam].map(j=>steps[j]),gangs[steps[i].fam]):cardHtml(steps[i],steps,an);
    tipEl.hidden=false;
    tipEl.classList.toggle('dock',narrow);
    if(narrow){tipEl.style.left='';tipEl.style.top='';return;}
    const nb=nodeEls[i].getBoundingClientRect(),hb=host.getBoundingClientRect();
    const w=tipEl.offsetWidth,h=tipEl.offsetHeight,sl=host.scrollLeft,gap=14;
    const cx=nb.left-hb.left+sl+nb.width/2,cy=nb.top-hb.top+nb.height/2;
    const cands=[[cx+nb.width/2+gap,cy-h/2],[cx-nb.width/2-gap-w,cy-h/2],[cx-w/2,cy+nb.height/2+gap],[cx-w/2,cy-nb.height/2-gap-h]];
    const others=nodeEls.map((n,k)=>{if(k===i)return null;const r2=n.getBoundingClientRect();return {l:r2.left-hb.left+sl-6,t:r2.top-hb.top-6,r:r2.right-hb.left+sl+6,b:r2.bottom-hb.top+6};}).filter(Boolean);
    let best=null;
    cands.forEach((c,k)=>{
      const x0=clamp(c[0],sl+6,sl+hb.width-w-6),y0=clamp(c[1],6,Math.max(6,hb.height-h-6));
      const hits=others.filter(o=>x0<o.r&&x0+w>o.l&&y0<o.b&&y0+h>o.t).length;
      const moved=Math.abs(x0-c[0])+Math.abs(y0-c[1]);
      const onSelf=x0<cx+nb.width/2&&x0+w>cx-nb.width/2&&y0<cy+nb.height/2&&y0+h>cy-nb.height/2?1000:0;
      const score=hits*100+moved*0.5+k+onSelf;
      if(!best||score<best.score)best={score,x:x0,y:y0};
    });
    const x=best.x,y=best.y;
    tipEl.style.left=f(x)+'px';tipEl.style.top=f(y)+'px';
  }

  nodeEls.forEach((n,i)=>{
    n.addEventListener('pointerenter',()=>{if(pinned<0)setHot(i);});
    n.addEventListener('pointerleave',()=>{if(pinned<0)setHot(-1);});
    n.addEventListener('focus',()=>{if(pinned<0)setHot(i);});
    n.addEventListener('blur',()=>{if(pinned<0)setHot(-1);});
    n.addEventListener('click',ev=>{ev.stopPropagation();pinned=pinned===i?-1:i;setHot(pinned<0?i:pinned);});
    n.addEventListener('keydown',ev=>{
      if(ev.key==='ArrowRight'||ev.key==='ArrowDown'){ev.preventDefault();nodeEls[Math.min(steps.length-1,i+1)].focus();}
      if(ev.key==='ArrowLeft'||ev.key==='ArrowUp'){ev.preventDefault();nodeEls[Math.max(0,i-1)].focus();}
      if(ev.key==='Enter'||ev.key===' '){ev.preventDefault();pinned=pinned===i?-1:i;setHot(pinned<0?i:pinned);}
      if(ev.key==='Escape'){pinned=-1;setHot(-1);n.blur();}
    });
  });
  svg.addEventListener('click',()=>{pinned=-1;setHot(-1);});

  settle();
  return {play,settle,paint,setSet,setHot:i=>{pinned=i;setHot(i);},setLive:v=>{live=v;settle();},endT,fire,count:steps.length,leaders:Object.values(gangs).map(g=>g[0])};
}

return {mount,glyph,analyse,toolMix,toolCount,diffTally,shapeSvg,FAM,ORDER,ZONES,ZONE_SLOTS};
})();
