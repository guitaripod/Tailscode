#!/usr/bin/env python3
"""Upload Tailscode's App Store screenshots for every locale the listing carries.

The composed panels live in marketing/appstore/panels: iphone/ and ipad/ are the
en-US sets, l10n/<locale>/iphone/ the localized iPhone sets. Apple falls back to
the primary locale for any set a locale does not carry, so the iPad is uploaded
for en-US only and es-MX borrows the es-ES panels; en-GB and en-AU carry nothing
and show the en-US set. The Mac set (panels/mac) goes on the MAC_OS version.

Every localization is uploaded on its own through `asc screenshots upload
--version-localization`, so one locale's timeout cannot take the rest down
(asc's app-scoped fan-out stops at the first failure, and refuses symlinks);
each set is then read back and must hold the expected count, all COMPLETE.

Usage: python3 scripts/asc-screenshots.py <marketing-version> [--platform=ios|macos] [--only=iphone|ipad] [--skip-existing]
"""
import json
import os
import subprocess
import sys

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


DEVICE = {"iphone": "IPHONE_67", "ipad": "IPAD_PRO_3GEN_129", "mac": "DESKTOP"}


def upload(locale, loc_id, source, platform, replace):
    """One localization, one set. A `--replace` run that dies on asc's checksum-settlement
    timeout (the asset itself lands COMPLETE a moment later) is retried once with
    `--skip-existing`, which picks up exactly the files that never went."""
    flags = ["--replace", "--confirm"] if replace else ["--skip-existing"]
    for attempt, extra in enumerate((flags, ["--skip-existing"])):
        if attempt:
            drop_unsettled(locale, loc_id)
        cmd = ["asc", "screenshots", "upload", "--version-localization", loc_id, "--path", source,
               "--device-type", DEVICE[platform], *extra]
        print(f"  {locale} {platform}: {' '.join(extra)}", flush=True)
        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode == 0:
            return True
        print(f"    attempt {attempt + 1} failed: {(result.stderr or result.stdout)[-300:].strip()}", flush=True)
    return False


def drop_unsettled(locale, loc_id):
    """The asset a timeout left behind sits in UPLOAD_COMPLETE with a checksum asc will not match,
    so the retry would count it against the ten-screenshot cap and refuse; delete it first."""
    for group in asc("screenshots", "list", "--version-localization", loc_id).get("sets", []):
        for shot in group.get("screenshots", []):
            state = (shot["attributes"].get("assetDeliveryState") or {}).get("state")
            if state != "COMPLETE":
                subprocess.run(["asc", "screenshots", "delete", "--id", shot["id"], "--confirm"],
                               capture_output=True, text=True)
                print(f"    {locale}: dropped {shot['attributes'].get('fileName')} ({state})", flush=True)


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
        sys.exit("usage: asc-screenshots.py <marketing-version> [--platform=ios|macos] [--only=iphone|ipad] [--skip-existing]")
    marketing = args[0]
    platform = "macos" if "--platform=macos" in sys.argv else "ios"
    only = next((a.split("=", 1)[1] for a in sys.argv if a.startswith("--only=")), None)
    replace = "--skip-existing" not in sys.argv
    version = version_id(marketing, platform)
    localizations = locales_on(version)
    print(f"{platform} {marketing} ({version}): {', '.join(sorted(localizations))}", flush=True)
    failed = []
    for folder, display_type in SETS[platform]:
        if only and folder != only:
            continue
        counts = {}
        for locale, loc_id in sorted(localizations.items()):
            source = source_dir(locale, folder)
            if source is None:
                continue
            counts[locale] = len([f for f in os.listdir(source) if f.endswith(".png")])
            if not upload(locale, loc_id, source, folder, replace):
                failed.append(f"{locale} {display_type}")
        failed += verify(localizations, display_type, counts)
    if failed:
        sys.exit("!! " + "\n!! ".join(failed))
    print("all sets verified", flush=True)


if __name__ == "__main__":
    main()
