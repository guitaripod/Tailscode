import sys, json, base64, io
from pathlib import Path
from PIL import Image
from playwright.sync_api import sync_playwright
here=Path(__file__).parent
L=Path(sys.argv[1]); out=Path(sys.argv[2])
def uri(path, lossless):
    im=Image.open(path)
    if im.mode not in ("RGB","RGBA"): im=im.convert("RGB")
    buf=io.BytesIO()
    im.save(buf,"WEBP",lossless=True,quality=100,method=4) if lossless else im.save(buf,"WEBP",quality=88,method=4,alpha_quality=100)
    return "data:image/webp;base64,"+base64.b64encode(buf.getvalue()).decode()
A={}
for k in ("chassis","interior","glass"): A[k]=uri(L/f"{k}.png",False)
for k in ("mask_i1","mask_i2","mask_i3","mask_c","mask_d","bloom_i1","bloom_i2","bloom_i3","bloom_c","bloom_d"): A[k]=uri(L/f"{k}.png",True)
hero=(here/"hero2.js").read_text()
html="""<!doctype html><meta charset=utf-8><body style="background:#000"><canvas id=c></canvas><pre id=o style="color:#8f8"></pre><script>
const ASSETS="""+json.dumps(A)+";"+hero+r"""
const W0=parseInt(new URLSearchParams(location.search).get('w')||'1280');
const H0=Math.round(W0*420/640);
const cv=document.getElementById('c');cv.width=W0;cv.height=H0;
const gl=cv.getContext('webgl2');const ext=gl.getExtension('EXT_disjoint_timer_query_webgl2');
const log=s=>{document.getElementById('o').textContent+=s+'\n';};
function sh(t,src){const s=gl.createShader(t);gl.shaderSource(s,src);gl.compileShader(s);if(!gl.getShaderParameter(s,gl.COMPILE_STATUS))throw new Error(gl.getShaderInfoLog(s)+src.slice(0,200));return s;}
function prog(fs){const p=gl.createProgram();gl.attachShader(p,sh(gl.VERTEX_SHADER,Hero.SHADERS.VS));gl.attachShader(p,sh(gl.FRAGMENT_SHADER,fs));gl.bindAttribLocation(p,0,'p');gl.linkProgram(p);if(!gl.getProgramParameter(p,gl.LINK_STATUS))throw new Error(gl.getProgramInfoLog(p));return p;}
function loadImg(src){return new Promise((res,rej)=>{const i=new Image();i.onload=()=>res(i);i.onerror=rej;i.src=src;});}
function tex(img,fmt){const t=gl.createTexture();gl.bindTexture(gl.TEXTURE_2D,t);gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL,true);gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL,false);
  if(fmt==='srgb')gl.texImage2D(gl.TEXTURE_2D,0,gl.SRGB8_ALPHA8,gl.RGBA,gl.UNSIGNED_BYTE,img);else gl.texImage2D(gl.TEXTURE_2D,0,gl.RGBA,gl.RGBA,gl.UNSIGNED_BYTE,img);
  gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MIN_FILTER,gl.LINEAR);gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MAG_FILTER,gl.LINEAR);gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_WRAP_S,gl.CLAMP_TO_EDGE);gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_WRAP_T,gl.CLAMP_TO_EDGE);return t;}
function dome(){
  const d="M128,212 C112,132 176,72 268,54 C366,38 462,52 512,108 C540,142 534,196 512,234 C494,260 452,268 420,270 L334,298 C296,314 254,322 214,314 C168,302 134,266 128,212 Z";
  const t=d.match(/[MLCZ]|-?\d+\.?\d*/g),pts=[];let i=0,cur=null;
  while(i<t.length){if(t[i]==='M'||t[i]==='L'){cur=[+t[i+1],+t[i+2]];pts.push(cur);i+=3;}else if(t[i]==='C'){const c1=[+t[i+1],+t[i+2]],c2=[+t[i+3],+t[i+4]],e=[+t[i+5],+t[i+6]];for(let k=1;k<=24;k++){const u=k/24,v=1-u;pts.push([v*v*v*cur[0]+3*v*v*u*c1[0]+3*v*u*u*c2[0]+u*u*u*e[0],v*v*v*cur[1]+3*v*v*u*c1[1]+3*v*u*u*c2[1]+u*u*u*e[1]]);}cur=e;i+=7;}else i++;}
  const cx=pts.reduce((a,p)=>a+p[0],0)/pts.length,cy=pts.reduce((a,p)=>a+p[1],0)/pts.length;
  const c=p=>[p[0]/640*2-1,1-p[1]/420*2],v=[];
  for(let k=0;k<pts.length;k++){const a=pts[k],b=pts[(k+1)%pts.length];v.push(...c([cx,cy]),...c(a),...c(b));}
  return new Float32Array(v);
}
function rect(x0,y0,x1,y1){const c=(x,y)=>[x/640*2-1,1-y/420*2];return new Float32Array([...c(x0,y0),...c(x1,y0),...c(x0,y1),...c(x1,y0),...c(x1,y1),...c(x0,y1)]);}
function vbo(a){const b=gl.createBuffer();gl.bindBuffer(gl.ARRAY_BUFFER,b);gl.bufferData(gl.ARRAY_BUFFER,a,gl.STATIC_DRAW);return {b,n:a.length/2};}
const FULL=vbo(new Float32Array([-1,-1,3,-1,-1,3])),DOME=vbo(dome()),ZONE=vbo(rect(456-66,150-58,456+66,150+58)),EYE=vbo(rect(520,170,640,260));
const INT=Hero.SHADERS.FS_INT,FRONT=Hero.SHADERS.FS_FRONT;
const PACK_INT=`#version 300 es
precision highp float;in vec2 vUv;out vec4 o;
uniform sampler2D uC,uMA,uMB,uBA,uBB;uniform vec3 uBg;uniform vec3 uTone[13];uniform float uInt[13];uniform float uTime,uRipple,uAspect;uniform vec2 uAct;
vec3 L(vec3 c){return pow(c,vec3(2.2));}
void main(){
  vec4 c=texture(uC,vUv);vec4 a=texture(uMA,vUv),b=texture(uMB,vUv),ba=texture(uBA,vUv),bb=texture(uBB,vUv);
  vec3 base=mix(L(uBg),L(c.rgb),c.a);
  float rip=1.+uRipple*.45*sin(length((vUv-uAct)*vec2(uAspect,1.))*38.-uTime*3.2);
  vec3 g=(a.r*uTone[0]*uInt[0]+a.g*uTone[1]*uInt[1]+a.b*uTone[2]*uInt[2]+a.a*uTone[3]*uInt[3]+b.r*uTone[4]*uInt[4]+b.g*uTone[5]*uInt[5]+b.b*rip*uTone[6]*uInt[6]+b.a*uTone[7]*uInt[7])*4.
        +(ba.r*uTone[0]*uInt[0]+ba.g*uTone[1]*uInt[1]+ba.b*uTone[2]*uInt[2]+ba.a*uTone[3]*uInt[3]+bb.r*uTone[4]*uInt[4]+bb.g*uTone[5]*uInt[5]+bb.b*rip*uTone[6]*uInt[6]+bb.a*uTone[7]*uInt[7])*2.;
  vec3 add=g/(1.+.2*g);vec3 col=1.-(1.-base)*(1.-clamp(add,0.,1.));
  o=vec4(pow(col,vec3(1./2.2)),1.);
}`;
const PACK_SRGB=PACK_INT.replace("vec3 base=mix(L(uBg),L(c.rgb),c.a);","vec3 base=mix(L(uBg),c.rgb,c.a);");
const EARLY=INT.replace("vec3 base=mix(L(uBg),L(c.rgb),c.a);","if(c.a<.004){o=vec4(pow(L(uBg),vec3(1./2.2)),1.);return;}\n  vec3 base=mix(L(uBg),L(c.rgb),c.a);");
const BLIT=`#version 300 es
precision highp float;in vec2 vUv;out vec4 o;uniform sampler2D uC;void main(){o=texture(uC,vUv);}`;
const ZONEQ=`#version 300 es
precision highp float;in vec2 vUv;out vec4 o;uniform sampler2D uC,uMA,uBA;uniform vec3 uTone[13];uniform float uInt[13];
void main(){vec4 c=texture(uC,vUv);vec4 a=texture(uMA,vUv),ba=texture(uBA,vUv);vec3 g=(a.r*uTone[0]*uInt[0]+a.g*uTone[1]*uInt[1])*4.+(ba.r*uTone[0]*uInt[0]+ba.g*uTone[1]*uInt[1])*2.;o=vec4(c.rgb+g,1.);}`;
const PROG={int:prog(INT),early:prog(EARLY),pack:prog(PACK_INT),packs:prog(PACK_SRGB),front:prog(FRONT),blit:prog(BLIT),zoneq:prog(ZONEQ)};
async function main(){
  const names=Object.keys(ASSETS),imgs={};
  const t0=performance.now();
  await Promise.all(names.map(async k=>{imgs[k]=await loadImg(ASSETS[k]);}));
  const decode=performance.now()-t0;
  const T={};names.forEach(k=>T[k]=tex(imgs[k]));
  const Ts=tex(imgs.interior,'srgb');
  const U=(p,n)=>gl.getUniformLocation(p,n);
  const ton=new Float32Array(13*3).fill(.5),inten=new Float32Array(13).fill(.5);
  function bind(p,list){gl.useProgram(p);list.forEach(([n,t],i)=>{gl.activeTexture(gl.TEXTURE0+i);gl.bindTexture(gl.TEXTURE_2D,t);const l=U(p,n);if(l)gl.uniform1i(l,i);});const a=U(p,'uTone[0]');if(a)gl.uniform3fv(a,ton);const b=U(p,'uInt[0]');if(b)gl.uniform1fv(b,inten);
    [['uBg',[.01,.02,.02]],['uAct',[.5,.5]],['uCz[0]',new Float32Array(12)],['uCen',[.5,.5]]].forEach(([n,v])=>{const l=U(p,n);if(!l)return;if(v.length===3)gl.uniform3fv(l,v);else if(v.length===2)gl.uniform2fv(l,v);else gl.uniform2fv(l,v);});
    [['uTime',1],['uRipple',1],['uAspect',W0/H0],['uSweep',.3],['uSweepAmt',0],['uCrunch',0],['uSc',1],['uSg',1],['uFade',1],['uEffort',3],['uHollow',0],['uRainbow',0],['uCtx',2],['uSpill',1]].forEach(([n,v])=>{const l=U(p,n);if(l)gl.uniform1f(l,v);});
    const sw=U(p,'uSweepTone');if(sw)gl.uniform3fv(sw,[1,1,1]);}
  const intTex=[['uC',T.interior],['uM1',T.mask_i1],['uM2',T.mask_i2],['uM3',T.mask_i3],['uB1',T.bloom_i1],['uB2',T.bloom_i2],['uB3',T.bloom_i3]];
  const frontTex=[['uCh',T.chassis],['uGl',T.glass],['uMc',T.mask_c],['uBc',T.bloom_c],['uMd',T.mask_d],['uBd',T.bloom_d]];
  const packTex=[['uC',T.interior],['uMA',T.mask_i1],['uMB',T.mask_i2],['uBA',T.bloom_i1],['uBB',T.bloom_i2]];
  const packTexS=[['uC',Ts],['uMA',T.mask_i1],['uMB',T.mask_i2],['uBA',T.bloom_i1],['uBB',T.bloom_i2]];
  function draw(v,blend){gl.bindBuffer(gl.ARRAY_BUFFER,v.b);gl.enableVertexAttribArray(0);gl.vertexAttribPointer(0,2,gl.FLOAT,false,0,0);if(blend){gl.enable(gl.BLEND);gl.blendFunc(gl.ONE,gl.ONE_MINUS_SRC_ALPHA);}else gl.disable(gl.BLEND);gl.drawArrays(gl.TRIANGLES,0,v.n);}
  const V={
    'interior: now (full-screen, 7 fetches)':()=>{bind(PROG.int,intTex);draw(FULL);},
    'interior: early-out outside the dome':()=>{bind(PROG.early,intTex);draw(FULL);},
    'interior: dome mesh only':()=>{bind(PROG.int,intTex);draw(DOME);},
    'interior: dome mesh, 5 fetches (packed)':()=>{bind(PROG.pack,packTex);draw(DOME);},
    'interior: dome mesh, packed, sRGB colour':()=>{bind(PROG.packs,packTexS);draw(DOME);},
    'interior: rest composite blit (1 fetch)':()=>{bind(PROG.blit,[['uC',T.interior]]);draw(FULL);},
    'interior: one zone quad, 3 fetches':()=>{bind(PROG.zoneq,[['uC',T.interior],['uMA',T.mask_i1],['uBA',T.bloom_i1]]);draw(ZONE);},
    'front: now (full-screen, 6 fetches, blended)':()=>{bind(PROG.front,frontTex);draw(FULL,true);},
    'front: static blit (1 fetch, blended)':()=>{bind(PROG.blit,[['uC',T.chassis]]);draw(FULL,true);},
    'front: eye, ear and ribs quad only':()=>{bind(PROG.zoneq,[['uC',T.chassis],['uMA',T.mask_c],['uBA',T.bloom_c]]);draw(EYE,true);}
  };
  const res={};
  for(const name of Object.keys(V)){
    const f=V[name];for(let i=0;i<30;i++)f();gl.finish();
    const meds=[];
    for(let round=0;round<3;round++){
      const qs=[];
      for(let i=0;i<120;i++){const q=gl.createQuery();gl.beginQuery(ext.TIME_ELAPSED_EXT,q);f();gl.endQuery(ext.TIME_ELAPSED_EXT);qs.push(q);}
      gl.finish();
      const t=[];let bad=false;
      for(let w=0;w<40;w++){await new Promise(r=>setTimeout(r,25));if(gl.getQueryParameter(qs[qs.length-1],gl.QUERY_RESULT_AVAILABLE))break;}
      for(const q of qs){if(!gl.getQueryParameter(q,gl.QUERY_RESULT_AVAILABLE)){bad=true;break;}t.push(gl.getQueryParameter(q,gl.QUERY_RESULT)/1000);}
      if(gl.getParameter(ext.GPU_DISJOINT_EXT))bad=true;
      t.sort((a,b)=>a-b);if(!bad)meds.push(t[Math.floor(t.length/2)]);
    }
    res[name]=meds.length?Math.min(...meds):null;
  }
  return {W:W0,H:H0,decode,res};
}
main().then(r=>{window.__bench=r;}).catch(e=>{window.__bench={err:String(e)};});
</script>"""
out.write_text(html)
with sync_playwright() as p:
    b=p.chromium.launch(args=["--headless=new","--enable-gpu","--use-angle=vulkan","--enable-features=Vulkan","--ignore-gpu-blocklist"])
    results=[]
    for w in (1280,2560):
        pg=b.new_page(viewport={"width":400,"height":300}); msgs=[]
        pg.on("console",lambda m:msgs.append(m.text)); pg.on("pageerror",lambda e:msgs.append(str(e)))
        pg.goto(f"file://{out}?w={w}")
        pg.wait_for_function("window.__bench!==undefined",timeout=180000)
        results.append(pg.evaluate("window.__bench")); print(msgs[:3]); pg.close()
    b.close()
json.dump(results,open(str(out)+".json","w"),indent=1)
for r in results:
    print(r.get("W"),r.get("H"),"decode+load ms",round(r.get("decode",0)),r.get("err",""))
    for k,v in (r.get("res") or {}).items(): print(f"  {k:48s} {v if v is None else round(v,1)} us")
