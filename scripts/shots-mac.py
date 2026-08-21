#!/usr/bin/env python3
"""Rebuild the Mac App Store screenshot set from the demo world.

Every shot is one clean launch of the **store** target — `TailscodeMacStore`, the sandboxed
build the App Store hands out — because a screenshot is a promise and the direct build makes
promises this one cannot keep (the terminal pane, the tailnet scan, the video slot). The store
target is built here, cloned to a scratch bundle id so it gets a container of its own, and run
with `--demo`: no tailnet, no real servers, nobody's own conversations in the marketing set.

The window is framed at exactly 1440x900pt, which is 2880x1800px on a 2x display — the size
App Store Connect wants for `APP_DESKTOP`. It is captured window-by-window with
`screencapture -o -l`, which drops the shadow and never depends on what happens to be on the
desktop behind it; the panels a shot opens are composited back over the main window at their
real offsets, and the result is flattened onto the app's own canvas colour so the rounded
corners read as full bleed rather than as a border.

  scripts/shots-mac.py                 # every shot
  scripts/shots-mac.py 03-git          # one
  scripts/shots-mac.py --no-build      # reuse the last build
  scripts/shots-mac.py --no-stage      # reuse the staged copy under /tmp as well
"""
import hashlib
import json
import os
import shutil
import subprocess
import sys
import time

import AppKit
import Quartz

ROOT = os.environ.get("TAILSCODE_ROOT",
                      os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.environ.get("TAILSCODE_SHOTS_OUT", os.path.join(ROOT, "Resources/Screenshots/mac"))
DERIVED = os.path.join(ROOT, "build-macstore-shots")
STAGE = "/tmp/tailscode-macshots"
BUNDLE = "com.guitaripod.tailscode.shots"
CONTAINER = os.path.expanduser(f"~/Library/Containers/{BUNDLE}/Data")
WIDTH, HEIGHT = 1440, 900
BED = "#0d1014"

PANE_A = "AAAAAAAA-0000-4000-8000-000000000001"
PANE_B = "BBBBBBBB-0000-4000-8000-000000000002"
SPLIT_ID = "CCCCCCCC-0000-4000-8000-000000000003"

# The tiling arrangement a launch restores, written the way the app itself writes it. A split
# cannot be performed from outside: the Mac's sidebar collapses a split whenever it opens a chat,
# and the pane chooser is the one surface in this build still offering a slot the sandbox has no
# player for. So the shot restores a layout — and is taken before the first full listing lands,
# because that listing's auto-open is the thing that collapses it.
SPLIT_SEED = {
    "layout": {
        "root": {"split": {
            "axis": "horizontal", "ratio": 0.5, "id": SPLIT_ID,
            "first": {"pane": {"_0": PANE_A}},
            "second": {"pane": {"_0": PANE_B}}}},
        "focusedPane": PANE_A,
        "focusHistory": [PANE_B, PANE_A],
    },
    "sessions": {
        PANE_A: {"profileID": "demo-claude", "sessionID": "demo-c2"},
        PANE_B: {"profileID": "demo-opencode", "sessionID": "demo-o1"},
    },
    "videos": {}, "pages": {},
}

# The appearance a marketing set is shot in, written for every shot rather than inherited. Without
# it the app follows the Mac's own light/dark setting and the six pictures come out however the
# machine happened to be that afternoon — which is how a set ends up half light and half dark.
BASE_SEED = {"tailscode.appearance": "dark"}

# A drive step is ("click", (x, y)) in window points, ("scroll", (x, y, lines)),
# ("key", "<System Events phrase>"), ("wait", seconds), or ("panel", (title-prefix, w, h)) to
# resize a floating window — a panel larger than the 1440x900 bed is composited clipped.
SHOTS = [
    {
        "name": "01-conversation",
        "env": {},
        "args": ["--demo"],
        "settle": 16,
        "drive": [
            ("click", (122, 317)),
            ("wait", 5),
            ("click", (267, 271)),
            ("wait", 2),
            ("click", (283, 346)),
            ("wait", 2),
            ("click", (283, 305)),
            ("wait", 2),
            ("scroll", (900, 400, 30)),
            ("wait", 2),
        ],
    },
    {
        "name": "02-split",
        "env": {"TAILSCODE_OPEN_SESSION": "demo-c2"},
        "args": ["--demo"],
        "settle": 16,
        "drive": [
            ("key", 'click menu item "Split Right" of menu "View" of menu bar item "View" of menu bar 1'),
            ("wait", 3),
            ("click", (1195, 445)),
            ("wait", 3),
            ("click", (1190, 383)),
            ("wait", 6),
        ],
    },
    {
        "name": "03-git",
        "env": {"TAILSCODE_OPEN_SESSION": "demo-c1"},
        "args": ["--demo", "--open", "git"],
        "settle": 16,
        "drive": [],
    },
    {
        "name": "04-analytics",
        "env": {},
        "args": ["--demo", "--open", "analytics"],
        "settle": 26,
        "drive": [("panel", ("The month in numbers", 760, 760))],
    },
    {
        "name": "05-spend",
        "env": {"TAILSCODE_OPEN_SESSION": "demo-c2"},
        "args": ["--demo", "--open", "spend"],
        "settle": 16,
        "drive": [],
    },
    {
        "name": "06-quickask",
        "env": {},
        "args": ["--demo", "--open", "quickask"],
        "settle": 14,
        "drive": [],
    },
]


def run(cmd, **kw):
    return subprocess.run(cmd, check=True, capture_output=True, text=True, **kw)


def build():
    run(["xcodegen", "generate"], cwd=ROOT)
    log = "/tmp/tailscode-macshots-build.log"
    with open(log, "w") as handle:
        code = subprocess.call(
            ["xcodebuild", "-project", "Tailscode.xcodeproj", "-scheme", "TailscodeMacStore",
             "-configuration", "Release", "-derivedDataPath", DERIVED, "build"],
            cwd=ROOT, stdout=handle, stderr=subprocess.STDOUT)
    if code != 0:
        subprocess.call(["grep", "-E", "error:|BUILD FAILED", log])
        sys.exit(f"build failed — {log}")


def stage():
    """A copy of the store app under a bundle id of its own.

    The shipping id would inherit this Mac's real profiles and its real conversations through
    the container macOS migrates on first sandboxed launch, and would write the demo flag back
    into the developer's own defaults. A scratch id gets an empty container instead."""
    app = os.path.join(STAGE, "Tailscode.app")
    if "--no-stage" in sys.argv:
        if not os.path.isdir(app):
            sys.exit(f"nothing staged at {app} — drop --no-stage")
        return app
    source = os.path.join(DERIVED, "Build/Products/Release/Tailscode.app")
    if not os.path.isdir(source):
        sys.exit(f"no built app at {source} — drop --no-build")
    shutil.rmtree(STAGE, ignore_errors=True)
    os.makedirs(STAGE)
    run(["cp", "-R", source, app])
    run(["/usr/libexec/PlistBuddy", "-c", f"Set :CFBundleIdentifier {BUNDLE}",
         os.path.join(app, "Contents/Info.plist")])
    run(["codesign", "--force", "--sign", "-", "--entitlements",
         os.path.join(ROOT, "TailscodeMac/TailscodeMac-Store.entitlements"), app])
    return app


def kill_app():
    """Every staged copy, not only this run's — a leftover window would be composited into the
    picture and would swallow the clicks meant for the one being shot."""
    subprocess.call(["pkill", "-f", "/tmp/tailscode-macshots"])
    for _ in range(10):
        time.sleep(0.5)
        if not windows():
            return
    sys.exit("a Tailscode window outlived its process")


def wipe_state():
    for leaf in ("Library/Preferences", "Library/Application Support", "Documents"):
        shutil.rmtree(os.path.join(CONTAINER, leaf), ignore_errors=True)


def seed(defaults):
    """Preferences written where a sandboxed app will actually read them.

    `defaults write <domain>` puts the value in `~/Library/Preferences`, which a container never
    reads, so the plist inside the container is written directly and the preferences daemon is
    restarted so it does not serve the copy it had already cached."""
    if not defaults:
        return
    folder = os.path.join(CONTAINER, "Library/Preferences")
    os.makedirs(folder, exist_ok=True)
    path = os.path.join(folder, f"{BUNDLE}.plist")
    if not os.path.exists(path):
        run(["plutil", "-create", "xml1", path])
    for key, value in defaults.items():
        subprocess.call(["/usr/libexec/PlistBuddy", "-c", f"Delete :{key}", path],
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        run(["/usr/libexec/PlistBuddy", "-c", f"Add :{key} string {value}", path])
    subprocess.call(["killall", "-u", os.environ.get("USER", ""), "cfprefsd"],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(1)


def windows():
    listed = Quartz.CGWindowListCopyWindowInfo(
        Quartz.kCGWindowListOptionOnScreenOnly | Quartz.kCGWindowListExcludeDesktopElements,
        Quartz.kCGNullWindowID)
    found = []
    for entry in listed:
        if str(entry.get("kCGWindowOwnerName", "")) != "Tailscode":
            continue
        if int(entry.get("kCGWindowLayer", 0)) not in (0, 3, 8, 25):
            continue
        bounds = entry["kCGWindowBounds"]
        found.append({
            "id": int(entry["kCGWindowNumber"]),
            "name": str(entry.get("kCGWindowName") or ""),
            "x": int(bounds["X"]), "y": int(bounds["Y"]),
            "w": int(bounds["Width"]), "h": int(bounds["Height"]),
        })
    return found


def idle_seconds():
    probe = subprocess.run(["ioreg", "-c", "IOHIDSystem"], capture_output=True, text=True).stdout
    for line in probe.splitlines():
        if "HIDIdleTime" in line:
            return int(line.rsplit("=", 1)[1].strip()) / 1e9
    return 999.0


LAST_SYNTHETIC = [0.0]


def wait_for_quiet(seconds=4.0, timeout=300.0):
    """A shot is driven by synthetic clicks into the frontmost app, so a person still typing at
    this Mac types into the picture. Wait for the keyboard to be still before taking it."""
    started = time.time()
    while time.time() - started < timeout:
        if idle_seconds() >= seconds:
            return
        time.sleep(1)
    print("  (took the shot without a quiet keyboard)")


def someone_else_typed():
    """True when the keyboard or the pointer moved on its own since the last event this script
    posted — which is the one thing that can put a stray character into a screenshot."""
    return idle_seconds() < (time.time() - LAST_SYNTHETIC[0]) - 1.0


def osa(script):
    subprocess.call(["osascript", "-e", script], stderr=subprocess.DEVNULL)


def activate():
    """Frontmost *and* key — a window merely in front still draws grey traffic lights."""
    for app in AppKit.NSRunningApplication.runningApplicationsWithBundleIdentifier_(BUNDLE):
        app.activateWithOptions_(AppKit.NSApplicationActivateIgnoringOtherApps)


def scroll(x, y, lines):
    """A wheel over a point, because the transcript settles where it likes after rows grow."""
    move = Quartz.CGEventCreateMouseEvent(
        None, Quartz.kCGEventMouseMoved, (x, y + 38), Quartz.kCGMouseButtonLeft)
    Quartz.CGEventPost(Quartz.kCGHIDEventTap, move)
    time.sleep(0.2)
    for _ in range(abs(lines)):
        event = Quartz.CGEventCreateScrollWheelEvent(
            None, Quartz.kCGScrollEventUnitLine, 1, 3 if lines > 0 else -3)
        Quartz.CGEventPost(Quartz.kCGHIDEventTap, event)
        time.sleep(0.03)
    LAST_SYNTHETIC[0] = time.time()


def click(x, y):
    """A real press at a window-relative point, which is how a row is opened and a row expanded."""
    down = Quartz.CGEventCreateMouseEvent(
        None, Quartz.kCGEventLeftMouseDown, (x, y + 38), Quartz.kCGMouseButtonLeft)
    up = Quartz.CGEventCreateMouseEvent(
        None, Quartz.kCGEventLeftMouseUp, (x, y + 38), Quartz.kCGMouseButtonLeft)
    Quartz.CGEventPost(Quartz.kCGHIDEventTap, down)
    time.sleep(0.12)
    Quartz.CGEventPost(Quartz.kCGHIDEventTap, up)
    LAST_SYNTHETIC[0] = time.time()


def main_window():
    """The hub, which is the app's first window — every panel opens after it, and window numbers
    only climb."""
    found = windows()
    return min(found, key=lambda w: w["id"]) if found else None


def frame_main():
    """1440x900pt on the main display, retried because the split layout and the panels all re-lay
    the window out well after it first appears.

    The hub is picked by window id — the app's first window, and window numbers only climb — and
    then named to System Events, because area is not identity: a panel that opens larger than a
    half-empty hub used to be the one that got resized, and the shot came out framing the wrong
    window entirely.
    """
    for _ in range(10):
        hub = main_window()
        if not hub:
            time.sleep(1.2)
            continue
        if (hub["w"], hub["h"]) == (WIDTH, HEIGHT) and hub["x"] == 0 and abs(hub["y"] - 38) <= 2:
            return hub
        target = hub["name"].replace("\\", "\\\\").replace('"', '\\"')
        if target:
            script = f'''
                tell application "System Events" to tell process "Tailscode"
                    repeat with w in windows
                        if name of w starts with "{target}" then
                            set position of w to {{0, 38}}
                            set size of w to {{{WIDTH}, {HEIGHT}}}
                        end if
                    end repeat
                end tell'''
        else:
            script = f'''
                tell application "System Events" to tell process "Tailscode"
                    if (count of windows) > 0 then
                        set position of window 1 to {{0, 38}}
                        set size of window 1 to {{{WIDTH}, {HEIGHT}}}
                    end if
                end tell'''
        osa(script)
        time.sleep(1.2)
    sys.exit("could not frame the window at 1440x900")


def capture(shot, main):
    """Every visible window of the app, drawn back where it really sits over the main one."""
    stack = [w for w in windows() if w["id"] != main["id"]]
    layers = []
    for window in [main] + list(reversed(stack)):
        path = f"/tmp/tailscode-shot-{window['id']}.png"
        subprocess.call(["screencapture", "-x", "-o", "-l", str(window["id"]), path])
        if os.path.exists(path):
            layers.append((path, window["x"] - main["x"], window["y"] - main["y"]))
    out = os.path.join(OUT, f"{shot['name']}.png")
    cmd = ["magick", "-size", f"{WIDTH * 2}x{HEIGHT * 2}", f"xc:{BED}"]
    for path, dx, dy in layers:
        cmd += [path, "-geometry", f"+{dx * 2}+{dy * 2}", "-composite"]
    cmd += ["-alpha", "remove", "-alpha", "off", "-colorspace", "sRGB",
            "-depth", "8", "-strip", "PNG24:" + out]
    run(cmd)
    return out


def verify(path):
    probe = run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", "-g", "hasAlpha", path]).stdout
    facts = dict(line.strip().split(": ", 1) for line in probe.splitlines() if ": " in line)
    width, height = int(facts["pixelWidth"]), int(facts["pixelHeight"])
    if (width, height) != (WIDTH * 2, HEIGHT * 2):
        sys.exit(f"{path} is {width}x{height}, not {WIDTH * 2}x{HEIGHT * 2}")
    if facts.get("hasAlpha") != "no":
        sys.exit(f"{path} still carries an alpha channel")
    digest = hashlib.md5(open(path, "rb").read()).hexdigest()
    print(f"  {os.path.basename(path)}  {width}x{height}  md5 {digest}")


def shoot(app, shot):
    kill_app()
    wipe_state()
    seed(dict(BASE_SEED, **shot.get("seed", {})))
    environment = dict(os.environ, **shot["env"])
    subprocess.Popen([os.path.join(app, "Contents/MacOS/Tailscode")] + shot["args"],
                     env=environment, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(shot["settle"])
    if shot["drive"]:
        wait_for_quiet()
    main = frame_main()
    activate()
    LAST_SYNTHETIC[0] = time.time()
    time.sleep(1.5)
    for kind, value in shot["drive"]:
        if kind == "wait":
            time.sleep(value)
        elif kind == "click":
            click(*value)
            time.sleep(0.8)
        elif kind == "scroll":
            scroll(*value)
            time.sleep(0.8)
        elif kind == "panel":
            title, width, height = value
            osa(f'''
                tell application "System Events" to tell process "Tailscode"
                    repeat with w in windows
                        if name of w starts with "{title}" then
                            set size of w to {{{width}, {height}}}
                        end if
                    end repeat
                end tell''')
            time.sleep(1.0)
        else:
            osa(f'tell application "System Events" to tell process "Tailscode" to {value}')
            LAST_SYNTHETIC[0] = time.time()
            time.sleep(0.6)
    main = frame_main()
    activate()
    time.sleep(1.5)
    if shot["drive"] and someone_else_typed():
        kill_app()
        return False
    path = capture(shot, main)
    verify(path)
    kill_app()
    return True


def main():
    wanted = [a for a in sys.argv[1:] if not a.startswith("--")]
    if "--no-build" not in sys.argv:
        build()
    app = stage()
    os.makedirs(OUT, exist_ok=True)
    for shot in SHOTS:
        if wanted and shot["name"] not in wanted:
            continue
        print(shot["name"])
        for _ in range(5):
            if shoot(app, shot):
                break
            print("  someone was using this Mac — taking it again")
        else:
            sys.exit(f"{shot['name']} could never be taken uninterrupted")


if __name__ == "__main__":
    main()
