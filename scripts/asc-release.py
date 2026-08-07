#!/usr/bin/env python3
"""Put an uploaded build into App Store review.

buildvm only hands Apple the binary. This is the rest of it, and it is
idempotent at every step: reuse or create the version record, write the release
notes every locale already carries, attach the build once it is VALID, then
submit — reusing an open review submission rather than making a second one,
which ASC refuses.

Usage: python3 scripts/asc-release.py <marketing-version> <build-number>
       python3 scripts/asc-release.py 1.9 25 --no-submit
"""
import json
import os
import sys
import time

sys.path.insert(0, os.path.expanduser("~/Dev/operator/lib"))
import asc  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP = "6791660932"
PLATFORM = "IOS"


def die(message: str) -> None:
    print(message, file=sys.stderr)
    sys.exit(1)


def version_record(marketing: str) -> dict:
    for row in asc.get(
        f"/v1/apps/{APP}/appStoreVersions", **{"limit": "50"}
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
    notes = json.load(open(os.path.join(ROOT, "docs/release-notes.json"))).get(marketing)
    if not notes:
        print(f"no release notes for {marketing} — leaving localizations alone")
        return
    for row in asc.get(
        f"/v1/appStoreVersions/{version_id}/appStoreVersionLocalizations",
        **{"limit": "50"},
    ).get("data", []):
        locale = row["attributes"]["locale"]
        text = notes.get(locale) or notes.get("en-US")
        if row["attributes"].get("whatsNew") == text:
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
        print(f"  notes {locale}")


def wait_for_build(number: str) -> dict:
    """A build is attachable only once processing says VALID, which lags the
    upload by minutes. Poll rather than guess."""
    for attempt in range(60):
        for row in asc.get(
            "/v1/builds",
            **{"filter[app]": APP, "limit": "20", "sort": "-uploadedDate"},
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
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
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
    print(f"build {number} attached to {marketing}")

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
    print(f"submitted {marketing} ({number}) for review")


if __name__ == "__main__":
    main()
