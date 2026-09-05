#!/usr/bin/env python3
"""Set TestFlight's "What to Test" for one build of Tailscode.

App Store Connect keeps tester-facing notes on a build's betaBuildLocalization,
which does not exist until the build finishes processing — so this polls for the
build, then creates or patches the en-US localization.

Usage: python3 scripts/asc-whats-to-test.py <build-number> <notes-file>
       python3 scripts/asc-whats-to-test.py 131 notes.txt --platform=macos   # the Mac train

The two trains number independently and usually share a build number, so the
train is named rather than guessed: without it the newest 131 could be the
other platform's.
"""
import os
import sys
import time

sys.path.insert(0, os.path.expanduser("~/Dev/operator/lib"))
import asc  # noqa: E402

APP = "6791660932"
LOCALE = "en-US"
PLATFORM = "MAC_OS" if "--platform=macos" in sys.argv else "IOS"


def find_build(number: str, tries: int = 60, delay: int = 30) -> str:
    for attempt in range(tries):
        builds = asc.get(
            "/v1/builds",
            **{
                "filter[app]": APP,
                "filter[version]": number,
                "filter[preReleaseVersion.platform]": PLATFORM,
                "limit": "1",
                "sort": "-uploadedDate",
            },
        ).get("data", [])
        if builds:
            state = builds[0]["attributes"].get("processingState")
            print(f"build {number}: {state}")
            if state != "PROCESSING":
                return builds[0]["id"]
        else:
            print(f"build {number}: not visible yet ({attempt + 1}/{tries})")
        time.sleep(delay)
    raise SystemExit(f"build {number} never appeared or never finished processing")


def set_notes(build_id: str, notes: str) -> None:
    existing = asc.get(f"/v1/builds/{build_id}/betaBuildLocalizations").get("data", [])
    mine = next((row for row in existing if row["attributes"]["locale"] == LOCALE), None)
    if mine:
        asc.patch(
            f"/v1/betaBuildLocalizations/{mine['id']}",
            {
                "data": {
                    "type": "betaBuildLocalizations",
                    "id": mine["id"],
                    "attributes": {"whatsNew": notes},
                }
            },
        )
        print(f"patched betaBuildLocalizations/{mine['id']}")
        return
    created = asc.post(
        "/v1/betaBuildLocalizations",
        {
            "data": {
                "type": "betaBuildLocalizations",
                "attributes": {"locale": LOCALE, "whatsNew": notes},
                "relationships": {
                    "build": {"data": {"type": "builds", "id": build_id}}
                },
            }
        },
    )
    print(f"created betaBuildLocalizations/{created['data']['id']}")


def main() -> None:
    args = [arg for arg in sys.argv[1:] if not arg.startswith("--")]
    if len(args) != 2:
        raise SystemExit(__doc__)
    number, path = args
    notes = open(path).read().strip()
    if len(notes) > 4000:
        raise SystemExit(f"notes are {len(notes)} chars; ASC caps whatsNew at 4000")
    build_id = find_build(number)
    set_notes(build_id, notes)
    print(f"https://appstoreconnect.apple.com/apps/{APP}/testflight/{'macos' if PLATFORM == 'MAC_OS' else 'ios'}")


if __name__ == "__main__":
    main()
