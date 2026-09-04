#!/usr/bin/env python3
"""Push the localized store listing — subtitle, keywords, promotional text, description — to
every locale on every version that is still editable — docs/asc-listing-l10n.json for the iPhone
train, docs/asc-listing-l10n-macos.json for the Mac's, which sells a window rather than a Lock Screen.

The subtitle lives on the app info (shared by every version and platform); keywords, promo and
description live on each platform's version. A version waiting for review is not editable, so
`--reopen` cancels the open review submissions first — the build stays attached, and
scripts/asc-release.py submits again in seconds. Every field is read back after writing.

Usage: python3 scripts/asc-listing.py [--reopen] [<marketing-version>]
"""
import json
import os
import sys
import time

sys.path.insert(0, os.path.expanduser("~/Dev/operator/lib"))
import asc  # noqa: E402

APP = "6791660932"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EDITABLE = ("PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED")


def die(message):
    print(f"!! {message}", file=sys.stderr)
    sys.exit(1)


def reopen():
    subs = asc.get(f"/v1/apps/{APP}/reviewSubmissions",
                   **{"filter[state]": "WAITING_FOR_REVIEW,READY_FOR_REVIEW"}).get("data", [])
    for sub in subs:
        asc.patch(f"/v1/reviewSubmissions/{sub['id']}", {"data": {
            "type": "reviewSubmissions", "id": sub["id"], "attributes": {"canceled": True}}})
        print(f"cancelled {sub['attributes']['platform']} submission {sub['id']}")


def versions(marketing):
    rows = asc.get(f"/v1/apps/{APP}/appStoreVersions", limit="50").get("data", [])
    return [v for v in rows if v["attributes"].get("versionString") == marketing]


def wait_editable(marketing):
    for _ in range(30):
        rows = versions(marketing)
        if rows and all(v["attributes"]["appStoreState"] in EDITABLE for v in rows):
            return rows
        time.sleep(5)
    die(f"{marketing} never became editable: "
        f"{[(v['attributes']['platform'], v['attributes']['appStoreState']) for v in versions(marketing)]}")


def push(books, marketing):
    book = books["IOS"]
    infos = asc.get(f"/v1/apps/{APP}/appInfos")["data"]
    info = next((i for i in infos if i["attributes"].get("appStoreState") in EDITABLE), None)
    if info is None:
        die("no editable app info — the subtitle is locked until a version is reopened")
    for loc in asc.get(f"/v1/appInfos/{info['id']}/appInfoLocalizations")["data"]:
        locale = loc["attributes"]["locale"]
        entry = book.get(locale)
        if not entry:
            continue
        asc.patch(f"/v1/appInfoLocalizations/{loc['id']}", {"data": {
            "type": "appInfoLocalizations", "id": loc["id"],
            "attributes": {"subtitle": entry["subtitle"]}}})
        back = asc.get(f"/v1/appInfoLocalizations/{loc['id']}")["data"]["attributes"]["subtitle"]
        if back != entry["subtitle"]:
            die(f"subtitle {locale} did not stick: {back!r}")
        print(f"subtitle {locale}: {back}")
    for ver in wait_editable(marketing):
        platform = ver["attributes"]["platform"]
        for loc in asc.get(f"/v1/appStoreVersions/{ver['id']}/appStoreVersionLocalizations")["data"]:
            locale = loc["attributes"]["locale"]
            entry = books[platform].get(locale)
            if not entry:
                continue
            attrs = {"keywords": entry["keywords"], "promotionalText": entry["promo"],
                     "description": entry["description"]}
            asc.patch(f"/v1/appStoreVersionLocalizations/{loc['id']}", {"data": {
                "type": "appStoreVersionLocalizations", "id": loc["id"], "attributes": attrs}})
            back = asc.get(f"/v1/appStoreVersionLocalizations/{loc['id']}")["data"]["attributes"]
            for key, wanted in attrs.items():
                if back.get(key) != wanted:
                    die(f"{platform} {locale} {key} did not stick")
            print(f"{platform} {locale}: keywords {len(attrs['keywords'])} · promo "
                  f"{len(attrs['promotionalText'])} · description {len(attrs['description'])}")


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    marketing = args[0] if args else json.load(open(os.path.join(ROOT, "docs/release-notes.json")))
    if not isinstance(marketing, str):
        marketing = next(k for k in marketing if "-" not in k)
    books = {
        "IOS": json.load(open(os.path.join(ROOT, "docs/asc-listing-l10n.json"))),
        "MAC_OS": json.load(open(os.path.join(ROOT, "docs/asc-listing-l10n-macos.json"))),
    }
    if "--reopen" in sys.argv:
        reopen()
    push(books, marketing)


if __name__ == "__main__":
    main()
