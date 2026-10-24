import sys

import numpy as np
from PIL import Image, ImageChops, ImageFilter

src, out = sys.argv[1], sys.argv[2]
GROUND = np.array([8, 8, 12], dtype=np.float32)

image = Image.open(src).convert("RGB")
width, height = image.size

highlights = image.point(lambda v: max(0, v - 150) * 2)
bloom = ImageChops.screen(
    highlights.filter(ImageFilter.GaussianBlur(width * 0.006)).point(lambda v: int(v * 0.7)),
    highlights.filter(ImageFilter.GaussianBlur(width * 0.022)).point(lambda v: int(v * 0.9)),
)
pixels = np.asarray(ImageChops.screen(image, bloom), dtype=np.float32)
pixels = 255 - (255 - pixels) * (255 - GROUND) / 255

xs = np.linspace(0, 1, width, dtype=np.float32)[None, :]
ys = np.linspace(0, 1, height, dtype=np.float32)[:, None]
side = np.clip(np.minimum(xs, 1 - xs) / 0.07, 0, 1)
floor = np.clip((1 - ys) / 0.34, 0, 1)
keep = (side * floor)[..., None] ** 1.4
pixels = GROUND + (pixels - GROUND) * keep

rng = np.random.default_rng(3)
pixels += rng.normal(0, 1.1, pixels.shape[:2])[..., None]
Image.fromarray(np.clip(pixels, 0, 255).astype(np.uint8)).save(out)
