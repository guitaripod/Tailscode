#!/usr/bin/env python3
"""Compose the iPhone Duo App Store panels from the Duo masters.

The Duo set tells the iPhone set's story (marketing/captions/<locale>.json, key "iphone": the same ten
captions, word for word, so no new translation exists to drift) on the four sizes App Store Connect
takes for APP_IPHONE_DUO, shared by one set of ten per locale:

  outer portrait 1398x2034   outer landscape 2034x1398   inner portrait 2007x2853   inner landscape 2853x2007

Each panel has its own size and master, chosen to show its caption best: the Duo table of
marketing/captions/layout.json says, by slug, which master (and which pose it was shot in), which of
the four sizes, and where the device sits. The house style is market-compose.py's, whose helpers this
imports: one flat ink ground, the amber lit phrase, the heaviest system weight, the hairline motif
through a node at the margin, and the framed device from the `frames` CLI, never a drawn bezel.

A portrait panel puts the caption on top and lets the device bleed off the bottom, like the iPhone set.
A landscape panel puts the caption in a column on the left and the whole device on the right, so
nothing a caption sits beside is ever cut. The headline is one size per orientation and locale, in
proportion to the panel's width, fitted by measuring, never by cutting words.

Masters:  marketing/appstore/duo/<slug>.png for en-US, marketing/appstore/l10n/<locale>/duo/<slug>.png
          otherwise: the raw simulator captures at the slot size the Duo table names
Panels:   marketing/appstore/panels/duo/<slug>.png, marketing/appstore/panels/l10n/<locale>/duo/<slug>.png
Stage:    store/shots/duo/<locale>/<slug>.png (en-GB and en-AU copy en-US, es-MX copies es-ES)

  scripts/market-compose-duo.py                    # every locale that has masters
  scripts/market-compose-duo.py --locale ja        # one locale
  scripts/market-compose-duo.py --check-fit        # measure every caption of every locale, compose nothing
  scripts/market-compose-duo.py --stage            # copy the panels to store/shots/duo
  scripts/market-compose-duo.py --contact PATH     # also write a contact sheet of what was made

Run it with a Python that has Pillow and PyObjC and `frames` on PATH (the macbook's ~/scratch-compose/venv).
"""
import importlib.util
import json
import os
import shutil
import sys

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("compose", os.path.join(HERE, "market-compose.py"))
compose = importlib.util.module_from_spec(spec)
spec.loader.exec_module(compose)

ROOT = compose.ROOT
MASTERS = os.path.join(ROOT, "marketing/appstore/duo")
L10N_IN = compose.L10N_IN
PANELS = os.path.join(compose.OUT, "duo")
STAGE = os.path.join(ROOT, "store/shots/duo")

FRAME_COLOR = "Star White"
SIZES = {
    "outer-portrait": (1398, 2034),
    "outer-landscape": (2034, 1398),
    "inner-portrait": (2007, 2853),
    "inner-landscape": (2853, 2007),
}
STATE_SLOT = {
    "outer-portrait": "outer-portrait", "outer-landscape": "outer-landscape",
    "inner-portrait": "inner-portrait", "laptop-portrait": "inner-portrait",
    "inner-landscape": "inner-landscape", "book-landscape": "inner-landscape",
}
COPIES = {"en-GB": "en-US", "en-AU": "en-US", "es-MX": "es-ES"}

PORTRAIT = {
    "ref": 1398, "margin": 0.0667, "motif_y": 0.0606, "head_y": 0.103, "cap_share": 0.085,
    "floor_share": 0.057, "sub_size": 0.041, "sub_floor": 0.032, "gap": 0.021, "device_top": 0.335,
    "device_width": 0.985, "align": "left", "sub_lines": 2.4,
}
LANDSCAPE = {
    "ref": 2034, "margin": 0.048, "motif_y": 0.058, "head_y": None, "cap_share": 0.034,
    "floor_share": 0.021, "sub_size": 0.0225, "sub_floor": 0.0175, "gap": 0.014, "column": 0.285,
    "device_width": 0.65, "device_x": 0.345, "align": "left", "sub_lines": 5.0,
}


def duo_table():
    with open(compose.LAYOUT) as f:
        return json.load(f)["duo"]


def entries(locale):
    """The ten captions of a locale: its iphone entries, verbatim."""
    return [dict(e) for e in compose.captions(locale)["iphone"]]


def orientation(size):
    return "portrait" if size[1] > size[0] else "landscape"


def base(size):
    return PORTRAIT if orientation(size) == "portrait" else LANDSCAPE


def metrics(size, extra=None):
    """The panel's geometry in pixels: the set's fractions of its width (and of its height for the
    portrait device's top), overridden by the slug's own entry in the Duo table."""
    W, H = size
    b = {**base(size), **(extra or {})}
    head_basis = W if orientation(size) == "portrait" else H
    head_y = None if b["head_y"] is None else round(b["head_y"] * head_basis)
    out = {
        "size": size, "align": b["align"], "margin": round(b["margin"] * W), "motif_y": round(b["motif_y"] * W),
        "head_y": head_y, "cap_share": b["cap_share"], "floor_share": b["floor_share"],
        "sub_size": round(b["sub_size"] * W), "sub_floor": round(b["sub_floor"] * W),
        "gap": round(b["gap"] * W), "sub_lines": b["sub_lines"],
        "device_width": round(b["device_width"] * W), "device_x": round(b.get("device_x", 0.5) * W),
    }
    if orientation(size) == "portrait":
        out["device_top"] = round(b["device_top"] * H)
        out["column"] = W - 2 * out["margin"]
    else:
        out["column"] = round(b["column"] * W)
    return out


def sub_fit(text, spec):
    """The subline's size and rendered image: started large and stepped down until it holds within the
    lines the orientation allows, never below the floor."""
    size = spec["sub_size"]
    while True:
        image = compose.render_text(text, size, compose.SUBLINE_WEIGHT, compose.SUBLINE_INK, spec["column"],
                                    spec["align"], compose.SUBLINE_LEADING)
        lines = (image.height - 6) / (size * compose.SUBLINE_LEADING * 1.19)
        if lines <= spec["sub_lines"] or size <= spec["sub_floor"]:
            return size, image, lines
        size = round(size * 0.96)


def caption_block(canvas, spec, entry, head_size):
    """Paints the headline and the subline and returns where the block ends and what a checker needs."""
    kern = compose.HEADLINE_KERN * head_size / 100
    head = compose.render_text(entry["headline"], head_size, compose.HEADLINE_WEIGHT, compose.HEADLINE_INK,
                               spec["column"], spec["align"], compose.HEADLINE_LEADING, entry.get("highlight"),
                               compose.ACCENT, kern)
    sub_size, sub, sub_lines = sub_fit(entry["subline"], spec)
    head_y = spec["head_y"] if spec["head_y"] is not None else centred_y(head, sub, spec)
    canvas.paste(head, (spec["margin"], head_y), head)
    sub_y = head_y + head.height + spec["gap"]
    canvas.paste(sub, (spec["margin"], sub_y), sub)
    return {
        "end": sub_y + sub.height, "start": head_y, "head_box": compose.ink_box(head), "sub_lines": sub_lines, "sub_size": sub_size,
        "head_height": head.height,
    }


def centred_y(head, sub, spec):
    """Where a landscape panel's caption block starts so the block sits on the panel's middle, a little
    above it, beside the device and clear of the hairline at the top."""
    height = head.height + spec["gap"] + sub.height
    middle = (spec["size"][1] - height) // 2 - round(0.02 * spec["size"][1])
    return max(middle, spec["motif_y"] + compose.CLEAR)


def clear_room(spec):
    """The y a caption block must end above: the device's top in a portrait panel, where the device
    sits under the caption, and the panel's bottom margin in a landscape one, where it sits beside it."""
    if "device_top" in spec:
        return spec["device_top"] - compose.CLEAR
    return spec["size"][1] - spec["margin"]


def block_end(entry, head_size, spec):
    canvas = Image.new("RGBA", spec["size"], compose.GROUND + (255,))
    return caption_block(canvas, spec, entry, head_size)["end"]


MAX_REFLOW_LINES = 3.3


def shaped(row, reflow):
    """The caption row as it is set: with the author's line breaks, or, when a column is too narrow for
    them, as one line of words the column wraps."""
    if not reflow:
        return row
    return {**row, "headline": " ".join(row["headline"].split("\n"))}


def head_lines(row, head, column):
    """How many lines a headline takes in a column at a size, and whether its widest unbreakable run
    fits: the author's breaks are measured line by line, a reflowed headline by drawing it."""
    kern = compose.HEADLINE_KERN * head / 100
    if "\n" in row["headline"]:
        widths = compose.line_widths(row["headline"], head, compose.HEADLINE_WEIGHT, kern)
        return len(widths), max(widths)
    widest_word = max(max(compose.line_widths(word, head, compose.HEADLINE_WEIGHT, kern)) for word in row["headline"].split())
    image = compose.render_text(row["headline"], head, compose.HEADLINE_WEIGHT, compose.HEADLINE_INK, column, "left",
                                compose.HEADLINE_LEADING, kern=kern)
    return (image.height - 6) / (head * compose.HEADLINE_LEADING * 1.19), widest_word


def head_holds(group, head, spec, reflow):
    """Whether every caption of a group holds in the column at this headline size."""
    limit = 2.0 if not reflow else MAX_REFLOW_LINES
    for row in group:
        lines, widest = head_lines(shaped(row, reflow), head, spec["column"])
        if widest > spec["column"] * 0.985 or lines > limit + 0.01:
            return False
    return True


def head_fraction(rows, name, table):
    """The headline setting of one orientation: its size as a fraction of the panel's width and whether
    the captions are reflowed. The widest size at which every caption of that orientation holds within
    its column with its own line breaks and every block ends clear of its device; a locale whose words
    cannot do that above the legible floor reflows its landscape headlines over up to three lines
    instead. Measured at the orientation's reference width, since all of it scales."""
    group = [r for r in rows if orientation(table[r["slug"]]["size"]) == name]
    if not group:
        return None
    reference = PORTRAIT if name == "portrait" else LANDSCAPE
    ref = reference["ref"]
    probe = SIZES["outer-portrait" if name == "portrait" else "outer-landscape"]
    spec = metrics((ref, round(ref * probe[1] / probe[0])))
    floor = reference["floor_share"] * ref / compose.CAP_RATIO
    best = None
    for reflow in (False, True) if name == "landscape" else (False,):
        head = reference["cap_share"] * ref / compose.CAP_RATIO
        while head > 20 and not head_holds(group, head, spec, reflow):
            head *= 0.98
        head = round(head)
        while head > 40 and max(block_end(shaped(r, reflow), head, spec) for r in group) > clear_room(spec):
            head = round(head * 0.98)
        best = (head / ref, reflow)
        if head >= floor:
            break
    return best


def head_fractions(rows, table):
    return {name: head_fraction(rows, name, table) for name in ("portrait", "landscape")}


def master_path(locale, slug):
    if locale == "en-US":
        return os.path.join(MASTERS, slug + ".png")
    return os.path.join(L10N_IN, locale, "duo", slug + ".png")


def panel_dir(locale):
    return PANELS if locale == "en-US" else os.path.join(compose.OUT, "l10n", locale, "duo")


def place_device(canvas, master, top, width, x):
    """The framed device at `width`, whatever does not fit bleeding off the panel, with its shadow."""
    device = compose.framed(master, FRAME_COLOR)
    scale = width / device.width
    device = device.resize((round(device.width * scale), round(device.height * scale)), Image.LANCZOS)
    compose.device_shadow(canvas, device, (x, top))
    canvas.paste(device.convert("RGB"), (x, top), device.split()[3])
    return device


def place_portrait(canvas, master, spec, entry):
    """The device under the caption of a portrait panel. By default it bleeds off the bottom. An entry
    can `crop` it, a fraction of the device's height hidden behind the ground so the part that sells
    rises to the caption, or `fit` it, scaled down to stand whole above the panel's bottom margin."""
    W, H = spec["size"]
    framed = compose.framed(master, FRAME_COLOR)
    width = spec["device_width"]
    height = round(framed.height * width / framed.width)
    if entry.get("fit"):
        room = H - spec["device_top"] - round(entry.get("bottom", 0.03) * H)
        if height > room:
            width, height = round(width * room / height), room
    base = canvas.copy()
    top = spec["device_top"] - round(entry.get("crop", 0) * height)
    place_device(canvas, master, top, width, (W - width) // 2)
    if entry.get("crop"):
        compose.cropped_top(canvas, base, spec["device_top"], entry.get("fade", round(0.02 * W)))


def compose_panel(master, row, entry, setting):
    """One panel. Portrait: the caption on top, the device from `device_top`. Landscape: the caption in
    the left column, the whole device on the right, centred on the panel's height unless the entry gives
    a `top`."""
    size = tuple(entry["size"])
    W, H = size
    spec = metrics(size, entry)
    portrait = orientation(size) == "portrait"
    canvas = compose.ground(W, H) if portrait else compose.ground(W, H, lift_at=(0.68, 0.5), lift_radius=0.36)
    if portrait:
        place_portrait(canvas, master, spec, entry)
    else:
        framed = compose.framed(master, FRAME_COLOR)
        height = round(framed.height * spec["device_width"] / framed.width)
        top = round(entry["top"] * H) if "top" in entry else (H - height) // 2
        place_device(canvas, master, top, spec["device_width"], spec["device_x"])
    compose.motif(canvas, spec)
    fraction, reflow = setting
    caption_block(canvas, spec, shaped(row, reflow), round(fraction * W))
    return canvas.convert("RGB")


def fit_issues(locale, rows, table):
    """Every way a locale's captions fail to hold on its panels: a headline line wider than its column,
    glyphs touching the column edge, a lit phrase not in the headline, a headline over the lines its
    setting allows, a subline that needs more lines than its column allows at its floor, a block that
    reaches its device, a headline below the legible floor."""
    issues = []
    settings = head_fractions(rows, table)
    for row in rows:
        entry = table[row["slug"]]
        size = tuple(entry["size"])
        who = f"{locale}/duo/{row['slug']}"
        spec = metrics(size, entry)
        fraction, reflow = settings[orientation(size)]
        head = round(fraction * size[0])
        floor = spec["floor_share"] * size[0] / compose.CAP_RATIO
        if head < floor:
            issues.append(f"{who}: headline set at {head}px, below the legible floor of {round(floor)}px")
        setting_row = shaped(row, reflow)
        lines, widest = head_lines(setting_row, head, spec["column"])
        if widest > spec["column"]:
            issues.append(f"{who}: headline run of {round(widest)}px in a {spec['column']}px column")
        if lines > (MAX_REFLOW_LINES if reflow else 2.0) + 0.01:
            issues.append(f"{who}: headline runs to {lines:.1f} lines")
        if row.get("highlight") and not compose.phrase_span(row["headline"], row["highlight"]):
            issues.append(f"{who}: lit phrase {row['highlight']!r} is not in the headline")
        canvas = Image.new("RGBA", size, compose.GROUND + (255,))
        block = caption_block(canvas, spec, setting_row, head)
        left, _, right, _ = block["head_box"]
        if left < 0 or right >= spec["column"] - 1:
            issues.append(f"{who}: headline glyphs touch the column edge ({left}..{right} of {spec['column']})")
        if block["sub_lines"] > spec["sub_lines"]:
            issues.append(f"{who}: subline needs {block['sub_lines']:.1f} lines at its {block['sub_size']}px floor")
        if block["end"] > clear_room(spec) + 24:
            issues.append(f"{who}: caption ends at {block['end']}px, past {clear_room(spec)}px")
    return issues, settings


def check_fit(wanted):
    failures = 0
    table = duo_table()
    for locale in wanted or compose.locales():
        issues, settings = fit_issues(locale, entries(locale), table)
        shown = "  ".join(f"{k} {v[0] * 100:.2f}% of width{' reflowed' if v[1] else ''}" for k, v in settings.items() if v)
        print(f"{locale:8} duo  headline {shown}  {'ok' if not issues else str(len(issues)) + ' issues'}")
        for issue in issues:
            print("    " + issue)
        failures += len(issues)
    if failures:
        sys.exit(f"{failures} caption fit issues")


def emit_locale(locale, table):
    missing = [slug for slug in table if not os.path.exists(master_path(locale, slug))]
    if missing:
        print(f"  {locale}/duo: masters missing for {', '.join(missing)}, skipped")
        return
    rows = entries(locale)
    settings = head_fractions(rows, table)
    folder = panel_dir(locale)
    os.makedirs(folder, exist_ok=True)
    for row in rows:
        entry = table[row["slug"]]
        size = tuple(entry["size"])
        master = master_path(locale, row["slug"])
        with Image.open(master) as shot:
            if shot.size != size or SIZES[STATE_SLOT[entry["state"]]] != size:
                sys.exit(f"{master} is {shot.size}, the Duo table says {entry['state']} at {size}")
        panel = compose_panel(master, row, entry, settings[orientation(size)])
        panel.save(os.path.join(folder, row["slug"] + ".png"), optimize=True)
        print(f"  {locale}/duo/{row['slug']}.png  {size[0]}x{size[1]}")
    for stale in sorted(set(os.listdir(folder)) - {r["slug"] + ".png" for r in rows}):
        if stale.endswith(".png"):
            os.remove(os.path.join(folder, stale))
            print(f"  {locale}/duo/{stale} removed (not in the manifest)")


def stage():
    """Copies the composed panels where `midgar shots` reads them: exactly the ten slugs per locale."""
    slugs = [r["slug"] + ".png" for r in entries("en-US")]
    shutil.rmtree(STAGE, ignore_errors=True)
    for locale in compose.locales():
        for target in [locale] + [c for c, origin in COPIES.items() if origin == locale]:
            os.makedirs(os.path.join(STAGE, target), exist_ok=True)
            for name in slugs:
                shutil.copy(os.path.join(panel_dir(locale), name), os.path.join(STAGE, target, name))
    print(f"staged {len(os.listdir(STAGE))} locales at {os.path.relpath(STAGE, ROOT)}")


def contact(path, locale, height=900):
    """One sheet of a locale's ten panels in store order, each scaled to the same height."""
    images = [Image.open(os.path.join(panel_dir(locale), e["slug"] + ".png")).convert("RGB") for e in entries(locale)]
    images = [i.resize((round(i.width * height / i.height), height), Image.LANCZOS) for i in images]
    columns = 5
    rows = [images[i:i + columns] for i in range(0, len(images), columns)]
    gap = 12
    width = max(sum(i.width for i in row) + gap * (len(row) + 1) for row in rows)
    sheet = Image.new("RGB", (width, (height + gap) * len(rows) + gap), (40, 40, 44))
    y = gap
    for row in rows:
        x = gap
        for image in row:
            sheet.paste(image, (x, y))
            x += image.width + gap
        y += height + gap
    sheet.save(path)
    print(f"contact sheet {path}")


def main():
    args = sys.argv[1:]
    wanted = None
    if "--locale" in args:
        i = args.index("--locale")
        wanted = [args[i + 1]]
        del args[i:i + 2]
    contact_path = None
    if "--contact" in args:
        i = args.index("--contact")
        contact_path = args[i + 1]
        del args[i:i + 2]
    if "--check-fit" in args:
        check_fit(wanted)
        return
    if "--stage" in args:
        stage()
        return
    table = duo_table()
    for locale in wanted or compose.locales():
        emit_locale(locale, table)
    if contact_path:
        contact(contact_path, (wanted or ["en-US"])[0])


if __name__ == "__main__":
    main()
