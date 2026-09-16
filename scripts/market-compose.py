#!/usr/bin/env python3
"""Compose the App Store marketing panels from the raw screenshot masters.

A raw screenshot shows a surface; a store panel has to *sell* it at thumbnail
size, where the first three images are the whole pitch. So every panel burns
its claim into the picture: a headline in the system face, a quieter subline,
and the screenshot itself framed on the app's own canvas with a breath of the
brand accent behind it.

The iPhone and iPad captions live in marketing/captions/<locale>.json, one file
per store locale, so the same panel is told in every language the listing
carries; the Mac set is en-US only and its captions stay in this file.

Masters:  marketing/appstore/iphone/*.png (1320x2868) and marketing/appstore/ipad/*.png for
          en-US; marketing/appstore/l10n/<locale>/iphone/*.png for every other locale;
          Resources/Screenshots/mac/*.png (2880x1800)
Panels:   marketing/appstore/panels/{iphone,ipad,mac}/*.png for en-US,
          marketing/appstore/panels/l10n/<locale>/{iphone,ipad}/*.png otherwise

Panel filenames become the landing page's fallback labels, so they are the
story slugs, numbered in store order.

  scripts/market-compose.py                    # everything, every locale that has masters
  scripts/market-compose.py iphone             # one platform, every locale
  scripts/market-compose.py iphone --locale ja # one platform, one locale
"""
import io
import json
import math
import os
import sys

import AppKit
import Foundation
from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
IPHONE_IN = os.path.join(ROOT, "marketing/appstore/iphone")
IPAD_IN = os.path.join(ROOT, "marketing/appstore/ipad")
L10N_IN = os.path.join(ROOT, "marketing/appstore/l10n")
MAC_IN = os.path.join(ROOT, "Resources/Screenshots/mac")
CAPTIONS = os.path.join(ROOT, "marketing/captions")
OUT = os.path.join(ROOT, "marketing/appstore/panels")

ACCENT = (84, 107, 255)
CANVAS_TOP = (13, 15, 21)
CANVAS_BOTTOM = (7, 8, 12)
HEADLINE_INK = (244, 246, 250)
SUBLINE_INK = (154, 163, 178)
BORDER = (255, 255, 255, 30)

MAC = [
    ("01-conversation", "01-native-on-mac", "Claude Code & opencode, native on the Mac", "Drive the agents on your own machines from a real window — over your own tailnet, no browser tab, no relay."),
    ("02-split", "02-two-machines", "Two machines, side by side", "Split the window and point the new pane at any server's conversations."),
    ("03-git", "03-repo-truth", "The repo, read — never operated", "Branch, staged, changed, and the real diffs, from the machine that owns them."),
    ("04-analytics", "04-month-in-numbers", "The month in numbers", "Every transcript priced turn by turn, merged across every server."),
    ("05-spend", "05-priced-turns", "A price on the whole conversation", "Where the money went: answers, cache, fresh input — turn by turn."),
    ("06-quickask", "06-one-chord-away", "One chord from anywhere", "Summon the question box over any app; the agent is already working."),
]


def locales():
    return sorted(f[:-5] for f in os.listdir(CAPTIONS) if f.endswith(".json"))


def captions(locale):
    """The iPhone manifest for one locale, and the substitution that retells panel 1 for the iPad."""
    with open(os.path.join(CAPTIONS, locale + ".json")) as f:
        book = json.load(f)
    panels = [(p["master"], p["slug"], p["headline"], p["subline"]) for p in book["iphone"]]
    return panels, book.get("ipad_headline_swap", {})


def ipad_manifest(panels, swap):
    return [(m, s, swap_all(h, swap), sub) for m, s, h, sub in panels]


def swap_all(text, swap):
    for src, dst in swap.items():
        text = text.replace(src, dst)
    return text


def masters_dir(locale, platform):
    if locale == "en-US":
        return IPHONE_IN if platform == "iphone" else IPAD_IN
    return os.path.join(L10N_IN, locale, platform)


def panels_dir(locale, platform):
    if locale == "en-US":
        return os.path.join(OUT, platform)
    return os.path.join(OUT, "l10n", locale, platform)


def render_text(text, size, weight, rgb, max_width, align, line_height):
    """Draws one block of text through AppKit so every script the listing speaks — Latin, kana,
    hangul, han — falls back to the right system face on its own. Returns an RGBA image the width
    of the column and exactly as tall as the text."""
    font = AppKit.NSFont.systemFontOfSize_weight_(size, weight)
    paragraph = AppKit.NSMutableParagraphStyle.alloc().init()
    paragraph.setAlignment_(AppKit.NSTextAlignmentLeft if align == "left" else AppKit.NSTextAlignmentCenter)
    paragraph.setLineHeightMultiple_(line_height)
    color = AppKit.NSColor.colorWithSRGBRed_green_blue_alpha_(rgb[0] / 255, rgb[1] / 255, rgb[2] / 255, 1)
    attributes = {
        AppKit.NSFontAttributeName: font,
        AppKit.NSForegroundColorAttributeName: color,
        AppKit.NSParagraphStyleAttributeName: paragraph,
    }
    string = Foundation.NSAttributedString.alloc().initWithString_attributes_(text, attributes)
    bounds = string.boundingRectWithSize_options_context_(
        (max_width, 100000), AppKit.NSStringDrawingUsesLineFragmentOrigin, None)
    height = int(math.ceil(bounds.size.height)) + 4
    rep = AppKit.NSBitmapImageRep.alloc().initWithBitmapDataPlanes_pixelsWide_pixelsHigh_bitsPerSample_samplesPerPixel_hasAlpha_isPlanar_colorSpaceName_bytesPerRow_bitsPerPixel_(
        None, max_width, height, 8, 4, True, False, AppKit.NSCalibratedRGBColorSpace, 0, 0)
    context = AppKit.NSGraphicsContext.graphicsContextWithBitmapImageRep_(rep)
    AppKit.NSGraphicsContext.saveGraphicsState()
    AppKit.NSGraphicsContext.setCurrentContext_(context)
    string.drawWithRect_options_context_(((0, 0), (max_width, height)), AppKit.NSStringDrawingUsesLineFragmentOrigin, None)
    context.flushGraphics()
    AppKit.NSGraphicsContext.restoreGraphicsState()
    png = rep.representationUsingType_properties_(AppKit.NSBitmapImageFileTypePNG, None)
    return Image.open(io.BytesIO(bytes(png))).convert("RGBA")


def gradient(width, height):
    base = Image.new("RGB", (1, height))
    for y in range(height):
        t = y / max(1, height - 1)
        base.putpixel((0, y), tuple(round(a + (b - a) * t) for a, b in zip(CANVAS_TOP, CANVAS_BOTTOM)))
    return base.resize((width, height))


def glow(canvas, center, radius, alpha):
    layer = Image.new("L", canvas.size, 0)
    draw = ImageDraw.Draw(layer)
    draw.ellipse([center[0] - radius, center[1] - radius, center[0] + radius, center[1] + radius], fill=alpha)
    layer = layer.filter(ImageFilter.GaussianBlur(radius / 2))
    tint = Image.new("RGB", canvas.size, ACCENT)
    canvas.paste(tint, (0, 0), layer)


def rounded(shot, radius, scale_w):
    ratio = scale_w / shot.width
    shot = shot.resize((scale_w, round(shot.height * ratio)), Image.LANCZOS)
    mask = Image.new("L", shot.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, shot.width - 1, shot.height - 1], radius=radius, fill=255)
    framed = Image.new("RGBA", shot.size, (0, 0, 0, 0))
    framed.paste(shot, (0, 0), mask)
    ImageDraw.Draw(framed).rounded_rectangle(
        [0, 0, shot.width - 1, shot.height - 1], radius=radius, outline=BORDER, width=2)
    return framed


def shadow_under(canvas, box, radius, blur=60, alpha=140):
    layer = Image.new("L", canvas.size, 0)
    ImageDraw.Draw(layer).rounded_rectangle(box, radius=radius, fill=alpha)
    layer = layer.filter(ImageFilter.GaussianBlur(blur))
    dark = Image.new("RGB", canvas.size, (0, 0, 0))
    canvas.paste(dark, (0, 0), layer)


def fitted(text, size, weight, ink, column, align, line_height, lines):
    """Renders the text at `size`, stepping the type down until it holds within `lines` lines, so a
    translation that runs long still sits above the frame instead of under it."""
    while True:
        image = render_text(text, size, weight, ink, column, align, line_height)
        if image.height <= lines * size * line_height * 1.25 + 4 or size <= 40:
            return image
        size = round(size * 0.94)


def text_block(canvas, x, y, headline, subline, head_size, sub_size, spacing, align, width, right=48):
    """Paints the headline (two lines at most) and the subline (two at most) and returns the y
    where the block ends."""
    column = width - x - right if align == "left" else width
    head = fitted(headline, head_size, AppKit.NSFontWeightSemibold, HEADLINE_INK, column, align, 1.0, 2)
    sub = fitted(subline, sub_size, AppKit.NSFontWeightRegular, SUBLINE_INK, column, align, 1.12, 2)
    left = x if align == "left" else 0
    canvas.paste(head, (left, y), head)
    sub_y = y + head.height + spacing
    canvas.paste(sub, (left, sub_y), sub)
    return sub_y + sub.height


def compose_iphone(master, slug, headline, subline):
    W, H = 1320, 2868
    canvas = gradient(W, H).convert("RGBA")
    glow(canvas, (W // 2, -300), 900, 26)
    end = text_block(canvas, 96, 148, headline, subline, 104, 51, 40, "left", W)
    shot = rounded(Image.open(master).convert("RGB"), 64, 1136)
    x = (W - shot.width) // 2
    y = max(660, end + 72)
    shadow_under(canvas, [x + 8, y + 24, x + shot.width - 8, min(H, y + shot.height)], 64)
    canvas.paste(shot.convert("RGB"), (x, y), shot.split()[3])
    return canvas.convert("RGB").crop((0, 0, W, H))


def content_window(shot, window_h):
    """The vertical crop of the master that actually shows something.

    An iPad screen is taller than its content: a chat pins to the bottom, Home
    fills from the top, and a fixed anchor turns one of them into a black band.
    Score each row by how much it varies, then keep the window that carries the
    most ink - ties go to the top, so a full screen keeps its status bar.
    """
    if shot.height <= window_h:
        return shot
    probe = shot.convert("L").resize((48, shot.height))
    rows = list(probe.getdata())
    activity = []
    for y in range(shot.height):
        row = rows[y * 48:(y + 1) * 48]
        mean = sum(row) / 48
        activity.append(sum(abs(v - mean) for v in row))
    prefix = [0]
    for a in activity:
        prefix.append(prefix[-1] + a)
    best_top, best_sum = 0, -1
    for top in range(0, shot.height - window_h + 1, 8):
        s = prefix[top + window_h] - prefix[top]
        if s > best_sum:
            best_top, best_sum = top, s
    return shot.crop((0, best_top, shot.width, best_top + window_h))


def compose_ipad(master, slug, headline, subline):
    W, H = 2064, 2752
    canvas = gradient(W, H).convert("RGBA")
    glow(canvas, (W // 2, -470), 1400, 26)
    end = text_block(canvas, 150, 232, headline, subline, 163, 80, 64, "left", W)
    y = max(1030, end + 110)
    scale_w = 1776
    source = Image.open(master).convert("RGB")
    window_h = round((H - y - 96) * source.width / scale_w)
    shot = rounded(content_window(source, window_h), 84, scale_w)
    x = (W - shot.width) // 2
    shadow_under(canvas, [x + 12, y + 38, x + shot.width - 12, min(H, y + shot.height + 24)], 84)
    canvas.paste(shot.convert("RGB"), (x, y), shot.split()[3])
    return canvas.convert("RGB").crop((0, 0, W, H))


def compose_mac(master, slug, headline, subline):
    W, H = 2880, 1800
    canvas = gradient(W, H).convert("RGBA")
    glow(canvas, (W // 2, -500), 1400, 24)
    end = text_block(canvas, 0, 96, headline, subline, 92, 44, 24, "center", W)
    shot = rounded(Image.open(master).convert("RGB"), 28, 2560)
    x = (W - shot.width) // 2
    y = end + 88
    shadow_under(canvas, [x + 10, y + 20, x + shot.width - 10, H], 28)
    canvas.paste(shot.convert("RGB"), (x, y), shot.split()[3])
    return canvas.convert("RGB").crop((0, 0, W, H))


def emit(label, source_dir, folder, manifest, compose):
    os.makedirs(folder, exist_ok=True)
    for master, slug, headline, subline in manifest:
        path = os.path.join(source_dir, master + ".png")
        if not os.path.exists(path):
            sys.exit(f"missing master {path}")
        panel = compose(path, slug, headline, subline)
        out = os.path.join(folder, slug + ".png")
        panel.save(out, optimize=True)
        print(f"  {label}/{slug}.png")


def emit_locale(locale, platform):
    panels, swap = captions(locale)
    source = masters_dir(locale, platform)
    if not os.path.isdir(source):
        print(f"  {locale}/{platform}: no masters at {source}, skipped")
        return
    manifest = panels if platform == "iphone" else ipad_manifest(panels, swap)
    compose = compose_iphone if platform == "iphone" else compose_ipad
    emit(f"{locale}/{platform}", source, panels_dir(locale, platform), manifest, compose)


def main():
    args = sys.argv[1:]
    wanted_locales = None
    if "--locale" in args:
        i = args.index("--locale")
        wanted_locales = [args[i + 1]]
        del args[i:i + 2]
    wanted = args or ["iphone", "ipad", "mac"]
    for platform in ("iphone", "ipad"):
        if platform in wanted:
            for locale in wanted_locales or locales():
                emit_locale(locale, platform)
    if "mac" in wanted:
        emit("mac", MAC_IN, os.path.join(OUT, "mac"), MAC, compose_mac)


if __name__ == "__main__":
    main()
