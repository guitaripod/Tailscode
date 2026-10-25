#!/usr/bin/env python3
"""The ten Mac App Store panels, composed from the masters scripts/shots-mac-panels.py photographs.

A master is the app on a 1280x832-point screen exactly as the window server drew it, glass and all.
This script makes it a store panel in four moves:

  1. the screen gets a real menu bar: the app's own menu titles (read from the string catalog in
     the panel's language), the Apple mark and a few status items, drawn over the empty strip the
     wallpaper leaves at the top, because the menu bar the window server drew carries whatever the
     person who took the picture had up there;
  2. the screen is framed in a MacBook by the `frames` CLI, which picks the device from the size of
     the screen it is given, never a bezel drawn here;
  3. the claim is set in the top zone: at most two lines in the heaviest system weight, one phrase lit
     in amber, one quiet subline;
  4. the framed laptop is placed large and bleeds off the bottom edge, so the interesting part of the
     screen fills the panel.

Text goes through AppKit, so every script the listing speaks falls back to the right system face.
Every caption box is measured and the run fails rather than let a translation touch the device.

  scripts/market-compose-mac.py                    # English, all ten
  scripts/market-compose-mac.py --locale de-DE     # one locale
  scripts/market-compose-mac.py --all              # English and the ten other locales
  scripts/market-compose-mac.py --contact PATH     # also write a contact sheet of what was made

Masters:  marketing/appstore/mac-masters/<locale>/<name>.png (a locale without its own masters
          is told over the English chrome and says so)
Captions: marketing/captions/<locale>.json, key "mac" (the caption book)
Panels:   marketing/appstore/panels/mac/<slug>.png for en-US,
          marketing/appstore/panels/l10n/<locale>/mac/<slug>.png otherwise
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
MASTERS = os.path.join(ROOT, "marketing/appstore/mac-masters")
PANELS = os.path.join(ROOT, "marketing/appstore/panels")
CATALOG = os.path.join(ROOT, "Resources/Localizable.xcstrings")
CAPTIONS = os.environ.get("TAILSCODE_CAPTIONS", os.path.join(ROOT, "marketing/captions"))
FRAME_CACHE = os.path.join(tempfile.gettempdir(), "tailscode-mac-frames")

W, H = 2880, 1800
INK = (11, 13, 17)
LIFT = (19, 22, 29)
AMBER = (255, 181, 71)
HEADLINE = (245, 242, 234)
SUBLINE = (168, 174, 184)
SIDE = 110
TOP = 64
DEVICE_WIDTH = 3560
DEVICE_TOP = 490
GAP = 10

LOCALES = ["de-DE", "es-ES", "fr-FR", "it", "ja", "ko", "pl", "pt-BR", "zh-Hans", "zh-Hant"]
CATALOG_CODE = {"de-DE": "de", "es-ES": "es", "fr-FR": "fr", "it": "it", "ja": "ja", "ko": "ko",
                "pl": "pl", "pt-BR": "pt-BR", "zh-Hans": "zh-Hans", "zh-Hant": "zh-Hant"}
FOCUS = {
    "fl-party": (3180, 0.50),
    "06-analytics": (3300, 0.50),
}
MENU_TITLES = ["File", "Edit", "Chat", "Model", "View", "Go", "Studio", "Window", "Help"]


def utf16(text, upto):
    return len(text[:upto].encode("utf-16-le")) // 2


def color(rgb, alpha=1.0):
    return AppKit.NSColor.colorWithSRGBRed_green_blue_alpha_(rgb[0] / 255, rgb[1] / 255, rgb[2] / 255, alpha)


def attributed(text, size, weight, rgb, line_height=1.0, align="left", lit=None, phrase=None, kern=0.0):
    paragraph = AppKit.NSMutableParagraphStyle.alloc().init()
    paragraph.setAlignment_(AppKit.NSTextAlignmentCenter if align == "center" else AppKit.NSTextAlignmentLeft)
    paragraph.setLineHeightMultiple_(line_height)
    attributes = {
        AppKit.NSFontAttributeName: AppKit.NSFont.systemFontOfSize_weight_(size, weight),
        AppKit.NSForegroundColorAttributeName: color(rgb),
        AppKit.NSParagraphStyleAttributeName: paragraph,
        AppKit.NSKernAttributeName: kern,
    }
    string = Foundation.NSMutableAttributedString.alloc().initWithString_attributes_(text, attributes)
    if phrase and lit and phrase in text:
        start = text.index(phrase)
        string.addAttribute_value_range_(
            AppKit.NSForegroundColorAttributeName, color(lit),
            (utf16(text, start), utf16(text, start + len(phrase)) - utf16(text, start)))
    return string


def widest_line(string, width):
    """The width of the longest line once the text is wrapped at `width`, and how many lines it took."""
    storage = AppKit.NSTextStorage.alloc().initWithAttributedString_(string)
    manager = AppKit.NSLayoutManager.alloc().init()
    container = AppKit.NSTextContainer.alloc().initWithSize_((width, 100000))
    container.setLineFragmentPadding_(0)
    manager.addTextContainer_(container)
    storage.addLayoutManager_(manager)
    manager.glyphRangeForTextContainer_(container)
    widest, lines = 0.0, 0
    index = 0
    count = manager.numberOfGlyphs()
    while index < count:
        rect = manager.lineFragmentUsedRectForGlyphAtIndex_effectiveRange_(index, None)
        used, span = rect[0], rect[1]
        widest = max(widest, used.size.width)
        lines += 1
        index = span.location + span.length
    return widest, lines


def draw(string, width, height):
    """The attributed text as an RGBA image `width` by `height`, transparent where nothing is drawn."""
    rep = AppKit.NSBitmapImageRep.alloc().initWithBitmapDataPlanes_pixelsWide_pixelsHigh_bitsPerSample_samplesPerPixel_hasAlpha_isPlanar_colorSpaceName_bytesPerRow_bitsPerPixel_(
        None, width, height, 8, 4, True, False, AppKit.NSCalibratedRGBColorSpace, 0, 0)
    context = AppKit.NSGraphicsContext.graphicsContextWithBitmapImageRep_(rep)
    AppKit.NSGraphicsContext.saveGraphicsState()
    AppKit.NSGraphicsContext.setCurrentContext_(context)
    string.drawWithRect_options_context_(((0, 0), (width, height)), AppKit.NSStringDrawingUsesLineFragmentOrigin, None)
    context.flushGraphics()
    AppKit.NSGraphicsContext.restoreGraphicsState()
    png = rep.representationUsingType_properties_(AppKit.NSBitmapImageFileTypePNG, None)
    return Image.open(io.BytesIO(bytes(png))).convert("RGBA")


def block(text, size, weight, rgb, column, lines, line_height, floor, **kw):
    """A text block fitted to `lines` lines no wider than `column`, stepping the size down until it
    holds. Returns the image, the size it settled on and the measured widest line."""
    while True:
        string = attributed(text, size, weight, rgb, line_height, **kw)
        widest, count = widest_line(string, column)
        bounds = string.boundingRectWithSize_options_context_(
            (column, 100000), AppKit.NSStringDrawingUsesLineFragmentOrigin, None)
        if (count <= lines and widest <= column) or size <= floor:
            height = int(math.ceil(bounds.size.height)) + 8
            return draw(string, column, height), size, widest, count
        size = round(size * 0.96)


def catalog():
    with open(CATALOG) as f:
        return json.load(f)["strings"]


def menu_titles(locale, strings):
    """The menu bar's words in the panel's language, from the same string catalog the app reads."""
    code = CATALOG_CODE.get(locale)
    out = []
    for key in MENU_TITLES:
        value = key
        if code:
            entry = strings.get(key, {}).get("localizations", {}).get(code)
            if entry and "stringUnit" in entry:
                value = entry["stringUnit"]["value"]
        out.append(value)
    return out


def symbol(name, size, rgb=(255, 255, 255), alpha=0.92):
    image = AppKit.NSImage.imageWithSystemSymbolName_accessibilityDescription_(name, None)
    if image is None:
        return None
    config = AppKit.NSImageSymbolConfiguration.configurationWithPointSize_weight_scale_(
        size, AppKit.NSFontWeightRegular, AppKit.NSImageSymbolScaleMedium)
    image = image.imageWithSymbolConfiguration_(config)
    box = image.size()
    width, height = int(math.ceil(box.width)) + 4, int(math.ceil(box.height)) + 4
    rep = AppKit.NSBitmapImageRep.alloc().initWithBitmapDataPlanes_pixelsWide_pixelsHigh_bitsPerSample_samplesPerPixel_hasAlpha_isPlanar_colorSpaceName_bytesPerRow_bitsPerPixel_(
        None, width, height, 8, 4, True, False, AppKit.NSCalibratedRGBColorSpace, 0, 0)
    context = AppKit.NSGraphicsContext.graphicsContextWithBitmapImageRep_(rep)
    AppKit.NSGraphicsContext.saveGraphicsState()
    AppKit.NSGraphicsContext.setCurrentContext_(context)
    image.drawInRect_fromRect_operation_fraction_(((2, 2), (box.width, box.height)), ((0, 0), (0, 0)),
                                                  AppKit.NSCompositingOperationSourceOver, 1.0)
    color(rgb, alpha).set()
    AppKit.NSRectFillUsingOperation(((0, 0), (width, height)), AppKit.NSCompositingOperationSourceAtop)
    context.flushGraphics()
    AppKit.NSGraphicsContext.restoreGraphicsState()
    png = rep.representationUsingType_properties_(AppKit.NSBitmapImageFileTypePNG, None)
    return Image.open(io.BytesIO(bytes(png))).convert("RGBA")


def text_width(string):
    bounds = string.boundingRectWithSize_options_context_((4000, 100), AppKit.NSStringDrawingUsesLineFragmentOrigin, None)
    return int(math.ceil(bounds.size.width)) + 4


def menu_extent(titles, size):
    """Where the last menu title ends at this size: the Apple mark, then every title and its gap."""
    x = 34 + size + 30 + 26
    for index, title in enumerate(titles):
        weight = AppKit.NSFontWeightBold if index == 0 else AppKit.NSFontWeightMedium
        x += text_width(attributed(title, size, weight, (255, 255, 255))) + 30
    return x


def menu_bar(master, wallpaper, locale, strings):
    """The screen with the empty top strip of the wallpaper put back and a menu bar drawn on it. The
    notch is the frame's, so nothing is drawn within its width of the centre."""
    screen = master.copy()
    bar = 66
    screen.paste(wallpaper.crop((0, 0, screen.width, bar + 6)), (0, 0))
    overlay = Image.new("RGBA", screen.size, (0, 0, 0, 0))
    ImageDraw.Draw(overlay).rectangle([0, 0, screen.width, bar], fill=(0, 0, 0, 58))
    screen.paste(overlay, (0, 0), overlay)
    titles = ["Tailscode"] + menu_titles(locale, strings)
    size = 24
    while size > 16 and menu_extent(titles, size) > 1090:
        size -= 1
    x = 34
    apple = symbol("apple.logo", size + 2)
    if apple:
        screen.paste(apple, (x, (bar - apple.height) // 2), apple)
        x += apple.width + 26
    for index, title in enumerate(titles):
        weight = AppKit.NSFontWeightBold if index == 0 else AppKit.NSFontWeightMedium
        string = attributed(title, size, weight, (255, 255, 255))
        width = text_width(string)
        image = draw(string, width, 40)
        alpha = image.split()[3].point(lambda a: int(a * 0.93))
        screen.paste(Image.new("RGB", image.size, (255, 255, 255)), (x, (bar - image.height) // 2 + 1), alpha)
        x += width + 30
    if x > 1100:
        sys.exit(f"the menu titles reach {x}px, into the notch")
    right = screen.width - 34
    clock = attributed("Tue 13 Oct  9:41", size, AppKit.NSFontWeightMedium, (255, 255, 255))
    bounds = clock.boundingRectWithSize_options_context_((4000, 100), AppKit.NSStringDrawingUsesLineFragmentOrigin, None)
    width = int(math.ceil(bounds.size.width)) + 4
    image = draw(clock, width, 40)
    screen.paste(Image.new("RGB", image.size, (255, 255, 255)), (right - width, (bar - image.height) // 2 + 1),
                 image.split()[3].point(lambda a: int(a * 0.93)))
    right -= width + 34
    for name in ("switch.2", "magnifyingglass", "battery.100percent", "wifi"):
        icon = symbol(name, size)
        if icon:
            screen.paste(icon, (right - icon.width, (bar - icon.height) // 2), icon)
            right -= icon.width + 30
    return screen


def framed(screen_path):
    """The screen in its MacBook, from `frames`, cached by the screen's bytes."""
    with open(screen_path, "rb") as f:
        key = hashlib.sha1(f.read()).hexdigest()[:16]
    folder = os.path.join(FRAME_CACHE, key)
    out = os.path.join(folder, os.path.splitext(os.path.basename(screen_path))[0] + "_framed.png")
    if not os.path.exists(out):
        os.makedirs(folder, exist_ok=True)
        result = subprocess.run(
            ["frames", "-d", "MacBook Air M5 13", "-c", "Silver", "-o", folder, screen_path],
            capture_output=True, text=True)
        if result.returncode != 0 or not os.path.exists(out):
            sys.exit(f"frames failed for {screen_path}:\n{result.stdout}{result.stderr}")
    return Image.open(out).convert("RGBA")


def backdrop():
    """Flat ink with the faintest lift behind the claim."""
    base = Image.new("RGB", (W, H), INK)
    layer = Image.new("L", (W // 4, H // 4), 0)
    ImageDraw.Draw(layer).ellipse([W // 8, -H // 10, W // 8 * 3 + W // 4, H // 4], fill=255)
    layer = layer.filter(ImageFilter.GaussianBlur(120)).resize((W, H), Image.BILINEAR)
    base.paste(Image.new("RGB", (W, H), LIFT), (0, 0), layer.point(lambda a: int(a * 0.55)))
    return base


def compose(master_path, entry, locale, strings, wallpaper, report):
    master = Image.open(master_path).convert("RGB")
    screen = menu_bar(master, wallpaper, locale, strings)
    work = os.path.join(FRAME_CACHE, "screens")
    os.makedirs(work, exist_ok=True)
    screen_path = os.path.join(work, f"{locale}-{entry['master']}.png")
    screen.save(screen_path)
    device = framed(screen_path)
    alpha = device.split()[3].point(lambda a: 255 if a > 8 else 0)
    box = alpha.getbbox()
    device = device.crop(box)
    width, focus = FOCUS.get(entry["master"], (DEVICE_WIDTH, 0.5))
    scale = width / device.width
    device = device.resize((width, round(device.height * scale)), Image.LANCZOS)
    canvas = backdrop().convert("RGBA")
    screen_width = 2560 * scale
    screen_left = W / 2 - focus * screen_width
    if screen_width > W:
        screen_left = min(0, max(W - screen_width, screen_left))
    x = round(screen_left - 323 * scale)
    canvas.paste(device, (x, DEVICE_TOP), device.split()[3])

    column = W - 2 * SIDE
    head, head_size, head_width, head_lines = block(
        entry["headline"], 150, AppKit.NSFontWeightBlack, HEADLINE, column, 2, 0.9, 70,
        align="center", lit=AMBER, phrase=entry.get("highlight"), kern=-2.5)
    sub, sub_size, sub_width, sub_lines = block(
        entry["subline"], 52, AppKit.NSFontWeightMedium, SUBLINE, column, 2, 1.12, 34, align="center")
    y = TOP
    canvas.alpha_composite(head, (SIDE, y))
    sub_y = y + head.height + 6
    canvas.alpha_composite(sub, (SIDE, sub_y))
    bottom = sub_y + sub.height
    lit_ok = (entry.get("highlight") or "") in entry["headline"].replace("\n", " ") or \
        (entry.get("highlight") or "") in entry["headline"]
    report.append({
        "slug": entry["slug"], "locale": locale, "headline_size": head_size, "headline_lines": head_lines,
        "headline_widest": round(head_width), "sub_size": sub_size, "sub_lines": sub_lines,
        "sub_widest": round(sub_width), "text_bottom": bottom, "device_top": DEVICE_TOP,
        "column": column, "lit_found": bool(lit_ok), "master": os.path.relpath(master_path, ROOT),
    })
    if bottom > DEVICE_TOP - GAP:
        sys.exit(f"{locale}/{entry['slug']}: the caption reaches y={bottom}, device starts at {DEVICE_TOP}")
    if head_width > column or sub_width > column:
        sys.exit(f"{locale}/{entry['slug']}: a caption line is wider than the safe column")
    return canvas.convert("RGB")


def captions_for(locale):
    with open(os.path.join(CAPTIONS, locale + ".json")) as f:
        return json.load(f)["mac"]


def run_locale(locale, strings, wallpaper, report):
    masters = os.path.join(MASTERS, locale)
    english = False
    if not os.path.isdir(masters) or len([f for f in os.listdir(masters) if f.endswith(".png")]) < 10:
        masters = os.path.join(MASTERS, "en-US")
        english = locale != "en-US"
    out = os.path.join(PANELS, "mac") if locale == "en-US" else os.path.join(PANELS, "l10n", locale, "mac")
    os.makedirs(out, exist_ok=True)
    entries = captions_for(locale)
    made = []
    for entry in entries:
        path = os.path.join(masters, entry["master"] + ".png")
        if not os.path.exists(path):
            sys.exit(f"missing master {path}")
        panel = compose(path, entry, locale, strings, wallpaper, report)
        target = os.path.join(out, entry["slug"] + ".png")
        panel.save(target, optimize=True)
        made.append(target)
        print(f"  {locale}/{entry['slug']}.png" + ("  (English chrome)" if english else ""))
    keep = {e["slug"] + ".png" for e in entries}
    for stale in sorted(set(os.listdir(out)) - keep):
        if stale.endswith(".png"):
            os.remove(os.path.join(out, stale))
            print(f"  {locale}/{stale} removed (not in the book)")
    return made


def contact(paths, target, columns=5):
    thumbs = [Image.open(p).convert("RGB").resize((576, 360), Image.LANCZOS) for p in paths]
    rows = math.ceil(len(thumbs) / columns)
    sheet = Image.new("RGB", (columns * 576 + (columns + 1) * 12, rows * 360 + (rows + 1) * 12), (34, 36, 42))
    for index, thumb in enumerate(thumbs):
        sheet.paste(thumb, (12 + (index % columns) * 588, 12 + (index // columns) * 372))
    os.makedirs(os.path.dirname(target), exist_ok=True)
    sheet.save(target)


def main():
    args = sys.argv[1:]
    locales = ["en-US"]
    contact_path = None
    if "--locale" in args:
        locales = [args[args.index("--locale") + 1]]
    if "--all" in args:
        locales = ["en-US"] + LOCALES
    if "--contact" in args:
        contact_path = args[args.index("--contact") + 1]
    wallpaper = Image.open(os.path.join(MASTERS, "wallpaper.png")).convert("RGB")
    strings = catalog()
    report = []
    made = []
    for locale in locales:
        made += run_locale(locale, strings, wallpaper, report)
    reports = os.path.join(FRAME_CACHE, "fit-report.json")
    with open(reports, "w") as f:
        json.dump(report, f, indent=1, ensure_ascii=False)
    if contact_path:
        contact(made, contact_path)


if __name__ == "__main__":
    main()
