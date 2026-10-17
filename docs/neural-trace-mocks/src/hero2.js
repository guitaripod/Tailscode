const Hero=(function(){
const THEMES={
  matrix:{name:'Matrix',bg:'#030806',ink:'#d3f7e0',ink2:'#89be9b',accent:'#39ff88',info:'#6fd6ea',special:'#b79cff',warn:'#f2c14e',danger:'#ff5c7a',light:false},
  rose:{name:'Rosé Pine',bg:'#191724',ink:'#e0def4',ink2:'#908caa',accent:'#9ccfd8',info:'#c4a7e7',special:'#ebbcba',warn:'#f6c177',danger:'#eb6f92',light:false},
  tokyo:{name:'Tokyo Night',bg:'#1a1b26',ink:'#c0caf5',ink2:'#7a88cf',accent:'#9ece6a',info:'#bb9af7',special:'#7dcfff',warn:'#e0af68',danger:'#f7768e',light:false},
  dawn:{name:'Rosé Pine Dawn',bg:'#faf4ed',ink:'#575279',ink2:'#797593',accent:'#56949f',info:'#907aa9',special:'#d7827e',warn:'#ea9d34',danger:'#b4637a',light:true}
};
const FAMILIES={fable:'#d97757',opus:'#a78bfa',sonnet:'#38bdf8',haiku:'#3fc47c',gpt:'#10a37f',gemini:'#4285f4',qwen:'#7a5af5',deepseek:'#4d6bfe',llama:'#1877f2',mistral:'#f2620f',glm:'#c65bd6',kimi:'#a3e635',minimax:'#f0507e',gemma:'#b8c4ff',phi:'#e4e44b',command:'#ff9ec7'};
const NT=13;
function hex(h){return [parseInt(h.slice(1,3),16)/255,parseInt(h.slice(3,5),16)/255,parseInt(h.slice(5,7),16)/255];}
function mixc(a,b,t){return a.map((v,i)=>v*(1-t)+b[i]*t);}
function lin(c){return c.map(v=>Math.pow(v,2.2));}
function glowify(c,light){return light?mixc(c,[1,1,1],.45):c;}
function tones(t){
  const L=t.light,ink=glowify(hex(t.ink),L),ink2=glowify(hex(t.ink2),L),ac=glowify(hex(t.accent),L),inf=glowify(hex(t.info),L),sp=glowify(hex(t.special),L);
  return [ink,inf,ac,sp,ink2,mixc(ac,inf,.45),mixc(ac,inf,.5),mixc(ink,inf,.3),ac,ac,ac,ac,ac].map(lin);
}
function stateTone(t,name){
  const L=t.light;
  return lin(glowify(hex({live:t.accent,attention:t.warn,danger:t.danger,quiet:t.ink2}[name]),L));
}
const MOTION={
  breath(t){const p=(t/1.9)%1,r=.5-.5*Math.cos(2*Math.PI*p);return .34+.66*r;},
  heartbeat(t){const p=(t/1.6)%1,g=(c,w)=>Math.exp(-Math.pow((p-c)/w,2));return .42+.58*Math.max(g(.08,.045),.85*g(.25,.05));},
  sweep(t){return (t/1.05)%1;},
  still(){return 1;}
};

const VS=`#version 300 es
in vec2 p;out vec2 vUv;void main(){vUv=p*.5+.5;gl_Position=vec4(p,0.,1.);}`;
const FS_INT=`#version 300 es
precision highp float;in vec2 vUv;out vec4 o;
uniform sampler2D uC,uM1,uM2,uM3,uB1,uB2,uB3;uniform vec3 uBg;uniform vec3 uTone[13];uniform float uInt[13];
uniform float uTime,uRipple,uAspect,uSweep,uSweepAmt,uCrunch;uniform vec3 uSweepTone;uniform vec2 uAct;uniform vec2 uCz[6];
vec3 L(vec3 c){return pow(c,vec3(2.2));}
vec2 crunchUv(vec2 uv){
  if(uCrunch<=0.)return uv;
  vec2 best=uCz[0];float bd=1e9;
  for(int i=0;i<6;i++){vec2 d=(uv-uCz[i])*vec2(uAspect,1.);float dd=dot(d,d);if(dd<bd){bd=dd;best=uCz[i];}}
  return best+(uv-best)*(1.+.7*uCrunch);
}
vec3 mix8(vec3 a,vec3 b,vec3 c,float rip){
  return a.r*uTone[0]*uInt[0]+a.g*uTone[1]*uInt[1]+a.b*uTone[2]*uInt[2]+b.r*uTone[3]*uInt[3]+b.g*uTone[4]*uInt[4]+b.b*uTone[5]*uInt[5]+c.r*rip*uTone[6]*uInt[6]+c.g*uTone[7]*uInt[7];
}
void main(){
  vec4 c=texture(uC,vUv);
  vec3 base=mix(L(uBg),L(c.rgb),c.a);
  vec2 gu=crunchUv(vUv);
  float rip=1.+uRipple*.45*sin(length((vUv-uAct)*vec2(uAspect,1.))*38.-uTime*3.2);
  vec3 g=mix8(texture(uM1,gu).rgb,texture(uM2,gu).rgb,texture(uM3,gu).rgb,rip)*4.
        +mix8(texture(uB1,gu).rgb,texture(uB2,gu).rgb,texture(uB3,gu).rgb,rip)*(6./3.);
  float luma=dot(g,vec3(.3,.5,.2));
  float sw=exp(-pow((vUv.x*.9+vUv.y*.35-uSweep)*7.,2.));
  vec3 sg=uSweepTone*sw*uSweepAmt*(.14*c.a+min(luma*1.2,1.));
  vec3 add=g+sg;add=add/(1.+.2*add);
  vec3 col=1.-(1.-base)*(1.-clamp(add,0.,1.));
  o=vec4(pow(col,vec3(1./2.2)),1.);
}`;
const FS_FRONT=`#version 300 es
precision highp float;in vec2 vUv;out vec4 o;
uniform sampler2D uCh,uGl,uMc,uBc,uMd,uBd;uniform vec3 uTone[13];uniform float uInt[13];uniform vec2 uCen;
uniform float uSc,uSg,uFade,uTime,uEffort,uHollow,uRainbow,uCtx,uSpill;
vec3 L(vec3 c){return pow(c,vec3(2.2));}
vec2 tf(vec2 uv,float s){return (uv-uCen)/s+uCen;}
vec3 rb(float x){return .5+.5*cos(6.2831853*(x+vec3(0.,.33,.67)));}
vec3 gl(vec3 mc,vec3 md,vec2 uv){
  float xd=uv.x*640.,yd=(1.-uv.y)*420.;
  float seg=clamp(floor((xd-562.)/8.2),0.,4.);
  float lit=seg<uEffort?1.:(uHollow>.5?.1:.14);
  vec3 eyec=mix(uTone[9],rb(uv.x*5.-uTime*.3),uRainbow);
  float rib=clamp(floor((yd-381.)/6.),0.,5.);
  float rl=clamp(uCtx-(5.-rib),0.,1.);
  return mc.r*uTone[8]*uInt[8]*2.+mc.g*eyec*uInt[9]*lit*4.+md.r*uTone[10]*uInt[10]*rl*3.+md.g*uTone[11]*uInt[11]*3.+md.b*uTone[12]*uInt[12];
}
void main(){
  vec2 u1=tf(vUv,uSc),u2=tf(vUv,uSg);
  vec4 ch=texture(uCh,u1);
  vec3 g=gl(texture(uMc,u1).rgb,texture(uMd,u1).rgb,u1)+gl(texture(uBc,u1).rgb,texture(uBd,u1).rgb,u1)*(4./3.);
  g*=mix(ch.a,1.,uSpill);g=g/(1.+.2*g);
  float ga=uSpill>.5?clamp(max(g.r,max(g.g,g.b)),0.,1.):0.;
  vec3 col=(L(ch.rgb)*ch.a+g)*uFade;float a=clamp(ch.a+ga,0.,1.)*uFade;
  vec4 gs=texture(uGl,u2);float gA=gs.a*(1.-.8*(1.-uFade));
  col=col*(1.-gA)+L(gs.rgb)*gA;a=a*(1.-gA)+gA;
  o=vec4(pow(clamp(col,0.,1.),vec3(1./2.2)),a);
}`;
function sh(gl,t,src){const s=gl.createShader(t);gl.shaderSource(s,src);gl.compileShader(s);if(!gl.getShaderParameter(s,gl.COMPILE_STATUS))throw new Error(gl.getShaderInfoLog(s));return s;}
function prog(gl,fs){const p=gl.createProgram();gl.attachShader(p,sh(gl,gl.VERTEX_SHADER,VS));gl.attachShader(p,sh(gl,gl.FRAGMENT_SHADER,fs));gl.bindAttribLocation(p,0,'p');gl.linkProgram(p);if(!gl.getProgramParameter(p,gl.LINK_STATUS))throw new Error(gl.getProgramInfoLog(p));return p;}
function tex(gl,img){
  const t=gl.createTexture();gl.bindTexture(gl.TEXTURE_2D,t);gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL,true);gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL,false);
  gl.texImage2D(gl.TEXTURE_2D,0,gl.RGBA,gl.RGBA,gl.UNSIGNED_BYTE,img);
  gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MIN_FILTER,gl.LINEAR);gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MAG_FILTER,gl.LINEAR);gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_WRAP_S,gl.CLAMP_TO_EDGE);gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_WRAP_T,gl.CLAMP_TO_EDGE);
  return t;
}
function loadImg(src){return new Promise((res,rej)=>{const i=new Image();i.onload=()=>res(i);i.onerror=rej;i.src=src;});}
const ZC={think:[456,150],act:[348,104],sense:[204,162],shell:[240,284],delegate:[396,250],say:[520,306]};
const ZORD=['think','sense','act','shell','delegate','say'];

async function create(opts){
  const imgs={};
  await Promise.all(Object.keys(opts.assets).map(async k=>{imgs[k]=await loadImg(opts.assets[k]);}));
  const W=imgs.interior.width,H=imgs.interior.height;
  const cI=opts.interior,cF=opts.front;cI.width=cF.width=W;cI.height=cF.height=H;
  const gI=cI.getContext('webgl2'),gF=cF.getContext('webgl2');
  if(!gI||!gF)throw new Error('WebGL2 unavailable');
  const pI=prog(gI,FS_INT),pF=prog(gF,FS_FRONT);
  [[gI,pI],[gF,pF]].forEach(([g])=>{const b=g.createBuffer();g.bindBuffer(g.ARRAY_BUFFER,b);g.bufferData(g.ARRAY_BUFFER,new Float32Array([-1,-1,3,-1,-1,3]),g.STATIC_DRAW);g.enableVertexAttribArray(0);g.vertexAttribPointer(0,2,g.FLOAT,false,0,0);});
  const T={C:tex(gI,imgs.interior),M1:tex(gI,imgs.mask_i1),M2:tex(gI,imgs.mask_i2),M3:tex(gI,imgs.mask_i3),B1:tex(gI,imgs.bloom_i1),B2:tex(gI,imgs.bloom_i2),B3:tex(gI,imgs.bloom_i3),Ch:tex(gF,imgs.chassis),Gl:tex(gF,imgs.glass),Mc:tex(gF,imgs.mask_c),Bc:tex(gF,imgs.bloom_c),Md:tex(gF,imgs.mask_d),Bd:tex(gF,imgs.bloom_d)};
  const bytes=Object.values(imgs).reduce((a,i)=>a+i.width*i.height*4,0);
  const U=(g,p,n)=>g.getUniformLocation(p,n);
  const st={theme:'matrix',inten:[.5,.5,.5,.5,.5,.5,.55,.6,.3,.5,.6,.15,.25],toneOv:Array(NT).fill(null),time:0,ripple:0,act:[.5,.5],cen:[.5,.5],sc:1,sg:1,fade:1,frames:0,effort:5,hollow:0,rainbow:0,ctx:0,sweep:0,sweepAmt:0,sweepTone:[0,0,0],crunch:0};
  function toneArr(){
    const th=THEMES[st.theme],base=tones(th),out=new Float32Array(NT*3);
    for(let i=0;i<NT;i++){const c=st.toneOv[i]||base[i];out[i*3]=c[0];out[i*3+1]=c[1];out[i*3+2]=c[2];}
    return out;
  }
  const czArr=new Float32Array(ZORD.flatMap(z=>[ZC[z][0]/640,1-ZC[z][1]/420]));
  function draw(){
    const t0=performance.now(),th=THEMES[st.theme],ton=toneArr(),inten=new Float32Array(st.inten);
    gI.viewport(0,0,W,H);gI.useProgram(pI);
    [['uC',T.C],['uM1',T.M1],['uM2',T.M2],['uM3',T.M3],['uB1',T.B1],['uB2',T.B2],['uB3',T.B3]].forEach(([n,t],i)=>{gI.activeTexture(gI.TEXTURE0+i);gI.bindTexture(gI.TEXTURE_2D,t);gI.uniform1i(U(gI,pI,n),i);});
    gI.uniform3fv(U(gI,pI,'uBg'),new Float32Array(hex(th.bg)));gI.uniform3fv(U(gI,pI,'uTone[0]'),ton);gI.uniform1fv(U(gI,pI,'uInt[0]'),inten);
    gI.uniform1f(U(gI,pI,'uTime'),st.time);gI.uniform1f(U(gI,pI,'uRipple'),st.ripple);gI.uniform1f(U(gI,pI,'uAspect'),W/H);gI.uniform2fv(U(gI,pI,'uAct'),new Float32Array(st.act));
    gI.uniform1f(U(gI,pI,'uSweep'),st.sweep);gI.uniform1f(U(gI,pI,'uSweepAmt'),st.sweepAmt);gI.uniform3fv(U(gI,pI,'uSweepTone'),new Float32Array(st.sweepTone));gI.uniform1f(U(gI,pI,'uCrunch'),st.crunch);gI.uniform2fv(U(gI,pI,'uCz[0]'),czArr);
    gI.drawArrays(gI.TRIANGLES,0,3);
    gF.viewport(0,0,W,H);gF.clearColor(0,0,0,0);gF.clear(gF.COLOR_BUFFER_BIT);gF.useProgram(pF);
    [['uCh',T.Ch],['uGl',T.Gl],['uMc',T.Mc],['uBc',T.Bc],['uMd',T.Md],['uBd',T.Bd]].forEach(([n,t],i)=>{gF.activeTexture(gF.TEXTURE0+i);gF.bindTexture(gF.TEXTURE_2D,t);gF.uniform1i(U(gF,pF,n),i);});
    gF.uniform3fv(U(gF,pF,'uTone[0]'),ton);gF.uniform1fv(U(gF,pF,'uInt[0]'),inten);
    gF.uniform2fv(U(gF,pF,'uCen'),new Float32Array(st.cen));gF.uniform1f(U(gF,pF,'uSc'),st.sc);gF.uniform1f(U(gF,pF,'uSg'),st.sg);gF.uniform1f(U(gF,pF,'uFade'),st.fade);
    gF.uniform1f(U(gF,pF,'uTime'),st.time);gF.uniform1f(U(gF,pF,'uEffort'),st.effort);gF.uniform1f(U(gF,pF,'uHollow'),st.hollow);gF.uniform1f(U(gF,pF,'uRainbow'),st.rainbow);gF.uniform1f(U(gF,pF,'uCtx'),st.ctx);gF.uniform1f(U(gF,pF,'uSpill'),th.light?0:1);
    gF.drawArrays(gF.TRIANGLES,0,3);
    st.frames++;st.cost=performance.now()-t0;
  }
  return {st,draw,W,H,bytes,themes:THEMES};
}

const STATES=[
  {id:'idle',group:'Quiet',kind:'idle',tone:'quiet',motion:'still',zone:null,head:'no segment',says:'Nothing is happening.',sheet:'idle'},
  {id:'settled',group:'Quiet',kind:'a turn that ended well',tone:'quiet',motion:'still',zone:null,identity:true,head:'no segment',says:'The eye wears the model that answered and how hard it thought.',sheet:'done'},
  {id:'thinking',group:'Working',kind:'thinking',tone:'live',motion:'breath',zone:'think',head:'● thinking',says:'PLAN breathes.',sheet:'thinking'},
  {id:'reading',group:'Working',kind:'usingTool(Read)',tone:'live',motion:'breath',zone:'sense',head:'● reading',says:'SENSE breathes.',sheet:'reading',add:{fam:'sense',tool:'Read',arg:'TailscodeCore/Sources/TailscodeCore/Activity.swift',status:'run'}},
  {id:'editing',group:'Working',kind:'usingTool(Edit)',tone:'live',motion:'breath',zone:'act',head:'● editing',says:'ACT breathes.',sheet:'editing',add:{fam:'act',tool:'Edit',arg:'TailscodeLinux/Sources/Chat/TranscriptRows.swift',status:'run'}},
  {id:'running',group:'Working',kind:'usingTool(Bash)',tone:'live',motion:'breath',zone:'shell',head:'● running',says:'SHELL breathes.',sheet:'running',add:{fam:'shell',tool:'Bash',arg:'swift build -c release',status:'run'}},
  {id:'writing',group:'Working',kind:'writing',tone:'live',motion:'breath',zone:'say',head:'▮ writing',says:'SAY breathes: the agent is writing.',sheet:'writing',add:{fam:'say',tool:'Said',text:'The build now passes on both switches.',status:'run'}},
  {id:'delegating',group:'Working',kind:'delegating',tone:'live',motion:'breath',zone:'delegate',head:'▸ delegating',says:'DELEGATE breathes; a Task node opens a smaller head.',sheet:'delegating',add:{fam:'delegate',tool:'Task',arg:'Review the diff',status:'run'}},
  {id:'background',group:'Working',kind:'inBackground',tone:'live',motion:'breath',zone:null,orbit:true,head:'◔ background',says:'The turn is over and work continues: the eye breathes and one satellite circles the dome.',sheet:'background'},
  {id:'approval',group:'Needs you',kind:'needsApproval',tone:'attention',motion:'heartbeat',zone:'shell',head:'⏸ approval',says:'The waiting tool beats twice, the eye turns attention.',sheet:'approval',add:{fam:'shell',tool:'Bash',arg:'rm -rf build && swift build -c release',status:'wait',mark:'⏸'}},
  {id:'question',group:'Needs you',kind:'needsAnswer',tone:'attention',motion:'heartbeat',zone:'think',head:'? question',says:'The question beats in PLAN; the dock holds the options.',sheet:'question',add:{fam:'think',tool:'Question',text:'Which client should I install first?',status:'wait',mark:'?'}},
  {id:'stalled',group:'Needs you',kind:'stalled',tone:'attention',motion:'still',zone:'shell',head:'◔ stalled',says:'Work the machine found stuck: attention, held still.',sheet:'stalled',add:{fam:'shell',tool:'Bash',arg:'ffmpeg -i walk.mov …',status:'stall'}},
  {id:'retrying',group:'Needs you',kind:'retrying',tone:'attention',motion:'sweep',zone:null,head:'◐ retrying',says:'A band of light crosses the dome.',sheet:'retrying'},
  {id:'compacting',group:'Needs you',kind:'compacting',tone:'attention',motion:'sweep',zone:null,crunch:true,head:'◐ compacting',says:'The galaxies draw in while the sweep runs; the ribs drop to what was kept.',sheet:'compacting'},
  {id:'queued',group:'Quiet',kind:'queued(2)',tone:'quiet',motion:'still',zone:null,dim:.35,head:'⋯ 2 queued',says:'Held still, eye dim.',sheet:'queued'},
  {id:'connecting',group:'Quiet',kind:'connecting',tone:'quiet',motion:'sweep',zone:null,dim:.4,head:'◐ connecting',says:'A quiet band sweeps the dome.',sheet:'connecting'},
  {id:'reconnecting',group:'Needs you',kind:'reconnecting',tone:'attention',motion:'sweep',zone:null,dim:.4,head:'◐ reconnecting',says:'Attention band while the line comes back.',sheet:'reconnecting'},
  {id:'failed',group:'Ended',kind:'failed (also a quota wall)',tone:'danger',motion:'still',zone:'shell',head:'✗ failed',says:'The eye holds danger, the failed node keeps its mark.',sheet:'failed',fail:true},
  {id:'stopped',group:'Ended',kind:'stopped or interrupted: no face',tone:'quiet',motion:'still',zone:null,dim:.4,head:'(a card, no segment)',says:'A record, not a fault: neutral, held still, the last node dashed.',sheet:'stopped',stopped:true},
  {id:'offline',group:'Ended',kind:'offline',tone:'quiet',motion:'still',zone:null,dark:true,head:'⚠ offline',says:'The machine is down: the head is dark.',sheet:'offline'}
];

function frameFor(state,t,theme,ctx){
  const th=THEMES[theme],NZ=6,inten=[.5,.5,.5,.5,.5,.5,.55,.6,.3,.5,.62,.15,.25],tone=Array(NT).fill(null);
  const m=state.motion==='breath'?MOTION.breath(t):state.motion==='heartbeat'?MOTION.heartbeat(t):1;
  const sc=stateTone(th,state.tone);
  const out={inten,tone,sweepAmt:0,sweep:0,sweepTone:sc,crunch:0,ripple:0,orbit:false};
  if(state.dark){for(let i=0;i<NT;i++)inten[i]=i===9?0:.05;inten[8]=.06;return out;}
  if(state.dim!==undefined){for(let i=0;i<NZ;i++)inten[i]=state.dim;inten[6]=state.dim;inten[9]=.35;tone[9]=sc;}
  if(state.zone){
    for(let i=0;i<NZ;i++)inten[i]=.3;
    const zi=ZORD.indexOf(state.zone);
    inten[zi]=state.motion==='still'?1.0:.5+.85*m;
    if(state.tone!=='live')tone[zi]=sc;
    inten[6]=.7;
  }
  if(state.tone!=='live'||!state.identity){tone[9]=sc;}
  inten[9]=state.dim!==undefined?.35:(state.tone==='quiet'&&!state.identity?.4:(state.motion==='still'?1:.35+.65*m));
  if(state.id==='failed'){for(let i=0;i<NZ;i++)inten[i]=.1;inten[6]=.2;inten[7]=.3;inten[ZORD.indexOf('shell')]=.9;tone[3]=sc;inten[8]=.15;}
  if(state.motion==='sweep'){out.sweep=m;out.sweepAmt=state.dim?.55:.9;if(state.tone==='quiet')out.sweepAmt=.5;}
  if(state.crunch){const c=.5-.5*Math.cos(2*Math.PI*((t/2.6)%1));out.crunch=c;inten[8]=.3+.7*c;}
  if(state.orbit){for(let i=0;i<NZ;i++)inten[i]=.28;out.orbit=true;}
  if(state.id==='background'){tone[9]=stateTone(th,'live');}
  if(state.identity){tone[9]=lin(glowify(hex(FAMILIES[ctx.family||'fable']),th.light));inten[9]=1;}
  const ctxF=ctx.ctxFill==null?0:ctx.ctxFill;
  const ribTone=ctxF>=.8?stateTone(th,'danger'):ctxF>=.5?stateTone(th,'attention'):stateTone(th,'quiet');
  tone[10]=ribTone;inten[10]=ctx.ctxEst?.5:1;
  if(state.id==='compacting'){const c=out.crunch;out.ctxOverride=ctxF*(1-.55*c);}
  const call=ctx.call;
  if(call){
    const ct={listening:['live','breath'],hearing:['live','still'],connecting:['quiet','sweep'],degraded:['danger','still'],ended:['quiet','still'],working:['live','breath']}[call];
    if(ct){tone[11]=stateTone(th,ct[0]);inten[11]=ct[1]==='breath'?.2+.9*MOTION.breath(t):ct[1]==='sweep'?.2+.7*(.5+.5*Math.sin(t*6)):1;}
  }
  inten[12]=.25;
  return out;
}

function effortSpec(e){
  if(e==='power')return {effort:5,hollow:0,rainbow:1};
  if(e==='server')return {effort:0,hollow:1,rainbow:0};
  if(e==='ember')return {effort:1,hollow:0,rainbow:0};
  return {effort:Math.max(1,Math.min(5,e)),hollow:0,rainbow:0};
}
return {create,THEMES,FAMILIES,STATES,MOTION,frameFor,effortSpec,tones,hex,lin,ZC,ZORD};
})();
