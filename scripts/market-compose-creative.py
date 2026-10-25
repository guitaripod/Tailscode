#!/usr/bin/env python3
"""Compose the iOS 27 creative assets for the App Store product page, from the iPhone masters.

Apple's specification (developer.apple.com/help/app-store-connect/reference/app-information/
creative-assets-specifications) lists, for images without an alpha channel:

  product page header   21:9   3840 x 1646         .png .jpg      and a 16:9 5244 x 2950 .png
  search results        3:2    1920x1280-3840x2560 .png .jpg      and the same 16:9 5244 x 2950 .png

The page says nothing about text or overlays. What is public beyond it: Apple's asset best practices
ask for a short phrase that enhances the visual rather than describes it, focal art in the centre of
the composition so nothing clips, and no pricing, discounts, URLs or copyright marks. The 16:9 entry
is one universal PNG accepted by both placements, so it is made text-free here: one real piece of the
app, centred above the middle where the art-safe area of the template sits.

The header and search compositions keep every word and every focal element inside the middle of the
canvas, and let only the devices' edges and the ground run to the borders, so a crop at the sides or
an icon and title laid over the lower left take nothing that matters.

Words come from marketing/captions/<locale>.json, the `header` and `search` keys. Type, ground, accent
and the framing are market-compose.py's.

  scripts/market-compose-creative.py                  # every locale
  scripts/market-compose-creative.py --locale ja      # one locale
"""
import importlib.util
import os
import sys

from PIL import Image, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("compose", os.path.join(HERE, "market-compose.py"))
compose = importlib.util.module_from_spec(spec)
spec.loader.exec_module(compose)

OUT = os.path.join(compose.ROOT, "marketing/appstore/creative")
HEADER = (3840, 1646)
SEARCH = (3840, 2560)
UNIVERSAL = (5244, 2950)
BOARD_BOX = (30, 790, 1290, 1905)


def master(locale, name):
    return os.path.join(compose.masters_dir(locale, "iphone"), name + ".png")


def fitted_headline(text, highlight, column, ceiling, align):
    """The headline at the largest size up to `ceiling` whose longest line holds within `column`."""
    size = ceiling
    while size > 40:
        kern = compose.HEADLINE_KERN * size / 100
        if max(compose.line_widths(text, size, compose.HEADLINE_WEIGHT, kern)) <= column:
            break
        size = round(size * 0.97)
    image = compose.render_text(text, size, compose.HEADLINE_WEIGHT, compose.HEADLINE_INK, column, align,
                                compose.HEADLINE_LEADING, highlight, compose.ACCENT,
                                compose.HEADLINE_KERN * size / 100)
    return size, image


def hairline(canvas, y, node_x=None):
    """The set's tailnet line across the canvas, with a node where it starts to mean something."""
    draw = ImageDraw.Draw(canvas)
    draw.line([(0, y), (canvas.width, y)], fill=compose.ACCENT + (110,), width=3)
    if node_x is not None:
        draw.ellipse([node_x - 22, y - 22, node_x + 22, y + 22], fill=compose.GROUND + (255,),
                     outline=compose.ACCENT + (170,), width=3)
        draw.ellipse([node_x - 9, y - 9, node_x + 9, y + 9], fill=compose.ACCENT + (255,))


def phone(canvas, path, width, center_x, top):
    """A framed phone of `width` whose middle is `center_x`, running off the bottom of the canvas."""
    return compose.place_device(canvas, path, top, 0, canvas.width, width, center_x - width // 2)


def compose_header(locale, book):
    W, H = HEADER
    canvas = compose.ground(W, H, lift_at=(0.5, 0.8), lift_radius=0.42)
    hairline(canvas, 70, W // 2)
    size, head = fitted_headline(book["header"]["headline"], book["header"].get("highlight"), 1500, 150, "center")
    canvas.paste(head, ((W - head.width) // 2, 104), head)
    top = 104 + head.height + 12
    phone(canvas, master(locale, "fl-models"), 640, W // 2 - 720, top + 150)
    phone(canvas, master(locale, "07-home"), 640, W // 2 + 720, top + 150)
    phone(canvas, master(locale, "fl-agents"), 780, W // 2, top)
    return canvas.convert("RGB")


def compose_search(locale, book):
    W, H = SEARCH
    canvas = compose.ground(W, H, lift_at=(0.72, 0.7), lift_radius=0.4)
    hairline(canvas, 150, 560)
    size, head = fitted_headline(book["search"]["headline"], book["search"].get("highlight"), 1520, 168, "left")
    canvas.paste(head, (560, 1010 - head.height // 2), head)
    phone(canvas, master(locale, "fl-agents"), 1120, 2740, 420)
    return canvas.convert("RGB")


def compose_universal(locale, book):
    """Text-free: the Agents board's needs-you card and the first working row, cut from the master at
    its pixels and enlarged, on the ground with the tailnet line through it, set above the middle of
    the canvas."""
    W, H = UNIVERSAL
    canvas = compose.ground(W, H, lift_at=(0.5, 0.42), lift_radius=0.3, lift_alpha=18)
    cut = Image.open(master(locale, "fl-agents")).convert("RGB").crop(BOARD_BOX)
    scale = 1760 / cut.width
    cut = cut.resize((round(cut.width * scale), round(cut.height * scale)), Image.LANCZOS)
    y = round(H * 0.40)
    hairline(canvas, y)
    mask = Image.new("L", cut.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, cut.width - 1, cut.height - 1], radius=96, fill=255)
    x = (W - cut.width) // 2
    top = y - cut.height // 2
    shadow = Image.new("L", canvas.size, 0)
    ImageDraw.Draw(shadow).rounded_rectangle([x, top + 24, x + cut.width, top + cut.height + 24], radius=96, fill=170)
    shadow = shadow.filter(ImageFilter.GaussianBlur(50))
    canvas.paste(Image.new("RGB", canvas.size, (0, 0, 0)), (0, 0), shadow)
    canvas.paste(cut, (x, top), mask)
    ImageDraw.Draw(canvas).rounded_rectangle([x, top, x + cut.width, top + cut.height], radius=96,
                                             outline=compose.ACCENT + (150,), width=4)
    return canvas.convert("RGB")


def emit(locale):
    book = compose.captions(locale)
    folder = os.path.join(OUT, locale)
    os.makedirs(folder, exist_ok=True)
    for name, make in (("header-3840x1646", compose_header), ("search-3840x2560", compose_search),
                       ("universal-5244x2950", compose_universal)):
        make(locale, book).save(os.path.join(folder, name + ".png"), optimize=True)
        print(f"  {locale}/{name}.png")


def main():
    args = sys.argv[1:]
    wanted = [args[args.index("--locale") + 1]] if "--locale" in args else compose.locales()
    for locale in wanted:
        emit(locale)


if __name__ == "__main__":
    main()
