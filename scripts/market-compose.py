#!/usr/bin/env python3
"""Compose the App Store marketing panels from the raw screenshot masters.

A raw screenshot shows a surface; a store panel has to *sell* it at thumbnail
size, where the first three images are the whole pitch. So every panel burns
its claim into the picture — a headline of at most two lines with one phrase lit
in the panel's colour, a quieter subline — and the screenshot itself, framed in
its real bezel and large enough to read, with the one moment worth the thumbnail
pulled out of it and enlarged beside it.

Each panel has its own colour (marketing/captions/layout.json, by slug), so the
ten read as a rhythm down the store's carousel rather than one panel ten times;
that file also says how large the device is, how much of it bleeds off the
bottom, and which callouts to cut from the master. Nothing in it is language, so
every locale shares it; the words live in marketing/captions/<locale>.json.

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
import colorsys
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
LAYOUT = os.path.join(CAPTIONS, "layout.json")
WIDGET_TILES = os.path.join(ROOT, "marketing/appstore/widgets")
OUT = os.path.join(ROOT, "marketing/appstore/panels")

FRAME_COLOR = "Silver"
FRAME_CACHE = os.path.join(tempfile.gettempdir(), "tailscode-frames")

ACCENT = (84, 107, 255)
CANVAS_TOP = (13, 15, 21)
CANVAS_BOTTOM = (6, 7, 11)
HEADLINE_INK = (252, 253, 255)
SUBLINE_INK = (196, 203, 219)
BORDER = (255, 255, 255, 30)

MAC = [
    ("01-conversation", "01-native-on-mac", "Your coding agents,\nnative on the Mac", "A real window for Claude Code, opencode and Oh My Pi on your own machines — over your tailnet, no browser tab, no relay.", "native on the Mac"),
    ("02-split", "02-two-machines", "Two machines,\nside by side", "Split the window and point the new pane at any server's conversations.", "side by side"),
    ("03-git", "03-repo-truth", "The repo, read —\nnever operated", "Branch, staged, changed, and the real diffs, from the machine that owns them.", "never operated"),
    ("04-analytics", "04-month-in-numbers", "The month\nin numbers", "Every transcript priced turn by turn, merged across every server.", "in numbers"),
    ("05-spend", "05-priced-turns", "A price on the\nwhole conversation", "Where the money went: answers, cache, fresh input — turn by turn.", "whole conversation"),
    ("06-quickask", "06-one-chord-away", "One chord\nfrom anywhere", "Summon the question box over any app; the agent is already working.", "from anywhere"),
]


def locales():
    return sorted(f[:-5] for f in os.listdir(CAPTIONS) if f.endswith(".json"))


def captions(locale):
    """One locale's caption book."""
    with open(os.path.join(CAPTIONS, locale + ".json")) as f:
        return json.load(f)


def manifest(entries):
    """The panels a locale tells, as dicts: master, slug, headline, subline and the phrase of the
    headline to light, which a locale may leave out."""
    return [dict(p) for p in entries]


def ipad_manifest(book):
    """The iPad's own panels where the locale wrote them, else the iPhone's retold for the iPad."""
    if "ipad" in book:
        return manifest(book["ipad"])
    swap = book.get("ipad_headline_swap", {})
    return [dict(p, headline=swap_all(p["headline"], swap)) for p in book["iphone"]]


def swap_all(text, swap):
    for src, dst in swap.items():
        text = text.replace(src, dst)
    return text


def layout():
    """Everything about a panel that is not language: its colour, the size of the device, what is
    cut from the master and enlarged beside it."""
    with open(LAYOUT) as f:
        return json.load(f)


def masters_dir(locale, platform):
    if locale == "en-US":
        return IPHONE_IN if platform == "iphone" else IPAD_IN
    return os.path.join(L10N_IN, locale, platform)


def panels_dir(locale, platform):
    if locale == "en-US":
        return os.path.join(OUT, platform)
    return os.path.join(OUT, "l10n", locale, platform)


def hexc(value):
    value = value.lstrip("#")
    return tuple(int(value[i:i + 2], 16) for i in (0, 2, 4))


def mix(a, b, t):
    return tuple(round(x + (y - x) * t) for x, y in zip(a, b))


def shifted(rgb, degrees, lift=0.0):
    """The same colour turned round the wheel — the second glow behind a device, which wants to be
    near the panel's colour and not the same as it."""
    h, l, sat = colorsys.rgb_to_hls(*(c / 255 for c in rgb))
    r, g, b = colorsys.hls_to_rgb((h + degrees / 360) % 1, min(1, l + lift), sat)
    return (round(r * 255), round(g * 255), round(b * 255))


def utf16(text, upto):
    return len(text[:upto].encode("utf-16-le")) // 2


def render_text(text, size, weight, rgb, max_width, align, line_height, highlight=None, lit=None, kern=0.0):
    """Draws one block of text through AppKit so every script the listing speaks — Latin, kana,
    hangul, han — falls back to the right system face on its own. `highlight` is a phrase of the text
    to draw in `lit`. Returns an RGBA image the width of the column and exactly as tall as the text."""
    font = AppKit.NSFont.systemFontOfSize_weight_(size, weight)
    paragraph = AppKit.NSMutableParagraphStyle.alloc().init()
    paragraph.setAlignment_(AppKit.NSTextAlignmentLeft if align == "left" else AppKit.NSTextAlignmentCenter)
    paragraph.setLineHeightMultiple_(line_height)

    def color(c):
        return AppKit.NSColor.colorWithSRGBRed_green_blue_alpha_(c[0] / 255, c[1] / 255, c[2] / 255, 1)

    attributes = {
        AppKit.NSFontAttributeName: font,
        AppKit.NSForegroundColorAttributeName: color(rgb),
        AppKit.NSParagraphStyleAttributeName: paragraph,
        AppKit.NSKernAttributeName: kern,
    }
    string = Foundation.NSMutableAttributedString.alloc().initWithString_attributes_(text, attributes)
    if highlight and lit and highlight in text:
        start = text.index(highlight)
        string.addAttribute_value_range_(
            AppKit.NSForegroundColorAttributeName, color(lit),
            (utf16(text, start), utf16(text, start + len(highlight)) - utf16(text, start)))
    bounds = string.boundingRectWithSize_options_context_(
        (max_width, 100000), AppKit.NSStringDrawingUsesLineFragmentOrigin, None)
    height = int(math.ceil(bounds.size.height)) + 6
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


def backdrop(width, height, accent):
    """The panel's own ground: the canvas darkened toward the bottom, the panel's colour pooled at the
    top where the claim sits, and a second, turned-round colour behind the device so the glass of the
    bezel has something to be seen against. The glows are blurred at a fraction of the size, which is
    indistinguishable and an order of magnitude faster."""
    top = mix(CANVAS_TOP, accent, 0.20)
    column = Image.new("RGB", (1, height))
    for y in range(height):
        t = y / max(1, height - 1)
        stop = mix(top, CANVAS_BOTTOM, min(1, t / 0.62)) if t < 0.62 else CANVAS_BOTTOM
        column.putpixel((0, y), stop)
    canvas = column.resize((width, height)).convert("RGBA")
    glow(canvas, (round(width * 0.12), -260), 1150, 70, accent)
    glow(canvas, (round(width * 0.9), round(height * 0.58)), 950, 34, shifted(accent, 38, 0.04))
    return canvas


def glow(canvas, center, radius, alpha, color=ACCENT):
    scale = 4
    small = (canvas.width // scale, canvas.height // scale)
    layer = Image.new("L", small, 0)
    r = radius / scale
    cx, cy = center[0] / scale, center[1] / scale
    ImageDraw.Draw(layer).ellipse([cx - r, cy - r, cx + r, cy + r], fill=alpha)
    layer = layer.filter(ImageFilter.GaussianBlur(r / 2)).resize(canvas.size, Image.BILINEAR)
    canvas.paste(Image.new("RGB", canvas.size, color), (0, 0), layer)


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


def fitted(text, size, weight, ink, column, align, line_height, lines, highlight=None, lit=None, kern=0.0, floor=40):
    """Renders the text at `size`, stepping the type down until it holds within `lines` lines, so a
    translation that runs long still sits above the frame instead of under it."""
    while True:
        image = render_text(text, size, weight, ink, column, align, line_height, highlight, lit, kern * size / 100)
        if image.height <= lines * size * line_height * 1.25 + 8 or size <= floor:
            return image
        size = round(size * 0.95)


def text_block(canvas, x, y, headline, subline, head_size, sub_size, spacing, align, width, accent,
               highlight=None, right=96):
    """Paints the headline (two lines at most, one phrase in the panel's colour) and the subline (two
    at most) and returns the y where the block ends."""
    column = width - x - right if align == "left" else width - 2 * right
    lit = mix(accent, (255, 255, 255), 0.30)
    head = fitted(headline, head_size, AppKit.NSFontWeightBold, HEADLINE_INK, column, align, 0.98, 2,
                  highlight, lit, kern=-1.8, floor=70)
    sub = fitted(subline, sub_size, AppKit.NSFontWeightMedium, SUBLINE_INK, column, align, 1.14, 2, floor=34)
    left = x if align == "left" else right
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


def place_device(canvas, master, top, bottom_margin, width_limit, width=None):
    """The framed device under the claim. With a `width` it is that wide and whatever does not fit
    bleeds off the bottom of the panel, which is what makes the screen large enough to read at
    thumbnail size; without one it is scaled whole into the room the claim leaves, nothing of the
    screen cropped, so a composer or a pill at the foot is always in the picture. Returns the device
    as placed and its top-left corner."""
    device = framed(master)
    if width:
        scale = width / device.width
    else:
        scale = min((canvas.height - top - bottom_margin) / device.height, width_limit / device.width)
    device = device.resize((round(device.width * scale), round(device.height * scale)), Image.LANCZOS)
    x = (canvas.width - device.width) // 2
    device_shadow(canvas, device, (x, top))
    canvas.paste(device.convert("RGB"), (x, top), device.split()[3])
    return device, (x, top), scale


def callout(master_img, box, scale, accent, radius=46):
    """A piece of the screen cut out at its own pixels and enlarged, in a rounded card with a
    hairline: the one moment of the panel worth reading at thumbnail size, drawn bigger than the
    device it came from so it reads as the point of the picture rather than a corner of it."""
    w, h = master_img.size
    cut = master_img.crop((round(box[0] * w), round(box[1] * h), round(box[2] * w), round(box[3] * h))).convert("RGB")
    cut = cut.resize((round(cut.width * scale), round(cut.height * scale)), Image.LANCZOS)
    mask = Image.new("L", cut.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, cut.width - 1, cut.height - 1], radius=radius, fill=255)
    card = Image.new("RGBA", cut.size, (0, 0, 0, 0))
    card.paste(cut, (0, 0), mask)
    draw = ImageDraw.Draw(card)
    draw.rounded_rectangle([0, 0, cut.width - 1, cut.height - 1], radius=radius,
                           outline=mix(accent, (255, 255, 255), 0.35) + (150,), width=4)
    return card


def paste_card(canvas, card, center, accent):
    """Sets a callout on the panel by its centre (as fractions of the panel), with a shadow under it
    and a breath of the panel's colour around it."""
    x = round(center[0] * canvas.width - card.width / 2)
    y = round(center[1] * canvas.height - card.height / 2)
    layer = Image.new("L", canvas.size, 0)
    ImageDraw.Draw(layer).rounded_rectangle([x, y + 28, x + card.width, y + card.height + 28], radius=46, fill=190)
    canvas.paste(Image.new("RGB", canvas.size, (0, 0, 0)), (0, 0), layer.filter(ImageFilter.GaussianBlur(46)))
    halo = Image.new("L", canvas.size, 0)
    ImageDraw.Draw(halo).rounded_rectangle([x - 10, y - 10, x + card.width + 10, y + card.height + 10], radius=56, fill=70)
    canvas.paste(Image.new("RGB", canvas.size, accent), (0, 0), halo.filter(ImageFilter.GaussianBlur(34)))
    canvas.paste(card.convert("RGB"), (x, y), card.split()[3])


def compose_iphone(master, entry, spec, locale):
    W, H = 1320, 2868
    accent = hexc(spec["accent"])
    canvas = backdrop(W, H, accent)
    end = text_block(canvas, 96, 150, entry["headline"], entry["subline"], 128, 56, 34, "left", W, accent,
                     entry.get("highlight"))
    if spec.get("kind") == "widgets":
        return compose_widgets(canvas, end, locale, accent).convert("RGB")
    top = end + spec.get("gap", 64)
    device_spec = spec.get("device", {})
    device, (dx, dy), scale = place_device(
        canvas, master, top, 40, W - 150, device_spec.get("width"))
    shot = Image.open(master).convert("RGB")
    for item in spec.get("callouts", []):
        card = callout(shot, item["box"], item["scale"], accent)
        paste_card(canvas, card, item["at"], accent)
    return canvas.convert("RGB")


def compose_widgets(canvas, end, locale, accent):
    """The Home Screen widgets, cut off the harness's key colour and set out the way a Home Screen
    sets them — a medium, two smalls, a large — on the panel's own ground. There is no device: a
    widget is a thing on a Home Screen and the family is the picture."""
    folder = os.path.join(WIDGET_TILES, locale)
    if not os.path.isdir(folder):
        folder = os.path.join(WIDGET_TILES, "en-US")
    tiles = {n: Image.open(os.path.join(folder, n + ".png")).convert("RGBA")
             for n in ("large", "medium", "small-a", "small-b")}
    W = canvas.width
    gap = 44
    rows = [("small-a", "small-b"), ("medium",), ("large",)]
    natural = sum(max(tiles[n].height for n in row) for row in rows) + gap * (len(rows) - 1)
    top = end + 90
    scale = min(1.0, (canvas.height - top - 70) / natural)
    sized = {n: t.resize((round(t.width * scale), round(t.height * scale)), Image.LANCZOS) for n, t in tiles.items()}
    width = sized["large"].width
    left = (W - width) // 2
    y = top
    for row in rows:
        x = left
        height = max(sized[n].height for n in row)
        spare = width - sum(sized[n].width for n in row)
        step = spare // max(1, len(row) - 1) if len(row) > 1 else 0
        for n in row:
            tile = sized[n]
            layer = Image.new("L", canvas.size, 0)
            layer.paste(tile.split()[3].point(lambda a: 150 if a > 200 else 0), (x, y + 24))
            canvas.paste(Image.new("RGB", canvas.size, (0, 0, 0)), (0, 0), layer.filter(ImageFilter.GaussianBlur(40)))
            canvas.paste(tile.convert("RGB"), (x, y), tile.split()[3])
            x += tile.width + step
        y += height + round(gap * scale)
    return canvas


def compose_ipad(master, entry, spec, locale):
    """The landscape workspace, whole, in its own bezel: the claim centred above it and the device
    scaled to the room the claim leaves, so no column of the three is cropped away."""
    W, H = 2752, 2064
    accent = hexc(spec["accent"])
    canvas = backdrop(W, H, accent)
    end = text_block(canvas, 0, 96, entry["headline"], entry["subline"], 150, 62, 30, "center", W, accent,
                     entry.get("highlight"), right=140)
    place_device(canvas, master, top=end + 60, bottom_margin=40, width_limit=W - 200)
    return canvas.convert("RGB")


def compose_mac(master, entry, spec, locale):
    W, H = 2880, 1800
    accent = hexc(spec["accent"])
    canvas = backdrop(W, H, accent)
    end = text_block(canvas, 0, 96, entry["headline"], entry["subline"], 124, 54, 28, "center", W, accent,
                     entry.get("highlight"), right=140)
    shot = rounded(Image.open(master).convert("RGB"), 28, 2560)
    x = (W - shot.width) // 2
    y = end + 88
    shadow_under(canvas, [x + 10, y + 20, x + shot.width - 10, H], 28)
    canvas.paste(shot.convert("RGB"), (x, y), shot.split()[3])
    return canvas.convert("RGB").crop((0, 0, W, H))


ACCENTS = ["#546BFF", "#FFB020", "#A855F7", "#30D158", "#32C8E6", "#FF5FA2", "#FF7A29", "#6E78FF", "#3DDC97", "#8C98FF"]


def spec_for(specs, platform, index, slug):
    """The layout of a panel: its own entry in layout.json where it has one, else the next colour
    round the palette, so a panel added to a manifest is never unstyled."""
    if slug in specs:
        return specs[slug]
    return {"accent": ACCENTS[index % len(ACCENTS)]}


def emit(label, source_dir, folder, entries, compose, locale, specs, platform):
    os.makedirs(folder, exist_ok=True)
    for index, entry in enumerate(entries):
        spec = spec_for(specs, platform, index, entry["slug"])
        path = os.path.join(source_dir, entry["master"] + ".png")
        if spec.get("kind") != "widgets" and not os.path.exists(path):
            sys.exit(f"missing master {path}")
        panel = compose(path, entry, spec, locale)
        out = os.path.join(folder, entry["slug"] + ".png")
        panel.save(out, optimize=True)
        print(f"  {label}/{entry['slug']}.png")
    for stale in sorted(set(os.listdir(folder)) - {e["slug"] + ".png" for e in entries}):
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
    emit(f"{locale}/{platform}", source, panels_dir(locale, platform), panels, compose, locale, layout(), platform)


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
        entries = [dict(master=m, slug=slug, headline=h, subline=sub, highlight=hl) for m, slug, h, sub, hl in MAC]
        emit("mac", MAC_IN, os.path.join(OUT, "mac"), entries, compose_mac, "en-US", layout(), "mac")


if __name__ == "__main__":
    main()
