#!/usr/bin/env python3
"""Compose the App Store marketing panels from the raw screenshot masters.

A raw screenshot shows a surface; a store panel has to *sell* it at thumbnail
size, where the first three images are the whole pitch. So every panel burns
its claim into the picture: a headline in the system face, a quieter subline,
and the screenshot itself framed on the app's own canvas with a breath of the
brand accent behind it.

The iPhone and iPad captions live in marketing/captions/<locale>.json, one file
per store locale, so the same panel is told in every language the listing
carries; the Mac set is en-US only and its captions stay in this file. The iPad
is photographed in landscape as the workspace it is, so a locale may carry an
`ipad` manifest of its own; one that does not retells the iPhone's.

Masters:  marketing/appstore/iphone/*.png (1320x2868) and marketing/appstore/ipad/*.png (2752x2064) for
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
import hashlib
import io
import json
import math
import os
import subprocess
import sys
import tempfile

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

FRAME_COLOR = "Silver"
FRAME_CACHE = os.path.join(tempfile.gettempdir(), "tailscode-frames")

ACCENT = (84, 107, 255)
CANVAS_TOP = (13, 15, 21)
CANVAS_BOTTOM = (7, 8, 12)
HEADLINE_INK = (244, 246, 250)
SUBLINE_INK = (154, 163, 178)
BORDER = (255, 255, 255, 30)

MAC = [
    ("01-conversation", "01-native-on-mac", "Claude Code, opencode & Oh My Pi, native on the Mac", "Drive the agents on your own machines from a real window — over your own tailnet, no browser tab, no relay."),
    ("02-split", "02-two-machines", "Two machines, side by side", "Split the window and point the new pane at any server's conversations."),
    ("03-git", "03-repo-truth", "The repo, read — never operated", "Branch, staged, changed, and the real diffs, from the machine that owns them."),
    ("04-analytics", "04-month-in-numbers", "The month in numbers", "Every transcript priced turn by turn, merged across every server."),
    ("05-spend", "05-priced-turns", "A price on the whole conversation", "Where the money went: answers, cache, fresh input — turn by turn."),
    ("06-quickask", "06-one-chord-away", "One chord from anywhere", "Summon the question box over any app; the agent is already working."),
]


def locales():
    return sorted(f[:-5] for f in os.listdir(CAPTIONS) if f.endswith(".json"))


def captions(locale):
    """One locale's caption book."""
    with open(os.path.join(CAPTIONS, locale + ".json")) as f:
        return json.load(f)


def manifest(entries):
    return [(p["master"], p["slug"], p["headline"], p["subline"]) for p in entries]


def ipad_manifest(book):
    """The iPad's own panels where the locale wrote them, else the iPhone's retold for the iPad."""
    if "ipad" in book:
        return manifest(book["ipad"])
    swap = book.get("ipad_headline_swap", {})
    return [(m, s, swap_all(h, swap), sub) for m, s, h, sub in manifest(book["iphone"])]


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


def framed(master, color=FRAME_COLOR):
    """The screenshot inside its real device bezel, from the `frames` CLI, which picks the device
    from the screenshot's own size. Cached by the master's bytes, because a panel is composed once
    per locale and the framing never changes between them."""
    with open(master, "rb") as f:
        key = hashlib.sha1(f.read() + color.encode()).hexdigest()[:16]
    folder = os.path.join(FRAME_CACHE, key)
    out = os.path.join(folder, os.path.splitext(os.path.basename(master))[0] + "_framed.png")
    if not os.path.exists(out):
        os.makedirs(folder, exist_ok=True)
        result = subprocess.run(["frames", "-c", color, "-o", folder, master], capture_output=True, text=True)
        if result.returncode != 0 or not os.path.exists(out):
            sys.exit(f"frames failed for {master}:\n{result.stdout}{result.stderr}")
    return Image.open(out).convert("RGBA")


def device_shadow(canvas, device, position, blur=70, alpha=170, drop=34):
    """A shadow cast by the bezel's own outline, so the shape under the device is the device's."""
    layer = Image.new("L", canvas.size, 0)
    layer.paste(device.split()[3].point(lambda a: alpha if a > 200 else 0), (position[0], position[1] + drop))
    layer = layer.filter(ImageFilter.GaussianBlur(blur))
    canvas.paste(Image.new("RGB", canvas.size, (0, 0, 0)), (0, 0), layer)


def place_device(canvas, master, top, bottom_margin, width_limit, side_margin=0):
    """Scales the framed device to the room between `top` and the canvas bottom, whole — nothing of
    the screen cropped away, so the composer and the pill under it are always in the picture."""
    device = framed(master)
    room_h = canvas.height - top - bottom_margin
    scale = min(room_h / device.height, width_limit / device.width)
    device = device.resize((round(device.width * scale), round(device.height * scale)), Image.LANCZOS)
    x = (canvas.width - device.width) // 2
    glow(canvas, (canvas.width // 2, top + device.height // 2), round(device.width * 0.8), 20)
    device_shadow(canvas, device, (x, top))
    canvas.paste(device.convert("RGB"), (x, top), device.split()[3])
    return device


def compose_iphone(master, slug, headline, subline):
    W, H = 1320, 2868
    canvas = gradient(W, H).convert("RGBA")
    glow(canvas, (W // 2, -300), 900, 26)
    end = text_block(canvas, 96, 132, headline, subline, 104, 51, 36, "left", W)
    place_device(canvas, master, top=end + 56, bottom_margin=44, width_limit=W - 150)
    return canvas.convert("RGB")


def compose_ipad(master, slug, headline, subline):
    """The landscape workspace, whole, in its own bezel: the claim centred above it and the device
    scaled to the room the claim leaves, so no column of the three is cropped away."""
    W, H = 2752, 2064
    canvas = gradient(W, H).convert("RGBA")
    glow(canvas, (W // 2, -520), 1500, 26)
    end = text_block(canvas, 0, 96, headline, subline, 108, 54, 24, "center", W)
    place_device(canvas, master, top=end + 56, bottom_margin=40, width_limit=W - 200)
    return canvas.convert("RGB")


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
    for stale in sorted(set(os.listdir(folder)) - {slug + ".png" for _, slug, _, _ in manifest}):
        if stale.endswith(".png"):
            os.remove(os.path.join(folder, stale))
            print(f"  {label}/{stale} removed (not in the manifest)")


def emit_locale(locale, platform):
    book = captions(locale)
    source = masters_dir(locale, platform)
    if not os.path.isdir(source):
        print(f"  {locale}/{platform}: no masters at {source}, skipped")
        return
    panels = manifest(book["iphone"]) if platform == "iphone" else ipad_manifest(book)
    compose = compose_iphone if platform == "iphone" else compose_ipad
    emit(f"{locale}/{platform}", source, panels_dir(locale, platform), panels, compose)


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
