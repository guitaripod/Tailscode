import sys, numpy as np
from PIL import Image
import astc_encoder as A
D=sys.argv[1]
exec(open('astc_test.py').read().split("rows=[]")[0].split("D=sys.argv[1]")[1])
ld=lambda n: np.asarray(Image.open(f"{D}/{n}.png").convert("RGB"))
i1,i2,i3,c,d=[ld(n) for n in ("mask_i1","mask_i2","mask_i3","mask_c","mask_d")]
z=np.zeros_like(i1[...,0])
packs=[np.dstack([i1[...,0],i1[...,1],i1[...,2],i2[...,0]]),np.dstack([i2[...,1],i2[...,2],i3[...,0],i3[...,1]]),np.dstack([c[...,0],c[...,1],d[...,0],d[...,1]]),np.dstack([d[...,2],z,z,z])]
tot=0
for k,p in enumerate(packs):
    for (bx,by,label) in ((4,4,"4x4"),(6,6,"6x6")):
        dec,size=enc_dec(p,bx,by,A.ASTCQualityPreset.THOROUGH)
        per=[psnr(p[...,ch],dec[...,ch]) for ch in range(4)]
        print(f"packed RGBA #{k} ASTC {label}: {size/1024:6.0f} KB  per-channel PSNR "+" ".join(f"{x:5.1f}" for x in per))
