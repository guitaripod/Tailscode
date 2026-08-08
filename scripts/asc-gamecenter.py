#!/usr/bin/env python3
"""Idempotent Game Center provisioner for Tailscode.

Mirrors the trophy catalog in TailscodeCore/Sources/TailscodeCore/Trophies.swift —
that file is the source of truth; a trophy added there is added here in the same
change. Ensures the GAME_CENTER capability on the app's bundle ID, the app's
gameCenterDetail, every achievement and leaderboard with its en-US localization,
and (with --images) renders SF-Symbol artwork on the Mac and uploads it.

Usage: python3 scripts/asc-gamecenter.py [--images]
"""
import json
import os
import subprocess
import sys

import requests

sys.path.insert(0, os.path.expanduser("~/Dev/operator/lib"))
import asc  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP_ID = json.load(open(os.path.join(ROOT, "docs/asc-metadata.json")))["appId"]
BUNDLE_RESOURCE_ID = "Z8A63L9289"
PREFIX = "com.guitaripod.tailscode."

ACHIEVEMENTS = [
    ("turns1", "bubble.left.fill", "First words", 5,
     "Send a first turn", "You sent your first turn."),
    ("turns100", "bubble.left.and.bubble.right.fill", "A hundred turns", 10,
     "Send 100 turns inside one month", "You sent 100 turns in a month."),
    ("turns1000", "text.bubble.fill", "A thousand turns", 25,
     "Send 1,000 turns inside one month", "You sent 1,000 turns in a month."),
    ("turns10000", "envelope.open.fill", "Ten thousand turns", 50,
     "Send 10,000 turns inside one month", "You sent 10,000 turns in a month."),
    ("streak3", "calendar", "Three days running", 10,
     "Work three days in a row", "You worked three days in a row."),
    ("streak7", "calendar.badge.checkmark", "A full week", 25,
     "Work seven days in a row", "You worked a full week without missing a day."),
    ("streak14", "calendar.circle.fill", "A fortnight", 50,
     "Work fourteen days in a row", "You worked a fortnight without missing a day."),
    ("streak30", "flame.fill", "A month unbroken", 100,
     "Work thirty days in a row", "You worked thirty days in a row."),
    ("tokens10m", "textformat.abc", "Ten million tokens", 10,
     "Move 10M tokens inside one month", "You moved ten million tokens in a month."),
    ("tokens100m", "doc.text.fill", "A hundred million tokens", 25,
     "Move 100M tokens inside one month", "You moved a hundred million tokens in a month."),
    ("tokens1b", "crown.fill", "The billion club", 100,
     "Move 1B tokens inside one month", "You moved a billion tokens in a month."),
    ("tools1000", "wrench.and.screwdriver.fill", "A thousand tool calls", 10,
     "Let the agent run 1,000 tools inside one month",
     "The agent ran a thousand tools for you in a month."),
    ("tools10000", "hammer.fill", "Ten thousand tool calls", 25,
     "Let the agent run 10,000 tools inside one month",
     "The agent ran ten thousand tools for you in a month."),
    ("sessions50", "square.stack.3d.up.fill", "Fifty conversations", 10,
     "Hold 50 conversations inside one month", "You held fifty conversations in a month."),
    ("subagent1", "person.2.fill", "Delegator", 10,
     "Send a subagent out to work", "You sent your first subagent out to work."),
    ("subagent250", "person.3.sequence.fill", "Fleet commander", 50,
     "Send 250 subagents out inside one month", "You sent 250 subagents out in a month."),
    ("compaction1", "arrow.down.right.and.arrow.up.left", "The long haul", 10,
     "Work a conversation long enough to compact it",
     "You worked a conversation long enough to compact it."),
    ("cache100", "banknote.fill", "Cache money", 25,
     "Let caching save $100 inside one month", "Caching kept $100 in your pocket in a month."),
    ("cache1000", "building.columns.fill", "A thousand saved", 50,
     "Let caching save $1,000 inside one month",
     "Caching kept $1,000 in your pocket in a month."),
    ("machines2", "server.rack", "A second machine", 25,
     "Put two machines to work in the same month",
     "You put two machines to work in the same month."),
    ("projects5", "folder.fill", "Five projects", 10,
     "Work five projects inside one month", "You worked five projects in a month."),
    ("models3", "cpu.fill", "Three models", 10,
     "Put three models to work inside one month",
     "You put three models to work in a month."),
    ("night50", "moon.stars.fill", "Night shift", 25,
     "Start 50 turns between midnight and five",
     "You started fifty turns between midnight and five."),
    ("clock24", "clock.fill", "Round the clock", 50,
     "Start a turn in every hour of the day", "You started a turn in every hour of the day."),
    ("longturn10", "hourglass", "The ten-minute turn", 25,
     "Keep the agent out on one turn for ten minutes",
     "You kept the agent out on one turn for ten minutes."),
    ("day100", "sun.max.fill", "The hundred-dollar day", 50,
     "Put $100 of work through one day", "You put $100 of work through a single day."),
    ("weekend100", "sofa.fill", "Weekender", 25,
     "Send 100 turns on Saturdays and Sundays",
     "You sent a hundred weekend turns."),
]

LEADERBOARDS = [
    ("board.streak", "flame.fill", "Longest streak", "days worked in a row"),
    ("board.turns30", "text.bubble.fill", "Turns in 30 days", "turns sent inside one month"),
    ("board.tokens30", "doc.text.fill", "Tokens in 30 days", "tokens moved inside one month"),
    ("board.tools30", "hammer.fill", "Tool calls in 30 days",
     "tool calls run inside one month"),
]


def ensure_capability():
    caps = asc.get(f"/v1/bundleIds/{BUNDLE_RESOURCE_ID}/bundleIdCapabilities").get("data", [])
    if any(c["attributes"].get("capabilityType") == "GAME_CENTER" for c in caps):
        print("capability: GAME_CENTER already on")
        return
    asc.post("/v1/bundleIdCapabilities", {"data": {
        "type": "bundleIdCapabilities",
        "attributes": {"capabilityType": "GAME_CENTER"},
        "relationships": {"bundleId": {"data": {
            "type": "bundleIds", "id": BUNDLE_RESOURCE_ID}}}}})
    print("capability: GAME_CENTER enabled")


def ensure_detail():
    detail = asc.get(f"/v1/apps/{APP_ID}/gameCenterDetail").get("data")
    if detail:
        print(f"gameCenterDetail: {detail['id']}")
        return detail["id"]
    made = asc.post("/v1/gameCenterDetails", {"data": {
        "type": "gameCenterDetails",
        "relationships": {"app": {"data": {"type": "apps", "id": APP_ID}}}}})
    detail_id = made["data"]["id"]
    print(f"gameCenterDetail: created {detail_id}")
    return detail_id


def existing(detail_id, kind):
    rows = list(asc.paged(f"/v1/gameCenterDetails/{detail_id}/{kind}"))
    return {r["attributes"]["vendorIdentifier"]: r["id"] for r in rows}


def localization_ids(resource, rid):
    rows = asc.get(f"/v1/{resource}/{rid}/localizations").get("data", [])
    return {r["attributes"]["locale"]: r["id"] for r in rows}


def ensure_achievements(detail_id):
    have = existing(detail_id, "gameCenterAchievements")
    ids = {}
    for slug, _, name, points, before, after in ACHIEVEMENTS:
        vendor = PREFIX + slug
        if vendor in have:
            ids[slug] = have[vendor]
        else:
            made = asc.post("/v1/gameCenterAchievements", {"data": {
                "type": "gameCenterAchievements",
                "attributes": {
                    "referenceName": name, "vendorIdentifier": vendor,
                    "points": points, "showBeforeEarned": True, "repeatable": False},
                "relationships": {"gameCenterDetail": {"data": {
                    "type": "gameCenterDetails", "id": detail_id}}}}})
            ids[slug] = made["data"]["id"]
            print(f"achievement: created {vendor}")
        locs = localization_ids("gameCenterAchievements", ids[slug])
        if "en-US" not in locs:
            loc = asc.post("/v1/gameCenterAchievementLocalizations", {"data": {
                "type": "gameCenterAchievementLocalizations",
                "attributes": {
                    "locale": "en-US", "name": name,
                    "beforeEarnedDescription": before, "afterEarnedDescription": after},
                "relationships": {"gameCenterAchievement": {"data": {
                    "type": "gameCenterAchievements", "id": ids[slug]}}}}})
            locs["en-US"] = loc["data"]["id"]
            print(f"achievement: localized {vendor}")
        ids[slug] = (ids[slug], locs["en-US"])
    return ids


def ensure_leaderboards(detail_id):
    have = existing(detail_id, "gameCenterLeaderboards")
    ids = {}
    for slug, _, name, unit in LEADERBOARDS:
        vendor = PREFIX + slug
        if vendor in have:
            ids[slug] = have[vendor]
        else:
            made = asc.post("/v1/gameCenterLeaderboards", {"data": {
                "type": "gameCenterLeaderboards",
                "attributes": {
                    "defaultFormatter": "INTEGER", "referenceName": name,
                    "vendorIdentifier": vendor, "scoreSortType": "DESC",
                    "submissionType": "BEST_SCORE"},
                "relationships": {"gameCenterDetail": {"data": {
                    "type": "gameCenterDetails", "id": detail_id}}}}})
            ids[slug] = made["data"]["id"]
            print(f"leaderboard: created {vendor}")
        locs = localization_ids("gameCenterLeaderboards", ids[slug])
        if "en-US" not in locs:
            loc = asc.post("/v1/gameCenterLeaderboardLocalizations", {"data": {
                "type": "gameCenterLeaderboardLocalizations",
                "attributes": {
                    "locale": "en-US", "name": name, "formatterOverride": "INTEGER",
                    "formatterSuffix": None, "formatterSuffixSingular": None},
                "relationships": {"gameCenterLeaderboard": {"data": {
                    "type": "gameCenterLeaderboards", "id": ids[slug]}}}}})
            locs["en-US"] = loc["data"]["id"]
            print(f"leaderboard: localized {vendor}")
        ids[slug] = (ids[slug], locs["en-US"])
    return ids


def render_icons(out_dir):
    catalog = [{"slug": s, "symbol": sym} for s, sym, *_ in ACHIEVEMENTS]
    catalog += [{"slug": s, "symbol": sym} for s, sym, *_ in LEADERBOARDS]
    spec_path = "/tmp/gc-catalog.json"
    json.dump(catalog, open(spec_path, "w"))
    subprocess.run(
        ["swift", os.path.join(ROOT, "scripts/render-gc-icons.swift"), spec_path, out_dir],
        check=True)


def upload_image(kind, loc_type, loc_rel, loc_id, path):
    data = open(path, "rb").read()
    reserve = asc.post(f"/v1/{kind}", {"data": {
        "type": kind,
        "attributes": {"fileName": os.path.basename(path), "fileSize": len(data)},
        "relationships": {loc_rel: {"data": {"type": loc_type, "id": loc_id}}}}})
    image_id = reserve["data"]["id"]
    for op in reserve["data"]["attributes"]["uploadOperations"]:
        headers = {h["name"]: h["value"] for h in op.get("requestHeaders", [])}
        chunk = data[op["offset"]:op["offset"] + op["length"]]
        requests.request(
            op["method"], op["url"], headers=headers, data=chunk,
            timeout=120).raise_for_status()
    asc.patch(f"/v1/{kind}/{image_id}", {"data": {
        "type": kind, "id": image_id, "attributes": {"uploaded": True}}})
    return image_id


def push_images(achievements, leaderboards):
    out_dir = os.path.join(ROOT, "marketing/gamecenter")
    os.makedirs(out_dir, exist_ok=True)
    render_icons(out_dir)
    for slug, (_, loc_id) in achievements.items():
        ensure_image(
            "gameCenterAchievementImages", "gameCenterAchievementLocalizations",
            "gameCenterAchievementLocalization", "gameCenterAchievementImage",
            loc_id, os.path.join(out_dir, f"{slug}.png"), slug)
    for slug, (_, loc_id) in leaderboards.items():
        ensure_image(
            "gameCenterLeaderboardImages", "gameCenterLeaderboardLocalizations",
            "gameCenterLeaderboardLocalization", "gameCenterLeaderboardImage",
            loc_id, os.path.join(out_dir, f"{slug}.png"), slug)


def ensure_image(kind, loc_type, loc_rel, include_key, loc_id, path, slug):
    loc = asc.get(f"/v1/{loc_type}/{loc_id}", **{"include": include_key})
    for image in loc.get("included", []):
        state = (image["attributes"].get("assetDeliveryState") or {}).get("state")
        if state in ("COMPLETE", "UPLOAD_COMPLETE"):
            return
        asc.delete(f"/v1/{kind}/{image['id']}")
        print(f"image: discarded stale {slug} ({state})")
    upload_image(kind, loc_type, loc_rel, loc_id, path)
    print(f"image: uploaded {slug}")


def main():
    total = sum(points for _, _, _, points, _, _ in ACHIEVEMENTS)
    assert total <= 1000, f"achievement points {total} exceed Game Center's 1000 budget"
    ensure_capability()
    detail_id = ensure_detail()
    achievements = ensure_achievements(detail_id)
    leaderboards = ensure_leaderboards(detail_id)
    if "--images" in sys.argv:
        push_images(achievements, leaderboards)
    print(f"OK: {len(achievements)} achievements ({total} points), "
          f"{len(leaderboards)} leaderboards")


if __name__ == "__main__":
    main()
