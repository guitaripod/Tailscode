#!/usr/bin/env python3
"""Compose the App Store marketing panels from the raw screenshot masters.

A raw screenshot shows a surface; a store panel has to *sell* it at thumbnail
size, where the first three images are the whole pitch. Every panel therefore
burns one claim into the picture and sets the screenshot, framed in its real
bezel, large enough to read under it. The contract is docs/marketing-2026-10.md:

  - one flat ink ground (#0B0D11) for the whole set, with at most a faint lift of
    light behind the device; no colour wash, no per-panel hue
  - one accent (#FFB547), used for the lit phrase of the headline and for the
    set's one motif, a hairline that runs edge to edge through a node at every
    panel's margin, so the panels join into one tailnet down the carousel
  - a warm-white headline in the heaviest system weight, two lines at most, one
    size for the whole set of a locale, and a grey subline under it
  - the device bleeds off the bottom edge, so the useful part of the UI is large

The words live in marketing/captions/<locale>.json (iphone and ipad here, each a list
of panels; the Mac set has its own composer, scripts/market-compose-mac.py), and
everything about a panel that is not language lives in marketing/captions/layout.json
by slug. Text is drawn through AppKit so every
script the listing speaks falls back to the right system face on its own, and
every size is fitted by measuring, never by cutting words: `--check-fit` renders
the captions of every locale and fails on overflow, clipping, a collision with
the device, or a set whose headline has fallen below the legible floor.

Masters:  marketing/appstore/iphone/*.png (1320x2868) and marketing/appstore/ipad/*.png (2752x2064) for
          en-US; marketing/appstore/l10n/<locale>/{iphone,ipad}/*.png for every other locale
Panels:   marketing/appstore/panels/{iphone,ipad}/*.png for en-US,
          marketing/appstore/panels/l10n/<locale>/{iphone,ipad}/*.png otherwise

Panel filenames are the story slugs, numbered in store order.

  scripts/market-compose.py                    # everything, every locale that has masters
  scripts/market-compose.py iphone             # one platform, every locale
  scripts/market-compose.py iphone --locale ja # one platform, one locale
  scripts/market-compose.py --check-fit        # measure every caption of every locale, compose nothing
"""
import hashlib
import io
import json
import math
import os
import re
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
CAPTIONS = os.path.join(ROOT, "marketing/captions")
LAYOUT = os.path.join(CAPTIONS, "layout.json")
OUT = os.path.join(ROOT, "marketing/appstore/panels")

FRAME_COLOR = "Silver"
FRAME_CACHE = os.path.join(tempfile.gettempdir(), "tailscode-frames")

GROUND = (11, 13, 17)
ACCENT = (255, 181, 71)
HEADLINE_INK = (245, 242, 234)
SUBLINE_INK = (168, 174, 184)
CLEAR = 28

HEADLINE_WEIGHT = AppKit.NSFontWeightHeavy
SUBLINE_WEIGHT = AppKit.NSFontWeightMedium
CAP_RATIO = 0.7046
HEADLINE_KERN = -0.6
HEADLINE_LEADING = 0.99
SUBLINE_LEADING = 1.16

PHONE = {
    "size": (1320, 2868), "margin": 88, "motif_y": 80, "head_y": 136, "cap_share": 0.085,
    "floor_share": 0.060, "sub_size": 54, "sub_floor": 42, "gap": 28, "device_top": 700,
    "device_width": 1276, "align": "left",
}
IPAD_SCREEN = (2752, 2064)
IPAD_ORIGIN = (124, 118)

PAD = {
    "size": (2752, 2064), "margin": 150, "motif_y": 80, "head_y": 132, "cap_share": 0.046,
    "floor_share": 0.034, "sub_size": 60, "sub_floor": 46, "gap": 28, "device_top": 650,
    "device_width": 2060, "align": "center",
}

def locales():
    return sorted(f[:-5] for f in os.listdir(CAPTIONS) if f.endswith(".json") and f != "layout.json")


def captions(locale):
    """One locale's caption book."""
    with open(os.path.join(CAPTIONS, locale + ".json")) as f:
        return json.load(f)


def manifest(entries):
    """The panels a locale tells, as dicts: master, slug, headline, subline and the phrase of the
    headline to light, which a locale may leave out."""
    return [dict(p) for p in entries]


def layout():
    """Everything about a panel that is not language: what it needs beyond the set's defaults."""
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


def utf16(text, upto):
    return len(text[:upto].encode("utf-16-le")) // 2


def phrase_span(text, phrase):
    """Where the lit phrase sits in the headline, or None. The phrase is matched across a line break
    as well as a space, because a translation may break the line inside the phrase it lights."""
    if not phrase:
        return None
    pattern = r"\s+".join(re.escape(word) for word in phrase.split())
    found = re.search(pattern, text)
    return (found.start(), found.end()) if found else None


def attributed(text, size, weight, rgb, align, line_height, highlight=None, lit=None, kern=0.0):
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
    span = phrase_span(text, highlight) if lit else None
    if span:
        string.addAttribute_value_range_(
            AppKit.NSForegroundColorAttributeName, color(lit),
            (utf16(text, span[0]), utf16(text, span[1]) - utf16(text, span[0])))
    return string


def render_text(text, size, weight, rgb, max_width, align, line_height, highlight=None, lit=None, kern=0.0):
    """Draws one block of text through AppKit so every script the listing speaks — Latin, kana,
    hangul, han — falls back to the right system face on its own. `highlight` is a phrase of the text
    to draw in `lit`. Returns an RGBA image the width of the column and exactly as tall as the text."""
    string = attributed(text, size, weight, rgb, align, line_height, highlight, lit, kern)
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


def line_widths(text, size, weight, kern, line_height=1.0):
    """The natural width of every explicit line of `text`, which is what has to fit the column."""
    widths = []
    for line in text.split("\n"):
        string = attributed(line or " ", size, weight, HEADLINE_INK, "left", line_height, kern=kern)
        bounds = string.boundingRectWithSize_options_context_(
            (100000, 100000), AppKit.NSStringDrawingUsesLineFragmentOrigin, None)
        widths.append(bounds.size.width)
    return widths


def headline_size(texts, column, width, spec):
    """One headline size for every panel of a set: the cap height the contract asks for, stepped down
    only as far as the longest line of the longest panel needs to hold within the column. A set
    whose type changed size from panel to panel would read as a mistake down the carousel."""
    size = spec["cap_share"] * width / CAP_RATIO
    while size > 20:
        kern = HEADLINE_KERN * size / 100
        widest = max(max(line_widths(t, size, HEADLINE_WEIGHT, kern)) for t in texts)
        if widest <= column:
            break
        size *= 0.98
    return round(size)


def sub_fit(text, column, spec):
    """The subline's size and rendered image: started large and stepped down until it holds in two
    lines, never below the floor — past it the caller reports the overflow instead of hiding it."""
    size = spec["sub_size"]
    while True:
        image = render_text(text, size, SUBLINE_WEIGHT, SUBLINE_INK, column, spec["align"], SUBLINE_LEADING)
        lines = (image.height - 6) / (size * SUBLINE_LEADING * 1.19)
        if lines <= 2.4 or size <= spec["sub_floor"]:
            return size, image, lines
        size = round(size * 0.96)


def ink_box(image):
    """The box the visible glyphs occupy in a rendered text image."""
    return image.split()[3].point(lambda a: 255 if a > 24 else 0).getbbox()


def glow(canvas, center, radius, alpha, color=ACCENT):
    """A blurred disc of `color` laid on a canvas at `center`; the blur runs at a quarter of the size,
    which is indistinguishable and an order of magnitude faster. The promo video's ground uses it."""
    scale = 4
    small = (canvas.width // scale, canvas.height // scale)
    layer = Image.new("L", small, 0)
    r = radius / scale
    cx, cy = center[0] / scale, center[1] / scale
    ImageDraw.Draw(layer).ellipse([cx - r, cy - r, cx + r, cy + r], fill=alpha)
    layer = layer.filter(ImageFilter.GaussianBlur(r / 2)).resize(canvas.size, Image.BILINEAR)
    canvas.paste(Image.new("RGB", canvas.size, color), (0, 0), layer)


def fitted(text, size, weight, ink, column, align, line_height, lines, highlight=None, lit=None, kern=0.0, floor=40):
    """Renders the text at `size`, stepping the type down until it holds within `lines` lines, so a
    translation that runs long still sits above the frame instead of under it."""
    while True:
        image = render_text(text, size, weight, ink, column, align, line_height, highlight, lit, kern * size / 100)
        if image.height <= lines * size * line_height * 1.25 + 8 or size <= floor:
            return image
        size = round(size * 0.95)


def ground(width, height, lift_at=(0.5, 0.74), lift_radius=0.62, lift_alpha=15):
    """The flat ink ground with a faint lift of light behind the device, which is what lets the
    bezel's edge be seen against it. No colour: the lift is white."""
    canvas = Image.new("RGBA", (width, height), GROUND + (255,))
    scale = 4
    layer = Image.new("L", (width // scale, height // scale), 0)
    r = lift_radius * width / scale
    cx, cy = lift_at[0] * width / scale, lift_at[1] * height / scale
    ImageDraw.Draw(layer).ellipse([cx - r, cy - r, cx + r, cy + r], fill=lift_alpha)
    layer = layer.filter(ImageFilter.GaussianBlur(r / 2.2)).resize(canvas.size, Image.BILINEAR)
    canvas.paste(Image.new("RGB", canvas.size, (255, 255, 255)), (0, 0), layer)
    return canvas


def backdrop(width, height, accent=None):
    """The set's ground, for a panel that does not choose its own lift."""
    return ground(width, height)


def motif(canvas, spec):
    """The set's one device: a hairline of the accent that runs edge to edge at the top of every
    panel and passes through a node at the margin, so ten panels side by side read as one line
    through ten nodes — the tailnet the product is about. The node is a lit core in a soft ring."""
    W = canvas.width
    y, x = spec["motif_y"], spec["margin"] + 6
    scale = 2
    layer = Image.new("RGBA", (W * scale, 60 * scale), (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    cy = 30 * scale
    draw.line([(0, cy), (W * scale, cy)], fill=ACCENT + (120,), width=3 * scale)
    draw.ellipse([(x - 20) * scale, cy - 20 * scale, (x + 20) * scale, cy + 20 * scale],
                 fill=GROUND + (255,), outline=ACCENT + (170,), width=3 * scale)
    draw.ellipse([(x - 8) * scale, cy - 8 * scale, (x + 8) * scale, cy + 8 * scale], fill=ACCENT + (255,))
    layer = layer.resize((W, 60), Image.LANCZOS)
    canvas.paste(layer, (0, y - 30), layer)


def caption_block(canvas, spec, entry, head_size, lit=ACCENT):
    """Paints the headline and the subline at the set's size and returns the y where the block ends
    and every measurement a checker needs: ink boxes, line count, the room used."""
    W = canvas.width
    margin = spec["margin"]
    column = W - 2 * margin
    kern = HEADLINE_KERN * head_size / 100
    head = render_text(entry["headline"], head_size, HEADLINE_WEIGHT, HEADLINE_INK, column, spec["align"],
                       HEADLINE_LEADING, entry.get("highlight"), lit, kern)
    sub_size, sub, sub_lines = sub_fit(entry["subline"], column, spec)
    canvas.paste(head, (margin, spec["head_y"]), head)
    sub_y = spec["head_y"] + head.height + spec["gap"]
    canvas.paste(sub, (margin, sub_y), sub)
    return {
        "end": sub_y + sub.height, "head_box": ink_box(head), "sub_box": ink_box(sub), "column": column,
        "head_size": head_size, "sub_size": sub_size, "sub_lines": sub_lines, "head_height": head.height,
        "sub_y": sub_y,
    }


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


def device_shadow(canvas, device, position, blur=60, alpha=150, drop=30):
    """A shadow cast by the bezel's own outline, so the shape under the device is the device's."""
    layer = Image.new("L", canvas.size, 0)
    layer.paste(device.split()[3].point(lambda a: alpha if a > 200 else 0), (position[0], position[1] + drop))
    layer = layer.filter(ImageFilter.GaussianBlur(blur))
    canvas.paste(Image.new("RGB", canvas.size, (0, 0, 0)), (0, 0), layer)


def place_device(canvas, master, top, bottom_margin, width_limit, width=None, x=None):
    """The framed device under the claim. With a `width` it is that wide and whatever does not fit
    bleeds off the bottom of the panel, which is what makes the screen large enough to read at
    thumbnail size; without one it is scaled whole into the room the claim leaves, nothing of the
    screen cropped. Returns the device as placed, its top-left corner and the scale."""
    device = framed(master)
    if width:
        scale = width / device.width
    else:
        scale = min((canvas.height - top - bottom_margin) / device.height, width_limit / device.width)
    device = device.resize((round(device.width * scale), round(device.height * scale)), Image.LANCZOS)
    if x is None:
        x = (canvas.width - device.width) // 2
    device_shadow(canvas, device, (x, top))
    canvas.paste(device.convert("RGB"), (x, top), device.split()[3])
    return device, (x, top), scale


def masked(master, rects):
    """The master with system chrome blanked out where `rects` (pixel boxes of the master) say, saved
    beside the framing cache. The iPad's workspace shots draw no status bar; the first-run screen is
    not part of that workspace, so the strip the system lays down its side is blanked to match."""
    if not rects:
        return master
    shot = Image.open(master).convert("RGB")
    for box in rects:
        ImageDraw.Draw(shot).rectangle(box, fill=(0, 0, 0))
    with open(master, "rb") as f:
        key = hashlib.sha1(f.read() + json.dumps(rects).encode()).hexdigest()[:16]
    folder = os.path.join(FRAME_CACHE, "masked-" + key)
    os.makedirs(folder, exist_ok=True)
    path = os.path.join(folder, os.path.basename(master))
    shot.save(path)
    return path


def cropped_top(canvas, base, clip_top, fade):
    """Hides everything the device has put above `clip_top` by laying the bare ground back over it, and
    softens the cut: the device rises out of the ground over `fade` pixels instead of ending on a
    line. This is how a panel crops deeper than the device's own top — the status bar, the island and
    whatever empty screen sits above the part that sells."""
    canvas.paste(base.crop((0, 0, canvas.width, clip_top)), (0, 0))
    if fade:
        box = (0, clip_top, canvas.width, clip_top + fade)
        mask = Image.linear_gradient("L").rotate(180).resize((canvas.width, fade))
        canvas.paste(Image.composite(base.crop(box), canvas.crop(box), mask), box[:2])


def compose_iphone(master, entry, spec, locale, head_size):
    spec = {**PHONE, **spec}
    W, H = spec["size"]
    canvas = ground(W, H)
    base = canvas.copy()
    top = spec["device_top"]
    crop = spec.get("crop", 0)
    if crop:
        device = framed(master)
        scale = spec["device_width"] / device.width
        top = round(spec["device_top"] - crop * device.height * scale)
    place_device(canvas, master, top, 0, W, spec["device_width"])
    if crop:
        cropped_top(canvas, base, spec["device_top"], spec.get("fade", 60))
    motif(canvas, spec)
    caption_block(canvas, spec, entry, head_size)
    return canvas.convert("RGB")


def compose_ipad(master, entry, spec, locale, head_size):
    """The iPad's panel. A panel with a `scale` and an `at` is cropped onto its proof object: the
    master is enlarged `scale` canvas pixels per framed pixel and placed so the point `at` (fractions
    of the screen) lands at the panel's left edge, just under the caption, with the device running
    off both sides and the bottom. One without them shows the whole workspace in its bezel."""
    spec = {**PAD, **spec}
    W, H = spec["size"]
    canvas = ground(W, H, lift_at=(0.5, 0.7), lift_radius=0.5)
    base = canvas.copy()
    path = masked(master, spec.get("mask"))
    if "scale" in spec:
        device = framed(path)
        k = spec["scale"]
        fx, fy = spec["at"]
        x = round(-(IPAD_ORIGIN[0] + fx * IPAD_SCREEN[0]) * k)
        top = round(spec["device_top"] - (IPAD_ORIGIN[1] + fy * IPAD_SCREEN[1]) * k)
        place_device(canvas, path, top, 0, W, round(device.width * k), x)
        cropped_top(canvas, base, spec["device_top"], spec.get("fade", 26))
    else:
        place_device(canvas, path, spec["device_top"], 0, W, spec["device_width"])
    motif(canvas, spec)
    caption_block(canvas, spec, entry, head_size)
    return canvas.convert("RGB")


COMPOSERS = {"iphone": (compose_iphone, PHONE), "ipad": (compose_ipad, PAD)}

def spec_for(specs, platform, slug):
    """The layout of a panel: its own entry in layout.json (by device, then slug) where it has one,
    else the set's defaults."""
    return specs.get(platform, {}).get(slug, {})


def block_end(entry, size, base):
    """Where the caption block of one panel ends when its headline is set at `size`."""
    canvas = Image.new("RGBA", (base["size"][0], 700), GROUND + (255,))
    return caption_block(canvas, base, entry, size)["end"]


def set_size(entries, platform):
    """The one headline size a locale's set of this platform is set in: the widest size at which every
    line holds within the column and every caption ends clear of the device. A script whose line
    height is taller than Latin's, or a language of long words, pays for it here, in the type size,
    and never in words cut from the caption."""
    base = PHONE if platform == "iphone" else PAD
    column = base["size"][0] - 2 * base["margin"]
    size = headline_size([e["headline"] for e in entries], column, base["size"][0], base)
    while size > 40 and max(block_end(e, size, base) for e in entries) > base["device_top"] - CLEAR:
        size = round(size * 0.98)
    return size


def emit(label, source_dir, folder, entries, compose, locale, specs, platform, head_size=None):
    os.makedirs(folder, exist_ok=True)
    for entry in entries:
        spec = spec_for(specs, platform, entry["slug"])
        path = os.path.join(source_dir, entry["master"] + ".png")
        if not os.path.exists(path):
            sys.exit(f"missing master {path}")
        panel = compose(path, entry, spec, locale, head_size) if head_size else compose(path, entry, spec, locale)
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
    panels = manifest(book[platform])
    compose = COMPOSERS[platform][0]
    emit(f"{locale}/{platform}", source, panels_dir(locale, platform), panels, compose, locale, layout(), platform,
         set_size(panels, platform))


def fit_issues(locale, platform, entries):
    """Every way this locale's captions fail to hold: a headline line wider than the column, glyphs
    touching the column's edge once drawn, a headline below the legible floor, a subline that needs
    more than two lines at its floor, and a caption block that reaches the device."""
    base = PHONE if platform == "iphone" else PAD
    W = base["size"][0]
    spec = dict(base)
    column = W - 2 * spec["margin"]
    size = set_size(entries, platform)
    issues = []
    floor = spec["floor_share"] * W / CAP_RATIO
    if size < floor:
        issues.append(f"headline set at {size}px, below the legible floor of {round(floor)}px")
    for entry in entries:
        who = f"{locale}/{platform}/{entry['slug']}"
        kern = HEADLINE_KERN * size / 100
        for line, width in zip(entry["headline"].split("\n"), line_widths(entry["headline"], size, HEADLINE_WEIGHT, kern)):
            if width > column:
                issues.append(f"{who}: headline line {line!r} is {round(width)}px in a {column}px column")
        if len(entry["headline"].split("\n")) > 2:
            issues.append(f"{who}: headline runs to {len(entry['headline'].split(chr(10)))} lines")
        if entry.get("highlight") and not phrase_span(entry["headline"], entry["highlight"]):
            issues.append(f"{who}: lit phrase {entry['highlight']!r} is not in the headline")
        canvas = Image.new("RGBA", (W, spec["size"][1]), GROUND + (255,))
        block = caption_block(canvas, spec, entry, size)
        left, _, right, _ = block["head_box"]
        if left < 0 or right >= column - 1:
            issues.append(f"{who}: headline glyphs touch the column edge ({left}..{right} of {column})")
        if block["sub_lines"] > 2.4:
            issues.append(f"{who}: subline needs {block['sub_lines']:.1f} lines at its {block['sub_size']}px floor")
        room = spec["device_top"] if platform == "iphone" else None
        if room and block["end"] > room - 24:
            issues.append(f"{who}: caption ends at {block['end']}px, within {CLEAR}px of the device at {room}px")
    return issues, size


def check_fit(wanted_locales):
    failures = 0
    for locale in wanted_locales or locales():
        book = captions(locale)
        for platform in ("iphone", "ipad"):
            issues, size = fit_issues(locale, platform, manifest(book[platform]))
            base = PHONE if platform == "iphone" else PAD
            cap = size * CAP_RATIO / base["size"][0] * 100
            print(f"{locale:8} {platform:6} headline {size}px (cap {cap:.1f}% of width)  {'ok' if not issues else str(len(issues)) + ' issues'}")
            for issue in issues:
                print("    " + issue)
            failures += len(issues)
    if failures:
        sys.exit(f"{failures} caption fit issues")


def main():
    args = sys.argv[1:]
    wanted_locales = None
    if "--locale" in args:
        i = args.index("--locale")
        wanted_locales = [args[i + 1]]
        del args[i:i + 2]
    if "--check-fit" in args:
        check_fit(wanted_locales)
        return
    if "mac" in args:
        sys.exit("the Mac set is composed by scripts/market-compose-mac.py")
    wanted = args or ["iphone", "ipad"]
    for platform in ("iphone", "ipad"):
        if platform in wanted:
            for locale in wanted_locales or locales():
                emit_locale(locale, platform)


if __name__ == "__main__":
    main()
