#!/usr/bin/env python3
"""Put an uploaded build into App Store review.

buildvm only hands Apple the binary. This is the rest of it, and it is
idempotent at every step: reuse or create the version record, write the release
notes every locale already carries, attach the build once it is VALID, then
submit — reusing an open review submission rather than making a second one,
which ASC refuses.

Every step is also checked rather than assumed: notes are read back after they
are written, the build is read back after it is attached, a version carrying a
Game Center build declares Game Center before it is offered for review, and a
version still reading PREPARE_FOR_SUBMISSION at the end is a failure however
cleanly the calls returned.

Usage: python3 scripts/asc-release.py <marketing-version> <build-number>
       python3 scripts/asc-release.py 1.9 25 --no-submit
       python3 scripts/asc-release.py 1.26 119 --platform=macos   # the Mac train, notes from "<version>-macos"
"""
import json
import os
import sys
import time
from typing import NoReturn

sys.path.insert(0, os.path.expanduser("~/Dev/operator/lib"))
import asc  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP = "6791660932"
PLATFORM = "MAC_OS" if "--platform=macos" in sys.argv else "IOS"


def die(message: str) -> NoReturn:
    print(message, file=sys.stderr)
    sys.exit(1)


def version_record(marketing: str) -> dict:
    for row in asc.get(
        f"/v1/apps/{APP}/appStoreVersions", **{"limit": "50", "filter[platform]": PLATFORM}
    ).get("data", []):
        if row["attributes"]["versionString"] == marketing:
            print(f"version {marketing} exists ({row['attributes']['appStoreState']})")
            return row
    created = asc.post(
        "/v1/appStoreVersions",
        {
            "data": {
                "type": "appStoreVersions",
                "attributes": {
                    "platform": PLATFORM,
                    "versionString": marketing,
                    "releaseType": "MANUAL",
                },
                "relationships": {"app": {"data": {"type": "apps", "id": APP}}},
            }
        },
    )["data"]
    print(f"version {marketing} created")
    return created


def write_notes(version_id: str, marketing: str) -> None:
    """Every locale ends up carrying this version's own words, and the ones it
    got are read back rather than assumed.

    A missing entry is fatal instead of a shrug: 1.5 through 1.9 all shipped
    wearing the 1.5 notes, because leaving the localizations alone looks exactly
    like writing them when nobody checks. A locale the file does not cover falls
    back to en-US and says so, which is a translation debt worth seeing."""
    book = json.load(open(os.path.join(ROOT, "docs/release-notes.json")))
    notes = (book.get(f"{marketing}-macos") if PLATFORM == "MAC_OS" else None) or book.get(marketing)
    if not notes:
        die(f"docs/release-notes.json has no entry for {marketing} — write the notes first")
    rows = asc.get(
        f"/v1/appStoreVersions/{version_id}/appStoreVersionLocalizations",
        **{"limit": "50"},
    ).get("data", [])
    if not rows:
        die(f"version {marketing} carries no localizations to write notes into")
    wanted = {}
    for row in rows:
        locale = row["attributes"]["locale"]
        text = notes.get(locale)
        if text is None:
            text = notes.get("en-US")
            if text is None:
                die(f"no notes for {locale} and no en-US to fall back to")
            print(f"  {locale} falls back to en-US")
        wanted[locale] = text
        if row["attributes"].get("whatsNew") == text:
            print(f"  notes {locale} already current")
            continue
        asc.patch(
            f"/v1/appStoreVersionLocalizations/{row['id']}",
            {
                "data": {
                    "type": "appStoreVersionLocalizations",
                    "id": row["id"],
                    "attributes": {"whatsNew": text},
                }
            },
        )
        print(f"  notes {locale} ({len(text)} chars)")
    unwritten = [
        row["attributes"]["locale"]
        for row in asc.get(
            f"/v1/appStoreVersions/{version_id}/appStoreVersionLocalizations",
            **{"limit": "50"},
        ).get("data", [])
        if row["attributes"].get("whatsNew") != wanted.get(row["attributes"]["locale"])
    ]
    if unwritten:
        die(f"notes did not stick for {', '.join(unwritten)}")
    extra = sorted(set(notes) - set(wanted))
    if extra:
        print(f"  notes on file for locales this version has not got: {', '.join(extra)}")


def ensure_game_center(version_id: str) -> None:
    """A build signed with the Game Center entitlement cannot be reviewed until
    the version it rides in declares Game Center too, and the version record
    does not inherit it — the submission fails with
    STATE_ERROR.BUILD_INDICATES_GAME_CENTER_ENABLED, naming the build rather than
    the missing declaration. Create the link and enable it; `enabled` is refused
    on the create and has to be a second call."""
    try:
        detail = asc.get(f"/v1/apps/{APP}/gameCenterDetail").get("data")
    except Exception:
        detail = None
    if not detail:
        return
    existing = asc.get(f"/v1/appStoreVersions/{version_id}/gameCenterAppVersion").get("data")
    if existing and existing["attributes"].get("enabled"):
        print("game center already declared for this version")
        return
    row = existing or asc.post(
        "/v1/gameCenterAppVersions",
        {
            "data": {
                "type": "gameCenterAppVersions",
                "relationships": {
                    "appStoreVersion": {
                        "data": {"type": "appStoreVersions", "id": version_id}
                    }
                },
            }
        },
    )["data"]
    if not row["attributes"].get("enabled"):
        asc.patch(
            f"/v1/gameCenterAppVersions/{row['id']}",
            {
                "data": {
                    "type": "gameCenterAppVersions",
                    "id": row["id"],
                    "attributes": {"enabled": True},
                }
            },
        )
    print("game center declared for this version")


def wait_for_build(number: str) -> dict:
    """A build is attachable only once processing says VALID, which lags the
    upload by minutes. Poll rather than guess."""
    for attempt in range(60):
        for row in asc.get(
            "/v1/builds",
            **{"filter[app]": APP, "filter[preReleaseVersion.platform]": PLATFORM,
               "limit": "20", "sort": "-uploadedDate"},
        ).get("data", []):
            if row["attributes"].get("version") != number:
                continue
            state = row["attributes"].get("processingState")
            if state == "VALID":
                return row
            print(f"  build {number} {state} …")
            break
        else:
            print(f"  build {number} not surfaced yet …")
        time.sleep(30)
    die(f"build {number} never went VALID")


def main() -> None:
    args = [a for a in sys.argv[1:] if not a.startswith("--") ]
    if len(args) != 2:
        die("usage: asc-release.py <marketing-version> <build-number>")
    marketing, number = args
    submit = "--no-submit" not in sys.argv

    version = version_record(marketing)
    version_id = version["id"]
    write_notes(version_id, marketing)

    build = wait_for_build(number)
    asc.patch(
        f"/v1/appStoreVersions/{version_id}/relationships/build",
        {"data": {"type": "builds", "id": build["id"]}},
    )
    attached = asc.get(f"/v1/appStoreVersions/{version_id}/build").get("data")
    if not attached or attached["id"] != build["id"]:
        die(f"build {number} did not attach to {marketing}")
    print(f"build {number} attached to {marketing}")

    ensure_game_center(version_id)

    if not submit:
        return

    open_submission = None
    for row in asc.get(
        f"/v1/apps/{APP}/reviewSubmissions", **{"limit": "10"}
    ).get("data", []):
        if row["attributes"].get("state") in {"READY_FOR_REVIEW", "WAITING_FOR_REVIEW", "IN_REVIEW"}:
            open_submission = row
            break
    if open_submission and open_submission["attributes"]["state"] != "READY_FOR_REVIEW":
        print(f"already {open_submission['attributes']['state']} — nothing to submit")
        return
    submission = open_submission or asc.post(
        "/v1/reviewSubmissions",
        {
            "data": {
                "type": "reviewSubmissions",
                "attributes": {"platform": PLATFORM},
                "relationships": {"app": {"data": {"type": "apps", "id": APP}}},
            }
        },
    )["data"]

    items = asc.get(
        f"/v1/reviewSubmissions/{submission['id']}/items", **{"limit": "10"}
    ).get("data", [])
    if not items:
        asc.post(
            "/v1/reviewSubmissionItems",
            {
                "data": {
                    "type": "reviewSubmissionItems",
                    "relationships": {
                        "reviewSubmission": {
                            "data": {"type": "reviewSubmissions", "id": submission["id"]}
                        },
                        "appStoreVersion": {
                            "data": {"type": "appStoreVersions", "id": version_id}
                        },
                    },
                }
            },
        )
        print("version added to the submission")

    asc.patch(
        f"/v1/reviewSubmissions/{submission['id']}",
        {
            "data": {
                "type": "reviewSubmissions",
                "id": submission["id"],
                "attributes": {"submitted": True},
            }
        },
    )
    state = asc.get(f"/v1/appStoreVersions/{version_id}").get("data", {}).get(
        "attributes", {}
    ).get("appStoreState")
    if state == "PREPARE_FOR_SUBMISSION":
        die(f"{marketing} still reads PREPARE_FOR_SUBMISSION — nothing was submitted")
    print(f"submitted {marketing} ({number}) for review — {state}")


if __name__ == "__main__":
    main()
