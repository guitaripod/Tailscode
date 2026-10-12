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

SIZES = {"iphone": (1320, 2868), "ipad": (2752, 2064), "mac": (2880, 1800)}
PER_LOCALE = 10
MAX_BYTES = 8 * 1024 * 1024
GROUND = (11, 13, 17)
GROUND_TOLERANCE = 6
PROBES = ((0.01, 0.012), (0.03, 0.12), (0.03, 0.17))
REQUIRED = {"iphone": "all", "ipad": ["en-US"], "mac": ["en-US"]}


def locales():
    return sorted(f[:-5] for f in os.listdir(CAPTIONS) if f.endswith(".json") and f != "layout.json")


def manifest(locale, device):
    """The file names a locale's panels of this device must have, from its caption book."""
    with open(os.path.join(CAPTIONS, locale + ".json")) as f:
        return [entry["slug"] + ".png" for entry in json.load(f)[device]]


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
        check_image(os.path.join(path, name), SIZES[device], failures)
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
    print("OK: sizes, no alpha, ten per locale, manifest names, nothing extra, under 8 MB, one ground")


if __name__ == "__main__":
    main()
