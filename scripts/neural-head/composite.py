import sys, numpy as np
from PIL import Image
from scipy.ndimage import gaussian_filter

D = sys.argv[1]; OUT = sys.argv[2]; THEME = sys.argv[3] if len(sys.argv) > 3 else "matrix"
GAIN = float(sys.argv[4]) if len(sys.argv) > 4 else 1.0
THEMES = {
  "matrix": {"think": (0.85,1.0,0.9), "sense": (0.25,0.85,1.0), "act": (0.15,1.0,0.5), "shell": (0.62,0.45,1.0), "delegate": (0.55,0.85,0.7), "say": (0.3,1.0,0.8), "link": (0.5,1.0,0.85), "star": (0.8,1.0,0.95), "seam": (0.15,1.0,0.5), "eye": (0.15,1.0,0.5)},
  "rose": {"think": (1.0,0.9,0.9), "sense": (0.61,0.81,0.85), "act": (0.92,0.74,0.73), "shell": (0.77,0.65,0.91), "delegate": (0.96,0.76,0.47), "say": (0.92,0.44,0.57), "link": (0.9,0.75,0.8), "star": (1.0,0.9,0.9), "seam": (0.92,0.74,0.73), "eye": (0.92,0.44,0.57)},
}
T = THEMES[THEME]
BG = np.array([0.003, 0.008, 0.007])

def lin(a): return np.where(a <= 0.04045, a / 12.92, ((a + 0.055) / 1.055) ** 2.4)
def srgb(a): a = np.clip(a, 0, 1); return np.where(a <= 0.0031308, a * 12.92, 1.055 * a ** (1 / 2.4) - 0.055)
def load(n, rgba=True):
    im = Image.open(f"{D}/{n}.png"); a = np.asarray(im).astype(np.float64)
    a = a / (65535.0 if im.mode.startswith("I") or a.max() > 255 else 255.0)
    return a
def mask(n): 
    im = Image.open(f"{D}/{n}.png").convert("RGB"); return np.asarray(im).astype(np.float64) / 255.0
def over(dst, src_rgb_lin, alpha): return dst * (1 - alpha[..., None]) + src_rgb_lin * alpha[..., None]
def bloom(g, radii=(2, 6, 16, 40), weights=(0.5, 0.35, 0.25, 0.18)):
    out = np.zeros_like(g)
    for r, w in zip(radii, weights):
        out += w * np.stack([gaussian_filter(g[..., c], r) for c in range(3)], -1)
    return out

interior = load("interior"); chassis = load("chassis"); glass = load("glass")
H, W = interior.shape[:2]
comp = np.ones((H, W, 3)) * BG
comp = over(comp, lin(interior[..., :3]), interior[..., 3])

glow = np.zeros((H, W, 3))
for n, chans in (("mask_i1", ("think", "sense", "act")), ("mask_i2", ("shell", "delegate", "say")), ("mask_i3", ("link", "star"))):
    try: m = mask(n)
    except Exception: continue
    for i, c in enumerate(chans):
        glow += m[..., i:i+1] * np.array(T[c]) ** 2.2 * 5.0
comp += glow * GAIN + bloom(glow * GAIN) * 1.1
comp = over(comp, lin(chassis[..., :3]), chassis[..., 3])
try:
    mc = mask("mask_c"); gc = np.zeros((H, W, 3))
    for i, c in enumerate(("seam", "eye")):
        gc += mc[..., i:i+1] * np.array(T[c]) ** 2.2 * (3.0 if c == "seam" else 5.0)
    comp += gc * GAIN + bloom(gc * GAIN, radii=(2, 8, 24), weights=(0.5, 0.4, 0.3))
except Exception: pass
comp = over(comp, lin(glass[..., :3]), glass[..., 3])
yy, xx = np.mgrid[0:H, 0:W]; v = 1 - 0.28 * (((xx - W / 2) / (W / 2)) ** 2 + ((yy - H / 2) / (H / 2)) ** 2)
comp = comp * v[..., None]
out = (srgb(comp / (1 + 0.15 * comp)) * 255).astype(np.uint8)
Image.fromarray(out).save(OUT); print("saved", OUT)
