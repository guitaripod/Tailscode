#!/usr/bin/env python3
"""Validate the composed App Store panels against the marketing contract (docs/marketing-2026-10.md).

For every file under marketing/appstore/panels it checks the things a store upload would refuse or
the contract promised: dimensions for the device class, a PNG with no alpha channel, ten panels per
locale and device, file names that are exactly the caption manifest's slugs, nothing else in the
tree, a size under the store's limit, and that every panel sits on the contract's one ground colour.

  scripts/market-validate.py                 # everything
  scripts/market-validate.py iphone          # one device class
  scripts/market-validate.py --locale ja     # one locale
  scripts/market-validate.py creative        # only the product page creative assets
  scripts/market-validate.py duo             # the iPhone Duo panels and what is staged for the store

The iPhone Duo set (panels/duo and panels/l10n/<locale>/duo) is the iPhone captions on the four sizes
App Store Connect takes for APP_IPHONE_DUO, 1398x2034, 2034x1398, 2007x2853 and 2853x2007: each slug's
size is the Duo table of marketing/captions/layout.json, every size of the four is used, and store/shots/duo
holds exactly the ten slugs for every locale, en-GB, en-AU and es-MX included.

The product page creative assets (marketing/appstore/creative/<locale>/) are checked too: header
3840x1646, search 3840x2560 and the 16:9 universal 5244x2950, PNG, no alpha.

Exits 1 and lists every failure when anything is wrong.
"""
import json
import os
import sys

from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PANELS = os.path.join(ROOT, "marketing/appstore/panels")
CAPTIONS = os.path.join(ROOT, "marketing/captions")

SIZES = {"iphone": (1320, 2868), "ipad": (2752, 2064), "mac": (2880, 1800), "duo": None}
DUO_SIZES = {(1398, 2034), (2034, 1398), (2007, 2853), (2853, 2007)}
CAPTION_KEY = {"duo": "iphone"}
STAGE = os.path.join(ROOT, "store/shots/duo")
STAGE_COPIES = {"en-GB": "en-US", "en-AU": "en-US", "es-MX": "es-ES"}
PER_LOCALE = 10
MAX_BYTES = 8 * 1024 * 1024
GROUND = (11, 13, 17)
GROUND_TOLERANCE = 6
PROBES = ((0.01, 0.012), (0.03, 0.12), (0.03, 0.17))
REQUIRED = {"iphone": "all", "ipad": ["en-US"], "mac": ["en-US"], "duo": "all"}


def locales():
    return sorted(f[:-5] for f in os.listdir(CAPTIONS) if f.endswith(".json") and f != "layout.json")


def manifest(locale, device):
    """The file names a locale's panels of this device must have, from its caption book."""
    with open(os.path.join(CAPTIONS, locale + ".json")) as f:
        return [entry["slug"] + ".png" for entry in json.load(f)[CAPTION_KEY.get(device, device)]]


def duo_table():
    """Each slug's size and pose on the Duo set, from the layout book."""
    with open(os.path.join(CAPTIONS, "layout.json")) as f:
        return json.load(f)["duo"]


def expected_size(device, name):
    if device == "duo":
        return tuple(duo_table()[name[:-4]]["size"])
    return SIZES[device]


def folder(locale, device):
    if locale == "en-US":
        return os.path.join(PANELS, device)
    return os.path.join(PANELS, "l10n", locale, device)


def has_alpha(image):
    return image.mode in ("RGBA", "LA", "PA") or "transparency" in image.info


def distance(a, b):
    return max(abs(x - y) for x, y in zip(a, b))


def check_image(path, expected, failures):
    label = os.path.relpath(path, PANELS)
    if os.path.getsize(path) >= MAX_BYTES:
        failures.append(f"{label}: {os.path.getsize(path)} bytes, over the 8 MB limit")
    try:
        image = Image.open(path)
        image.load()
    except Exception as error:
        failures.append(f"{label}: unreadable ({error})")
        return
    if image.format != "PNG":
        failures.append(f"{label}: {image.format}, not PNG")
    if image.size != expected:
        failures.append(f"{label}: {image.size[0]}x{image.size[1]}, expected {expected[0]}x{expected[1]}")
    if has_alpha(image):
        failures.append(f"{label}: has an alpha channel")
    rgb = image.convert("RGB")
    for fx, fy in PROBES:
        pixel = rgb.getpixel((round(fx * (rgb.width - 1)), round(fy * (rgb.height - 1))))
        if distance(pixel, GROUND) > GROUND_TOLERANCE:
            failures.append(f"{label}: ground at ({fx:.2f}, {fy:.2f}) is {pixel}, the contract's is {GROUND}")
            break


def check_folder(locale, device, failures, counted):
    path = folder(locale, device)
    label = f"{locale}/{device}"
    if not os.path.isdir(path):
        failures.append(f"{label}: no panels at {os.path.relpath(path, ROOT)}")
        return
    expected = manifest(locale, device)
    present = sorted(os.listdir(path))
    if len(expected) != PER_LOCALE:
        failures.append(f"{label}: the caption manifest lists {len(expected)} panels, expected {PER_LOCALE}")
    for name in expected:
        if name not in present:
            failures.append(f"{label}: missing {name}")
    for name in present:
        if name not in expected:
            failures.append(f"{label}: stray {name}, not in the manifest")
    pngs = [n for n in present if n in expected]
    if len(pngs) != PER_LOCALE:
        failures.append(f"{label}: {len(pngs)} manifest panels present, expected {PER_LOCALE}")
    for name in pngs:
        check_image(os.path.join(path, name), expected_size(device, name), failures)
        counted.append(1)
    if device == "duo":
        check_duo_set(label, expected, failures)


def check_duo_set(label, names, failures):
    """The Duo set's table: every slug has an entry naming one of the four store sizes, and the ten
    together use all four."""
    table = duo_table()
    used = set()
    for name in names:
        entry = table.get(name[:-4])
        if not entry:
            failures.append(f"{label}: layout.json duo has no entry for {name[:-4]}")
            continue
        used.add(tuple(entry["size"]))
        if tuple(entry["size"]) not in DUO_SIZES:
            failures.append(f"{label}: {name} is set at {entry['size']}, not one of the four Duo sizes")
    for size in sorted(DUO_SIZES - used):
        failures.append(f"{label}: no panel uses {size[0]}x{size[1]}")


def check_stage(failures, counted):
    """store/shots/duo: for every caption locale and the three regions that copy one, exactly the ten
    slugs, each the Duo table's size, PNG, no alpha, and the copies byte for byte what they copy."""
    if not os.path.isdir(STAGE):
        failures.append("store/shots/duo: not staged")
        return
    expected = sorted(manifest("en-US", "duo"))
    wanted = sorted(locales() + list(STAGE_COPIES))
    for name in sorted(set(os.listdir(STAGE)) - set(wanted)):
        failures.append(f"store/shots/duo/{name}: not a locale")
    for locale in wanted:
        folder_path = os.path.join(STAGE, locale)
        label = f"store/shots/duo/{locale}"
        if not os.path.isdir(folder_path):
            failures.append(f"{label}: missing")
            continue
        present = sorted(os.listdir(folder_path))
        if present != expected:
            failures.append(f"{label}: holds {len(present)} files, expected exactly the ten slugs ({sorted(set(present) ^ set(expected))})")
            continue
        origin = STAGE_COPIES.get(locale, locale)
        for name in expected:
            file = os.path.join(folder_path, name)
            image = Image.open(file)
            if image.format != "PNG" or has_alpha(image) or image.size != expected_size("duo", name):
                failures.append(f"{label}/{name}: {image.format} {image.size}, alpha {has_alpha(image)}")
            source = os.path.join(folder(origin, "duo"), name)
            if not os.path.exists(source) or open(source, "rb").read() != open(file, "rb").read():
                failures.append(f"{label}/{name}: differs from the panel of {origin}")
            counted.append(1)


CREATIVE = {"header-3840x1646.png": (3840, 1646), "search-3840x2560.png": (3840, 2560),
            "universal-5244x2950.png": (5244, 2950)}


def check_creative(locale, failures, counted):
    """The product page creative assets of one locale: exactly the three files, each the size Apple's
    creative-asset specification lists, PNG with no alpha, under the size limit, on the contract's ground."""
    path = os.path.join(ROOT, "marketing/appstore/creative", locale)
    label = f"creative/{locale}"
    if not os.path.isdir(path):
        failures.append(f"{label}: no assets at {os.path.relpath(path, ROOT)}")
        return
    present = sorted(os.listdir(path))
    for name in CREATIVE:
        if name not in present:
            failures.append(f"{label}: missing {name}")
    for name in present:
        if name not in CREATIVE:
            failures.append(f"{label}: stray {name}")
    for name, size in CREATIVE.items():
        if name not in present:
            continue
        file = os.path.join(path, name)
        check_image(file, size, failures)
        counted.append(1)


def stray_folders(device, known, failures):
    """Folders under the panels tree that no locale and device accounts for."""
    root = os.path.join(PANELS, "l10n")
    if os.path.isdir(root):
        for locale in sorted(os.listdir(root)):
            if locale not in known:
                failures.append(f"l10n/{locale}: a folder for a locale with no caption book")
                continue
            for entry in sorted(os.listdir(os.path.join(root, locale))):
                if entry not in SIZES:
                    failures.append(f"l10n/{locale}/{entry}: not a device folder")
    for entry in sorted(os.listdir(PANELS)):
        if entry not in SIZES and entry != "l10n":
            failures.append(f"{entry}: not a device folder")


def main():
    args = sys.argv[1:]
    only_locale = None
    if "--locale" in args:
        i = args.index("--locale")
        only_locale = args[i + 1]
        del args[i:i + 2]
    devices = [a for a in args if a in SIZES] or ([] if "creative" in args else list(SIZES))
    staged = "duo" in devices and not only_locale
    known = locales()
    failures, counted = [], []
    for device in devices:
        wanted = known if REQUIRED[device] == "all" else REQUIRED[device]
        for locale in ([only_locale] if only_locale else wanted):
            check_folder(locale, device, failures, counted)
        if device != "iphone" and not only_locale:
            root = os.path.join(PANELS, "l10n")
            for locale in sorted(os.listdir(root)) if os.path.isdir(root) else []:
                path = os.path.join(root, locale, device)
                if os.path.isdir(path) and locale not in wanted and locale in known:
                    check_folder(locale, device, failures, counted)
    if staged:
        check_stage(failures, counted)
    if not args or "creative" in args:
        for locale in ([only_locale] if only_locale else known):
            check_creative(locale, failures, counted)
    if not only_locale:
        stray_folders(devices, known, failures)
    print(f"checked {len(counted)} panels across {', '.join(devices)}")
    for failure in failures:
        print("FAIL " + failure)
    if failures:
        sys.exit(f"{len(failures)} failures")
    print("OK: sizes, no alpha, ten per locale, manifest names, nothing extra, under 8 MB, one ground"
          + (", the four Duo sizes" if "duo" in devices else "") + (", the store folders" if staged else ""))


if __name__ == "__main__":
    main()
