#!/usr/bin/env python3
"""Upload Tailscode's macOS App Store screenshots (en-US): one APP_DESKTOP set.

The Mac train shares the iOS app record, so this is the same three-step asset dance the iPhone
set uses — reserve (POST /v1/appScreenshots → uploadOperations) → PUT the bytes → commit
(PATCH uploaded=true + MD5) — against the MAC_OS version's en-US localization. The order is the
story the listing tells: a conversation working, the question it stops to ask, the repository
behind it, the month's numbers, the commands the server offers, and the box that opens anywhere.

Usage: python3 asc-mac-screenshots.py [--replace]
"""
import hashlib
import os
import sys
import time

import requests

sys.path.insert(0, os.path.expanduser("~/Dev/operator/lib"))
import asc  # noqa: E402

VERSION = "23e8cf30-6f9c-4020-ad92-ed9a0aec85e3"
DISPLAY_TYPE = "APP_DESKTOP"
FOLDER = os.environ.get(
    "TAILSCODE_SHOTS_OUT",
    os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                 "marketing/appstore/panels/mac"))
ORDER = [
    "01-native-on-mac.png",
    "02-two-machines.png",
    "03-repo-truth.png",
    "04-month-in-numbers.png",
    "05-priced-turns.png",
    "06-one-chord-away.png",
]


def localization(locale):
    locs = asc.get(f"/v1/appStoreVersions/{VERSION}/appStoreVersionLocalizations")["data"]
    return next(l["id"] for l in locs if l["attributes"]["locale"] == locale)


def screenshot_set(loc_id):
    sets = asc.get(f"/v1/appStoreVersionLocalizations/{loc_id}/appScreenshotSets")["data"]
    for entry in sets:
        if entry["attributes"]["screenshotDisplayType"] == DISPLAY_TYPE:
            return entry["id"], False
    made = asc.post("/v1/appScreenshotSets", {"data": {
        "type": "appScreenshotSets",
        "attributes": {"screenshotDisplayType": DISPLAY_TYPE},
        "relationships": {"appStoreVersionLocalization": {
            "data": {"type": "appStoreVersionLocalizations", "id": loc_id}}}}})
    return made["data"]["id"], True


def existing(set_id):
    return asc.get(f"/v1/appScreenshotSets/{set_id}/appScreenshots")["data"]


def upload_one(set_id, path):
    data = open(path, "rb").read()
    name = os.path.basename(path)
    reserved = asc.post("/v1/appScreenshots", {"data": {
        "type": "appScreenshots",
        "attributes": {"fileName": name, "fileSize": len(data)},
        "relationships": {"appScreenshotSet": {
            "data": {"type": "appScreenshotSets", "id": set_id}}}}})
    shot = reserved["data"]
    for operation in shot["attributes"]["uploadOperations"]:
        chunk = data[operation["offset"]:operation["offset"] + operation["length"]]
        headers = {h["name"]: h["value"] for h in operation["requestHeaders"]}
        response = requests.request(operation["method"], operation["url"],
                                    headers=headers, data=chunk, timeout=180)
        response.raise_for_status()
    asc.patch(f"/v1/appScreenshots/{shot['id']}", {"data": {
        "type": "appScreenshots", "id": shot["id"],
        "attributes": {"uploaded": True,
                       "sourceFileChecksum": hashlib.md5(data).hexdigest()}}})
    return shot["id"], name


def settle(ids):
    """An asset is not uploaded until Apple says it is: poll every reservation until its delivery
    state is complete, and quote whatever it says instead of when it is not."""
    pending = dict(ids)
    for _ in range(40):
        for shot_id in list(pending):
            state = asc.get(f"/v1/appScreenshots/{shot_id}")["data"]["attributes"]
            delivery = state.get("assetDeliveryState") or {}
            if delivery.get("state") == "COMPLETE":
                print(f"  COMPLETE  {pending.pop(shot_id)}")
            elif delivery.get("errors"):
                print(f"  FAILED    {pending[shot_id]}: {delivery}")
                pending.pop(shot_id)
        if not pending:
            return
        time.sleep(6)
    for shot_id, name in pending.items():
        print(f"  PENDING   {name} ({shot_id})")


def main():
    loc = localization("en-US")
    set_id, made = screenshot_set(loc)
    print(f"en-US {loc} · set {set_id}" + (" (created)" if made else ""))
    have = existing(set_id)
    if have and "--replace" not in sys.argv:
        sys.exit(f"the set already holds {len(have)} screenshots — pass --replace")
    for shot in have:
        asc.delete(f"/v1/appScreenshots/{shot['id']}")
    uploaded = []
    for name in ORDER:
        path = os.path.join(FOLDER, name)
        shot_id, filename = upload_one(set_id, path)
        print(f"  uploaded  {filename}  {shot_id}")
        uploaded.append((shot_id, filename))
    asc.patch(f"/v1/appScreenshotSets/{set_id}/relationships/appScreenshots", {
        "data": [{"type": "appScreenshots", "id": shot_id} for shot_id, _ in uploaded]})
    settle(uploaded)


if __name__ == "__main__":
    main()
