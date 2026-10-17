import sys, numpy as np
from PIL import Image
import astc_encoder as A
D=sys.argv[1]
def enc_dec(arr, bx, by, quality, flags=None):
    h,w=arr.shape[:2]
    cfg=A.ASTCConfig(A.ASTCProfile.LDR, bx, by, 1, quality) if flags is None else A.ASTCConfig(A.ASTCProfile.LDR, bx, by, 1, quality, flags)
    ctx=A.ASTCContext(cfg)
    img=A.ASTCImage(A.ASTCType.U8, w, h, 1, np.ascontiguousarray(arr.astype(np.uint8)).tobytes())
    sw=A.ASTCSwizzle.from_str("RGBA")
    comp=ctx.compress(img, sw)
    out=A.ASTCImage(A.ASTCType.U8, w, h, 1)
    ctx.decompress(comp, out, sw)
    dec=np.frombuffer(out.data, dtype=np.uint8).reshape(h,w,4)
    return dec, len(comp)
def psnr(a,b): 
    mse=np.mean((a.astype(float)-b.astype(float))**2); return 99 if mse==0 else 10*np.log10(255**2/mse)
rows=[]
for n,alpha in (("chassis",1),("interior",1),("glass",1),("mask_i1",0),("mask_i2",0),("mask_i3",0),("mask_c",0),("mask_d",0)):
    im=Image.open(f"{D}/{n}.png").convert("RGBA"); a=np.asarray(im)
    if n.startswith("mask"):
        a=a.copy(); a[...,3]=255
    for (bx,by,q,label) in ((4,4,A.ASTCQualityPreset.THOROUGH,"4x4"),(6,6,A.ASTCQualityPreset.THOROUGH,"6x6"),(8,8,A.ASTCQualityPreset.THOROUGH,"8x8")):
        try:
            dec,size=enc_dec(a,bx,by,q)
        except Exception as ex:
            print(n,label,"fail",ex); continue
        per=[psnr(a[...,c],dec[...,c]) for c in range(3 if n.startswith("mask") else 4)]
        rows.append((n,label,size/1024,per))
        print(f"{n:9s} ASTC {label}: {size/1024:7.0f} KB  per-channel PSNR "+" ".join(f"{p:5.1f}" for p in per))
