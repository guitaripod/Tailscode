import sys, numpy as np
from PIL import Image
from scipy.ndimage import gaussian_filter, zoom, uniform_filter
D=sys.argv[1]
def lin(a): return np.where(a<=0.04045,a/12.92,((a+0.055)/1.055)**2.4)
def srgb(a): a=np.clip(a,0,1); return np.where(a<=0.0031308,a*12.92,1.055*a**(1/2.4)-0.055)
def ld(n):
    im=Image.open(f"{D}/{n}.png"); return np.asarray(im).astype(np.float64)/(65535.0 if im.mode.startswith('I') else 255.0)
def ldm(n): return np.asarray(Image.open(f"{D}/{n}.png").convert('RGB')).astype(np.float64)/255.0
T={"think":(0.85,1.0,0.9),"sense":(0.25,0.85,1.0),"act":(0.15,1.0,0.5),"shell":(0.62,0.45,1.0),"delegate":(0.55,0.85,0.7),"say":(0.3,1.0,0.8),"link":(0.5,1.0,0.85),"star":(0.8,1.0,0.95),"seam":(0.15,1.0,0.5),"eye":(0.15,1.0,0.5)}
L={k:(np.array(v)**2.2) for k,v in T.items()}
base={n:ld(n) for n in ("interior","chassis","glass")}
masks={n:ldm(n) for n in ("mask_i1","mask_i2","mask_i3","mask_c")}
blooms={n:ldm(n) for n in ("bloom_i1","bloom_i2","bloom_i3","bloom_c")}
H,W=base["interior"].shape[:2]
def up(a,h,w): return np.stack([zoom(a[...,c],(h/a.shape[0],w/a.shape[1]),order=1) for c in range(a.shape[2])],-1)
def down_up(a,f):
    h,w=a.shape[:2]; sm=np.stack([zoom(a[...,c],1/f,order=1) for c in range(a.shape[2])],-1); return up(sm,h,w)[:h,:w]
def compose(B,M,Bl):
    bg=np.array([.003,.008,.007])
    I=B["interior"]; comp=np.ones((H,W,3))*bg; comp=comp*(1-I[...,3:4])+lin(I[...,:3])*I[...,3:4]
    glow=np.zeros((H,W,3)); bl=np.zeros((H,W,3))
    for (mn,bn,ch) in (("mask_i1","bloom_i1",("think","sense","act")),("mask_i2","bloom_i2",("shell","delegate","say")),("mask_i3","bloom_i3",("link","star"))):
        bu=up(Bl[bn],H,W)/3.0
        for i,c in enumerate(ch):
            glow+=M[mn][...,i:i+1]*L[c]*4*.5; bl+=bu[...,i:i+1]*L[c]*2*.5
    g=glow+bl; g=g/(1+.2*g); comp=1-(1-comp)*(1-np.clip(g,0,1))
    C=B["chassis"]; comp=comp*(1-C[...,3:4])+lin(C[...,:3])*C[...,3:4]
    gc=M["mask_c"][...,0:1]*L["seam"]*2*.5+M["mask_c"][...,1:2]*L["eye"]*4*.5+up(Bl["bloom_c"],H,W)[...,0:1]/3*L["seam"]*2*.5
    gc=gc/(1+.2*gc); comp=1-(1-comp)*(1-np.clip(gc,0,1))
    G=B["glass"]; comp=comp*(1-G[...,3:4])+lin(G[...,:3])*G[...,3:4]
    return srgb(comp)
ref=compose(base,masks,blooms)
def psnr(a,b):
    mse=np.mean((a-b)**2); return 99 if mse==0 else 10*np.log10(1/mse)
def ssim(a,b):
    ga=a.mean(-1); gb=b.mean(-1); mu_a=uniform_filter(ga,7); mu_b=uniform_filter(gb,7)
    sa=uniform_filter(ga*ga,7)-mu_a**2; sb=uniform_filter(gb*gb,7)-mu_b**2; sab=uniform_filter(ga*gb,7)-mu_a*mu_b
    c1,c2=.01**2,.03**2; s=((2*mu_a*mu_b+c1)*(2*sab+c2))/((mu_a**2+mu_b**2+c1)*(sa+sb+c2)); return float(s.mean())
print("reference composite", ref.shape)
rows=[]
def test(name,B=None,M=None,Bl=None):
    out=compose(B or base,M or masks,Bl or blooms); rows.append((name,psnr(ref,out),ssim(ref,out),float(np.abs(ref-out).max())))
for f in (2,):
    test(f"interior colour layer at 1/{f}",B={**base,"interior":down_up(base["interior"],f)})
    test(f"glass layer at 1/{f}",B={**base,"glass":down_up(base["glass"],f)})
    test(f"chassis layer at 1/{f}",B={**base,"chassis":down_up(base["chassis"],f)})
    test(f"all three colour layers at 1/{f}",B={k:down_up(v,f) for k,v in base.items()})
    for n in masks: test(f"{n} at 1/{f}",M={**masks,n:down_up(masks[n],f)})
for n in blooms:
    for f in (2,):
        test(f"{n} at 1/8 (from 1/4)",Bl={**blooms,n:down_up(blooms[n],f)})
test("masks quantised to 6 bits",M={k:np.round(v*63)/63 for k,v in masks.items()})
test("colour layers quantised to 6 bits",B={k:np.round(v*63)/63 for k,v in base.items()})
for r in rows: print(f"{r[0]:42s} PSNR {r[1]:6.2f} dB  SSIM {r[2]:.4f}  max err {r[3]:.3f}")
np.save(f"{D}/ref.npy",ref)
