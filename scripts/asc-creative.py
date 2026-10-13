#!/usr/bin/env python3
"""Put the iOS 27 product page creative — the 21:9 header and the 3:2 search-result asset — on every
localization of an editable iOS version.

marketing/appstore/creative/<locale>/ holds header-*.png and search-*.png per locale. Each file is
uploaded to the app's asset library once, then assigned to its localization: an existing placement
(a new version copies its predecessor's) is swapped for the new image, a missing one is created.
en-GB and en-AU borrow en-US's files and es-MX borrows es-ES's, as the screenshots do. Every
placement is read back and must name the image that was meant for it.

Usage: python3 scripts/asc-creative.py <marketing-version>
"""
import json
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CREATIVE = os.path.join(ROOT, "marketing/appstore/creative")
APP = "6791660932"
BORROWED = {"en-GB": "en-US", "en-AU": "en-US", "es-MX": "es-ES"}
KINDS = {"header": "PRODUCT_PAGE_HEADER_ASSET", "search": "APP_STORE_SEARCH_RESULTS_ASSET"}


def asc(*args):
    result = subprocess.run(["asc", *args, "--output", "json"], capture_output=True, text=True)
    if result.returncode != 0:
        sys.exit(f"asc {' '.join(args)} failed:\n{result.stdout[-1500:]}\n{result.stderr[-1500:]}")
    body = result.stdout[result.stdout.find("{"):]
    return json.loads(body) if body.strip().startswith("{") else {}


def version_id(marketing):
    for row in asc("versions", "list", "--app", APP, "--platform", "IOS").get("data", []):
        if row["attributes"]["versionString"] == marketing:
            return row["id"]
    sys.exit(f"no iOS version {marketing}")


def source_file(locale, kind):
    folder = os.path.join(CREATIVE, BORROWED.get(locale, locale))
    if not os.path.isdir(folder):
        return None
    return next((os.path.join(folder, name) for name in sorted(os.listdir(folder))
                 if name.startswith(kind + "-") and name.endswith(".png")), None)


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: asc-creative.py <marketing-version>")
    version = version_id(sys.argv[1])
    localizations = {row["attributes"]["locale"]: row["id"]
                     for row in asc("localizations", "list", "--version", version).get("data", [])}
    uploaded = {}
    failed = []
    for locale, localization in sorted(localizations.items()):
        for kind, placement_type in KINDS.items():
            path = source_file(locale, kind)
            if path is None:
                print(f"  {locale} {kind}: no file, shows the primary locale's", flush=True)
                continue
            if path not in uploaded:
                receipt = asc("asset-library", "images", "upload", "--library-id", APP,
                              "--file", path, "--category", "CREATIVE_ASSETS")
                uploaded[path] = receipt["imageId"]
            image = uploaded[path]
            existing = [row for row in asc("localizations", "placements", "list",
                                           "--localization-id", localization).get("data", [])
                        if row["attributes"]["placementType"] == placement_type]
            if existing:
                asc("localizations", "placements", "swap", "--localization-id", localization,
                    "--image-id", image, "--placement-type", placement_type,
                    "--placement-id", existing[0]["id"], "--confirm")
                verb = "swapped"
            else:
                asc("localizations", "placements", "create", "--localization-id", localization,
                    "--image-id", image, "--placement-type", placement_type,
                    "--placement-group", "DEFAULT_PROFILE")
                verb = "created"
            now = [row for row in asc("localizations", "placements", "list",
                                      "--localization-id", localization).get("data", [])
                   if row["attributes"]["placementType"] == placement_type]
            if len(now) != 1 or now[0]["attributes"]["state"] != "ACTIVE":
                failed.append(f"{locale} {kind}: {len(now)} placements")
            print(f"  {locale} {kind}: {verb}", flush=True)
    if failed:
        sys.exit("!! " + "\n!! ".join(failed))
    print("all creative placements verified", flush=True)


if __name__ == "__main__":
    main()
