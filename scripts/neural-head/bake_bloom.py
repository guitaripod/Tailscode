import sys, numpy as np
from PIL import Image
from scipy.ndimage import gaussian_filter, zoom
D = sys.argv[1]
SIG = (3, 9, 24); WT = (0.5, 0.35, 0.25); GAIN = 3.0
for n in ("mask_i1", "mask_i2", "mask_i3", "mask_c"):
    im = Image.open(f"{D}/{n}.png").convert("RGB"); a = np.asarray(im).astype(np.float64) / 255.0
    H, W = a.shape[:2]; sc = W / 1280.0
    out = np.zeros_like(a)
    for s, w in zip(SIG, WT):
        out += w * np.stack([gaussian_filter(a[..., c], s * sc) for c in range(3)], -1)
    out /= sum(WT)
    small = np.stack([zoom(out[..., c], 0.25, order=1) for c in range(3)], -1)
    Image.fromarray((np.clip(small * GAIN, 0, 1) * 255).astype(np.uint8)).save(f"{D}/bloom_{n[5:]}.png")
    print("bloom", n, small.shape)
