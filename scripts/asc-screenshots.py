#!/usr/bin/env python3
"""Upload Tailscode's App Store screenshots for every locale the listing carries.

The composed panels live in marketing/appstore/panels: iphone/ and ipad/ are the
en-US sets, l10n/<locale>/iphone/ the localized iPhone sets. Apple falls back to
the primary locale for any set a locale does not carry, so the iPad is uploaded
for en-US only and es-MX borrows the es-ES panels; en-GB and en-AU carry nothing
and show the en-US set. The Mac set (panels/mac) goes on the MAC_OS version.

Everything goes through `asc screenshots upload`, which fans out over a
<dir>/<locale>/<platform>/*.png tree: this script only stages that tree (as
copies under a scratch directory — asc refuses symlinks) and then verifies every set on the store
reads COMPLETE with the expected count.

Usage: python3 scripts/asc-screenshots.py <marketing-version> [--platform=ios|macos] [--dry-run]
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PANELS = os.path.join(ROOT, "marketing/appstore/panels")
APP = "6791660932"
BORROWED = {"es-MX": "es-ES"}
SETS = {"ios": [("iphone", "APP_IPHONE_67"), ("ipad", "APP_IPAD_PRO_3GEN_129")],
        "macos": [("mac", "APP_DESKTOP")]}


def asc(*args):
    result = subprocess.run(["asc", *args, "--output", "json"], capture_output=True, text=True)
    body = result.stdout[result.stdout.find("{"):] if "{" in result.stdout else result.stdout
    if result.returncode != 0:
        sys.exit(f"asc {' '.join(args)} failed:\n{result.stdout[-2000:]}\n{result.stderr[-2000:]}")
    return json.loads(body) if body.strip().startswith("{") else result.stdout


def version_id(marketing, platform):
    wanted = "MAC_OS" if platform == "macos" else "IOS"
    for row in asc("versions", "list", "--app", APP).get("data", []):
        a = row["attributes"]
        if a["versionString"] == marketing and a["platform"] == wanted:
            return row["id"]
    sys.exit(f"no {wanted} version {marketing}")


def locales_on(version):
    rows = asc("localizations", "list", "--version", version).get("data", [])
    return {r["attributes"]["locale"]: r["id"] for r in rows}


def source_dir(locale, platform):
    """Where this locale's panels are for one platform, or None when it shows the primary set."""
    if platform == "mac":
        return os.path.join(PANELS, "mac") if locale == "en-US" else None
    locale = BORROWED.get(locale, locale)
    if locale == "en-US":
        return os.path.join(PANELS, platform)
    path = os.path.join(PANELS, "l10n", locale, platform)
    return path if os.path.isdir(path) else None


def stage(locales, platform):
    """Builds the <dir>/<locale>/<platform> tree asc fans out over, returning (dir, {locale: count})."""
    root = tempfile.mkdtemp(prefix="tailscode-shots-")
    counts = {}
    for locale in locales:
        source = source_dir(locale, platform)
        if source is None:
            continue
        target = os.path.join(root, locale, platform)
        os.makedirs(target)
        files = sorted(f for f in os.listdir(source) if f.endswith(".png"))
        for name in files:
            shutil.copyfile(os.path.join(source, name), os.path.join(target, name))
        counts[locale] = len(files)
    return root, counts


def verify(localizations, display_type, counts):
    """Every localization that was given a set reads back with that many COMPLETE screenshots."""
    bad = []
    for locale, loc_id in sorted(localizations.items()):
        expected = counts.get(locale, 0)
        if not expected:
            continue
        sets = asc("screenshots", "list", "--version-localization", loc_id).get("sets", [])
        mine = [s for s in sets if s["set"]["attributes"]["screenshotDisplayType"] == display_type]
        shots = mine[0].get("screenshots", []) if mine else []
        states = sorted({(s["attributes"].get("assetDeliveryState") or {}).get("state") for s in shots})
        if len(shots) != expected or states != ["COMPLETE"]:
            bad.append(f"{locale} {display_type}: {len(shots)} shots {states}, expected {expected}")
        else:
            print(f"  {locale} {display_type}: {len(shots)} COMPLETE")
    return bad


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if len(args) != 1:
        sys.exit("usage: asc-screenshots.py <marketing-version> [--platform=ios|macos] [--dry-run]")
    marketing = args[0]
    platform = "macos" if "--platform=macos" in sys.argv else "ios"
    dry = "--dry-run" in sys.argv
    version = version_id(marketing, platform)
    localizations = locales_on(version)
    print(f"{platform} {marketing} ({version}): {', '.join(sorted(localizations))}")
    for folder, display_type in SETS[platform]:
        root, counts = stage(sorted(localizations), folder)
        print(f"== {display_type}: {counts}")
        cmd = ["asc", "screenshots", "upload", "--app", APP, "--version-id", version, "--path", root,
               "--device-type", display_type, "--replace", "--confirm"]
        if dry:
            cmd.append("--dry-run")
        print("   " + " ".join(cmd))
        result = subprocess.run(cmd)
        shutil.rmtree(root)
        if result.returncode != 0:
            sys.exit(f"upload failed for {display_type}")
        if dry:
            continue
        bad = verify(localizations, display_type, counts)
        if bad:
            sys.exit("!! " + "\n!! ".join(bad))


if __name__ == "__main__":
    main()
