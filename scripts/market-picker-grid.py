#!/usr/bin/env python3
"""Compose the shareable grid that explains the model and effort pill on iOS.

One PNG: a headline, then eight tiles in two rows, each a piece of the phone (the framed device,
cropped to the part that tells the story) over a numbered step, a title and the sentence that says
how it behaves. The pictures are the app's own, shot headlessly by `scripts/shots.sh pk-*`; this
script only arranges them.

Runs on the Mac (PyObjC draws the text, `frames` draws the bezels), from the same helpers the
store panels use.

  scripts/market-picker-grid.py <shots-dir> <out.png> [width]
"""
import importlib.util
import os
import sys
import tempfile

import AppKit
from PIL import Image, ImageChops, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("compose", os.path.join(HERE, "market-compose.py"))
compose = importlib.util.module_from_spec(spec)
spec.loader.exec_module(compose)

MARGIN = 120
GAP = 56
COLUMNS = 4
TILE_W = 820
TILE_PAD = 44
DEVICE_PAD = 24
IMAGE_H = 1180
TEXT_H = 500
TILE_H = IMAGE_H + TEXT_H
HEADER_H = 560
FOOTER_H = 190
WIDTH = MARGIN * 2 + COLUMNS * TILE_W + (COLUMNS - 1) * GAP
HEIGHT = HEADER_H + 2 * TILE_H + GAP + FOOTER_H

CARD = (255, 255, 255, 12)
CARD_EDGE = (255, 255, 255, 30)
ACCENT = compose.ACCENT
INK = compose.HEADLINE_INK
SOFT = compose.SUBLINE_INK
FAINT = (104, 112, 128)

PILL_ROWS = [
    ("pk-pill-haiku", "Haiku", "no levels, so no meter"),
    ("pk-pill-sonnet", "Sonnet", "low is one bar"),
    ("pk-pill-opus", "Opus", "xhigh is four"),
    ("pk-pill-fable", "Fable", "ultracode is the rainbow"),
    ("pk-pill-auto", "Auto", "the server decides: hollow bars"),
]

TILES = [
    {
        "shot": None,
        "title": "One pill, two halves",
        "body": "A dot in the model's colour and its name, then the effort word and five bars of heat. "
        "Hue says who answers, heat says how hard. A model with no levels shows only its dot and name.",
    },
    {
        "shot": "pk-menu",
        "anchor": "bottom",
        "title": "Tap the model for your pins",
        "body": "The quick menu opens on the pairs you pinned, a model and a level together, "
        "nearest the pill, with your recent models above them.",
    },
    {
        "shot": "pk-rail",
        "anchor": "bottom",
        "title": "Tap the effort: a rail opens",
        "body": "The levels lift out as a column, each with what it means. Tap a level or slide to it, "
        "a tick for every rung; lift off to the side and nothing changes. From xhigh up the top of the "
        "box glows with the level's heat, and ultracode wraps it in a rainbow.",
    },
    {
        "shot": "pk-cycle",
        "anchor": "bottom",
        "title": "Swipe the model to cycle pins",
        "body": "Swipe left or right across the model half of the pill to step through your pinned "
        "pairs without opening anything, and a toast says where you landed. On a hardware keyboard it "
        "is Ctrl-Option with the arrows.",
    },
    {
        "shot": "pk-carry",
        "anchor": "bottom",
        "title": "Your level never moves in silence",
        "body": "Pick a model that lacks your level and it moves to the nearest cooler one the model "
        "takes, never hotter, and a toast says so:",
        "quote": "\u201cxhigh moved to high. Sonnet has no xhigh.\u201d",
    },
    {
        "shot": "pk-list",
        "anchor": "top",
        "title": "The full list knows your chat",
        "body": "An effort strip for this chat's model sits above the list; with several machines, tabs "
        "switch between them, and models are grouped by family. Tap a star to pin the model, or swipe "
        "a row to pin the pair.",
    },
    {
        "shot": "pk-peek",
        "anchor": "top",
        "title": "Hold a row for the facts",
        "body": "A card says what the row had no room for: how much the model holds, what it reads, the "
        "levels it takes, and where your level would land and what a switch re-reads, once, in tokens.",
    },
    {
        "shot": "pk-home",
        "anchor": "bottom",
        "title": "Choose before the first word",
        "body": "Home's composer wears the same pill, so you choose the model and the level before a "
        "chat exists, and they go with it when it starts.",
    },
]


def font_text(text, size, weight, rgb, width, line_height=1.0, align="left"):
    return compose.render_text(text, size, weight, rgb, width, align, line_height)


def card(canvas, box, radius=44):
    layer = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    draw.rounded_rectangle(box, radius=radius, fill=CARD, outline=CARD_EDGE, width=2)
    canvas.alpha_composite(layer)


def rounded_clip(image, radius):
    mask = Image.new("L", image.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, image.width - 1, image.height - 1], radius=radius, fill=255)
    out = Image.new("RGBA", image.size, (0, 0, 0, 0))
    out.paste(image, (0, 0), mask)
    return out


MENU_BOX = (178, 630, 930, 1891)
MENU_DROP = 720


def master_path(shots, name):
    """The shot's file, except for the quick menu, which the simulator can only show with its
    on-screen keyboard raised over the composer; that menu is lifted out of its own capture and set
    down above the pill on the same Home screen with the keyboard away, where it opens on a phone."""
    if name != "pk-menu":
        return os.path.join(shots, name + ".png")
    base = Image.open(os.path.join(shots, "pk-pill-auto.png")).convert("RGBA")
    menu = Image.open(os.path.join(shots, "pk-menu.png")).convert("RGBA").crop(MENU_BOX)
    scale = 4
    mask = Image.new("L", (menu.width * scale, menu.height * scale), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, mask.width - 1, mask.height - 1], radius=64 * scale, fill=255)
    mask = mask.resize(menu.size, Image.LANCZOS)
    at = (MENU_BOX[0], MENU_BOX[1] + MENU_DROP)
    shadow = Image.new("L", base.size, 0)
    shadow.paste(mask.point(lambda a: 150 if a > 128 else 0), (at[0], at[1] + 26))
    shadow = shadow.filter(ImageFilter.GaussianBlur(34))
    base.paste(Image.new("RGBA", base.size, (0, 0, 0, 255)), (0, 0), shadow)
    base.paste(menu, at, mask)
    out = os.path.join(tempfile.gettempdir(), "pk-menu-composite.png")
    base.convert("RGB").save(out)
    return out


def fade_edge(image, edge, length):
    """Lets the cut edge of a cropped device dissolve into the card instead of ending in a ruler line."""
    mask = Image.new("L", image.size, 255)
    pixels = mask.load()
    for step in range(length):
        value = round(255 * step / length)
        row = step if edge == "top" else image.height - 1 - step
        for x in range(image.width):
            pixels[x, row] = value
    alpha = ImageChops.multiply(image.split()[3], mask)
    faded = image.copy()
    faded.putalpha(alpha)
    return faded


def device_crop(shots, name, anchor):
    """The framed phone cropped to the tile's picture: its top for a screen that begins at the top,
    its bottom, with the bezel's own corners, for one that happens at the composer. The edge that was
    cut fades out."""
    device = compose.framed(master_path(shots, name))
    width = TILE_W - DEVICE_PAD * 2
    scale = width / device.width
    device = device.resize((width, round(device.height * scale)), Image.LANCZOS)
    height = IMAGE_H - 24
    top = 0 if anchor == "top" else max(0, device.height - height)
    window = device.crop((0, top, width, min(device.height, top + height)))
    return fade_edge(window, "bottom", 220) if anchor == "top" else fade_edge(window, "top", 120)


PILL_BOX = {"pk-pill-auto": (150, 2618, 150 + 740, 2618 + 115)}


def pill_crop(shots, name):
    """Just the composer's pill row from a full-screen shot, large enough to read."""
    master = Image.open(os.path.join(shots, name + ".png")).convert("RGB")
    box = PILL_BOX.get(name, (150, 2612, 150 + 740, 2612 + 115))
    crop = master.crop(box)
    inner = TILE_W - TILE_PAD * 2
    scale = inner / crop.width
    crop = crop.resize((inner, round(crop.height * scale)), Image.LANCZOS)
    return rounded_clip(crop.convert("RGBA"), 34)


def tile_one(canvas, x, y, shots):
    """The legend tile: the pill at four settings, so hue and heat can be read off the page."""
    inner = TILE_W - TILE_PAD * 2
    cursor = y + 56
    for name, model, note in PILL_ROWS:
        label = font_text(f"{model}  ·  {note}", 34, AppKit.NSFontWeightMedium, SOFT, inner)
        canvas.alpha_composite(label, (x + TILE_PAD, cursor))
        cursor += label.height + 16
        pill = pill_crop(shots, name)
        canvas.alpha_composite(pill, (x + TILE_PAD, cursor))
        cursor += pill.height + 44


def number_badge(canvas, x, y, number):
    size = 84
    layer = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    draw.ellipse([x, y, x + size, y + size], fill=ACCENT + (255,))
    canvas.alpha_composite(layer)
    digit = font_text(str(number), 48, AppKit.NSFontWeightBold, (255, 255, 255), size, align="center")
    canvas.alpha_composite(digit, (x, y + (size - digit.height) // 2 + 1))


def place_tile(canvas, index, tile, shots):
    col, row = index % COLUMNS, index // COLUMNS
    x = MARGIN + col * (TILE_W + GAP)
    y = HEADER_H + row * (TILE_H + GAP)
    card(canvas, [x, y, x + TILE_W, y + TILE_H])
    if tile["shot"] is None:
        tile_one(canvas, x, y, shots)
    else:
        picture = device_crop(shots, tile["shot"], tile["anchor"])
        px = x + (TILE_W - picture.width) // 2
        py = y + 40 if tile["anchor"] == "top" else y + IMAGE_H - picture.height
        shadow = Image.new("L", canvas.size, 0)
        shadow.paste(picture.split()[3].point(lambda a: 150 if a > 200 else 0), (px, py + 24))
        shadow = shadow.filter(ImageFilter.GaussianBlur(36))
        canvas.paste(Image.new("RGB", canvas.size, (0, 0, 0)), (0, 0), shadow)
        canvas.alpha_composite(picture, (px, py))
    ty = y + IMAGE_H + 28
    block = 124
    number_badge(canvas, x + TILE_PAD, ty + (block - 84) // 2, index + 1)
    title = font_text(tile["title"], 52, AppKit.NSFontWeightSemibold, INK, TILE_W - TILE_PAD * 2 - 112)
    canvas.alpha_composite(
        title, (x + TILE_PAD + 112, ty + max(0, (block - title.height) // 2) - 4))
    body = font_text(tile["body"], 35, AppKit.NSFontWeightRegular, SOFT, TILE_W - TILE_PAD * 2, 1.22)
    by = ty + block + 20
    canvas.alpha_composite(body, (x + TILE_PAD, by))
    if tile.get("quote"):
        quote = font_text(tile["quote"], 35, AppKit.NSFontWeightMedium, INK, TILE_W - TILE_PAD * 2, 1.22)
        canvas.alpha_composite(quote, (x + TILE_PAD, by + body.height + 14))


def header(canvas):
    glow_layer = canvas.copy()
    compose.glow(glow_layer, (WIDTH // 2, -260), 1500, 30)
    canvas.paste(glow_layer.convert("RGBA"))
    kicker = font_text("TAILSCODE FOR iOS", 38, AppKit.NSFontWeightSemibold, ACCENT, 1200)
    canvas.alpha_composite(kicker, (MARGIN, 150))
    title = font_text(
        "Model and effort are one decision, so they are one pill.",
        122, AppKit.NSFontWeightBold, INK, WIDTH - MARGIN * 2)
    canvas.alpha_composite(title, (MARGIN, 214))
    sub = font_text(
        "Who answers and how hard it thinks sit together in one pill in the message box, "
        "on Home before the first word and in every chat after.",
        50, AppKit.NSFontWeightRegular, SOFT, WIDTH - MARGIN * 2, 1.2)
    canvas.alpha_composite(sub, (MARGIN, 214 + title.height + 30))


def footer(canvas):
    line = font_text(
        "Claude Code, opencode and Oh My Pi, from your phone, over your own tailnet.  ·  Tailscode on the App Store",
        40, AppKit.NSFontWeightMedium, FAINT, WIDTH - MARGIN * 2)
    canvas.alpha_composite(line, (MARGIN, HEIGHT - FOOTER_H + 56))


def main():
    if len(sys.argv) not in (3, 4):
        sys.exit("usage: market-picker-grid.py <shots-dir> <out.png> [width]")
    shots, out = sys.argv[1], sys.argv[2]
    width = int(sys.argv[3]) if len(sys.argv) == 4 else WIDTH
    canvas = compose.gradient(WIDTH, HEIGHT).convert("RGBA")
    header(canvas)
    for index, tile in enumerate(TILES):
        place_tile(canvas, index, tile, shots)
    footer(canvas)
    final = canvas.convert("RGB")
    if width != WIDTH:
        final = final.resize((width, round(HEIGHT * width / WIDTH)), Image.LANCZOS)
    final.save(out, optimize=True)
    print(f"{out} {final.width}x{final.height}")


if __name__ == "__main__":
    main()
