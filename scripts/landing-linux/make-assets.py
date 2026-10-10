import sys
from PIL import Image, ImageFilter, ImageOps

art, out = sys.argv[1], sys.argv[2]


def crop(name, width, height):
    image = Image.open(f"{art}/{name}.png").convert("RGB")
    return ImageOps.fit(image, (width, height), Image.LANCZOS, centering=(0.5, 0.5))


for name in ["aurora-cabin", "cat-roof", "sauna", "lighthouse", "fox", "station"]:
    crop(name, 1280, 704).save(f"{out}/poster-{name}.png")

final = crop("cat-roof", 256, round(256 * 704 / 1280))
blurred = final.filter(ImageFilter.GaussianBlur(256 / 14))
t = 3 / 8
eased = t * t * (3 - 2 * t)
Image.blend(blurred, final, eased).save(f"{out}/cat-sketch.jpg", "JPEG", quality=72)
