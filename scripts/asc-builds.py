#!/usr/bin/env python3
"""List Tailscode's most recent App Store Connect builds, newest first.

The next build number has to come from what ASC already holds, not from
project.yml: a number that was uploaded once is spent forever, even if that
upload was never submitted.

Usage: python3 scripts/asc-builds.py [limit]
"""
import os
import sys

sys.path.insert(0, os.path.expanduser("~/Dev/operator/lib"))
import asc  # noqa: E402

APP = "6791660932"


def main() -> None:
    limit = sys.argv[1] if len(sys.argv) > 1 else "12"
    rows = asc.get(
        "/v1/builds", **{"filter[app]": APP, "limit": limit, "sort": "-uploadedDate"}
    ).get("data", [])
    for row in rows:
        a = row["attributes"]
        print(
            f"build {a.get('version'):>4}  {a.get('processingState'):<12} "
            f"expired={a.get('expired')}  uploaded={a.get('uploadedDate')}"
        )
    if not rows:
        print("no builds")


if __name__ == "__main__":
    main()
