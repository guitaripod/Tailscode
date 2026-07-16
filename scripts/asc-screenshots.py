#!/usr/bin/env python3
"""Upload Tailscode's App Store screenshots (en-US): 6.9" iPhone only.

Tailscode is iPhone-only (UIDeviceFamily 1), so the listing carries a single
APP_IPHONE_67 set and NO iPad set. This script mirrors the local iphone folder
to ASC exactly: it deletes any stale iPad set, and replaces the iPhone set when
its contents differ from ORDER (so re-running after a screenshot refresh is safe).

ASC asset flow per screenshot: reserve (POST /v1/appScreenshots →
uploadOperations) → PUT the bytes → commit (PATCH uploaded=true + MD5).

Usage: python3 scripts/asc-screenshots.py
"""
import hashlib
import os
import sys

import requests

sys.path.insert(0, os.path.expanduser("~/Dev/operator/lib"))
import asc  # noqa: E402

APP = "6791660932"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ORDER = [
    "01-live.png", "setup.png", "02-work.png", "03-approval.png", "04-question.png",
    "05-subagents.png", "06-render.png", "07-home.png", "08-usage.png", "10-models.png",
]
IPHONE_SET = ("APP_IPHONE_67", os.path.join(ROOT, "marketing/appstore/iphone"))
STALE_SETS = ["APP_IPAD_PRO_3GEN_129"]


def version_localization():
    vers = asc.get(f"/v1/apps/{APP}/appStoreVersions").get("data", [])
    ver = next(v for v in vers if v["attributes"]["appStoreState"]
               in ("PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "METADATA_REJECTED"))
    locs = asc.get(f"/v1/appStoreVersions/{ver['id']}/appStoreVersionLocalizations").get("data", [])
    return next(l["id"] for l in locs if l["attributes"]["locale"] == "en-US")


def screenshot_set(loc_id, display_type):
    sets = asc.get(f"/v1/appStoreVersionLocalizations/{loc_id}/appScreenshotSets").get("data", [])
    for s in sets:
        if s["attributes"]["screenshotDisplayType"] == display_type:
            return s["id"]
    r = asc.post("/v1/appScreenshotSets", {"data": {"type": "appScreenshotSets",
        "attributes": {"screenshotDisplayType": display_type},
        "relationships": {"appStoreVersionLocalization": {
            "data": {"type": "appStoreVersionLocalizations", "id": loc_id}}}}})
    return r["data"]["id"]


def upload_one(set_id, path):
    data = open(path, "rb").read()
    name = os.path.basename(path)
    reserve = asc.post("/v1/appScreenshots", {"data": {"type": "appScreenshots",
        "attributes": {"fileSize": len(data), "fileName": name},
        "relationships": {"appScreenshotSet": {"data": {"type": "appScreenshotSets", "id": set_id}}}}})
    shot_id = reserve["data"]["id"]
    for op in reserve["data"]["attributes"]["uploadOperations"]:
        headers = {h["name"]: h["value"] for h in op["requestHeaders"]}
        chunk = data[op["offset"]:op["offset"] + op["length"]]
        requests.request(op["method"], op["url"], headers=headers, data=chunk, timeout=120).raise_for_status()
    asc.patch(f"/v1/appScreenshots/{shot_id}", {"data": {"type": "appScreenshots", "id": shot_id,
        "attributes": {"uploaded": True, "sourceFileChecksum": hashlib.md5(data).hexdigest()}}})
    print(f"  + {name}")


def all_sets(loc_id):
    return asc.get(f"/v1/appStoreVersionLocalizations/{loc_id}/appScreenshotSets").get("data", [])


def main():
    loc = version_localization()

    for s in all_sets(loc):
        if s["attributes"]["screenshotDisplayType"] in STALE_SETS:
            asc.delete(f"/v1/appScreenshotSets/{s['id']}")
            print(f"deleted stale set {s['attributes']['screenshotDisplayType']}")

    display_type, folder = IPHONE_SET
    set_id = screenshot_set(loc, display_type)
    existing = asc.get(f"/v1/appScreenshotSets/{set_id}/appScreenshots").get("data", [])
    have = [x["attributes"]["fileName"] for x in existing]
    if have == ORDER:
        print(f"{display_type} already matches {len(ORDER)} screenshots — skipping")
        print("DONE")
        return
    for x in existing:
        asc.delete(f"/v1/appScreenshots/{x['id']}")
    if existing:
        print(f"cleared {len(existing)} stale {display_type} screenshots")
    print(f"{display_type}:")
    for name in ORDER:
        upload_one(set_id, os.path.join(folder, name))
    print("DONE")


if __name__ == "__main__":
    main()
