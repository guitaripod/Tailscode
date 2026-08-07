#!/usr/bin/env python3
"""The reels a montage is cut from: the app doing loud things, back to back.

`film-take.py` performs one continuous scene for a demo. This performs the opposite — short,
unrelated, high-contrast moments with nothing between them, because a beat-synced edit eats
half-second clips and needs a deep pool of them that never repeats. Each reel is recorded to its
own file so the assigner treats them as separate sources and spreads consecutive cuts across them.

    scripts/film-reel.py --list
    scripts/film-reel.py grid          the tiling verbs: split, focus, zoom, exchange, close
    scripts/film-reel.py panes         a page, a stream, the terminal and the file tree in slots
    scripts/film-reel.py chrome        the palette, the cheatsheet, the zoom ramp, slash, new chat
    scripts/film-reel.py stream        one prompt and the answer arriving word by word
"""
import argparse
import sys
import time

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from film_stage import Stage  # noqa: E402

COMPOSER = (2280, 2055)
TRANSCRIPT = (1900, 1100)
FILTER = (390, 153)
LEFT_COMPOSER = (1530, 2035)
RIGHT_COMPOSER = (3050, 2035)


class Reel:
    def __init__(self, stage):
        self.s = stage

    def reset(self):
        """Keys only reach the pane from NORMAL mode with the chat filter empty — a search entry
        that captures the window's keys otherwise swallows every unbound letter."""
        s = self.s
        s.glide(*FILTER, seconds=0.25)
        s.click()
        s.chord("ctrl+a")
        s.tap("BackSpace")
        s.tap("Escape")
        time.sleep(0.3)
        s.glide(*COMPOSER, seconds=0.3)
        s.click()
        time.sleep(0.3)
        s.chord("ctrl+a")
        s.tap("BackSpace")
        s.tap("Escape")
        time.sleep(0.6)

    def split(self, axis, server="Return", pick=None, hold=2.0):
        s = self.s
        s.chord("ctrl+w")
        time.sleep(0.25)
        s.tap("v" if axis == "right" else "s")
        time.sleep(1.3)
        if server:
            s.tap(server)
            time.sleep(1.4)
        if pick:
            s.tap(pick)
            time.sleep(hold)

    def w(self, key, hold=0.9):
        self.s.chord("ctrl+w")
        time.sleep(0.22)
        self.s.tap(key)
        time.sleep(hold)


def grid(s):
    r = Reel(s)
    r.reset()
    s.say("split right, and the empty half asks which server")
    r.split("right", server=None)
    s.keys("Down", gap=0.5)
    s.keys("Down", gap=0.5)
    s.keys("Up", gap=0.55)
    s.tap("Return")
    time.sleep(1.5)
    s.say("a chat it already knows, opened into the new pane")
    s.tap("3")
    time.sleep(2.4)

    s.say("split down, on the other server")
    r.split("down", server="2", pick="2", hold=2.6)

    s.say("walking the panes")
    for key in ("k", "l", "j", "h", "l"):
        r.w(key, hold=0.75)

    s.say("zoom, and back")
    r.w("z", hold=1.6)
    r.w("z", hold=1.2)
    s.say("swap this split with its sibling")
    r.w("x", hold=1.2)
    r.w("x", hold=1.1)

    s.say("a third split, then let it go")
    r.split("right", server=None)
    s.tap("Escape")
    time.sleep(1.0)

    r.w("equal", hold=1.2)
    s.say("closing back down to one")
    r.w("q", hold=1.4)
    r.w("q", hold=1.6)


def panes(s):
    r = Reel(s)
    r.reset()
    s.say("the terminal, filling itself")
    s.chord("ctrl+t")
    time.sleep(1.6)
    s.write("ls -R --color=always /usr/include 2>/dev/null | head -4000", speed=0.03)
    s.tap("Return")
    time.sleep(6.0)
    s.write("git -C ~/Dev/iOS/Tailscode log --oneline --graph --color=always | head -60",
            speed=0.03)
    s.tap("Return")
    time.sleep(4.0)

    s.say("the file tree beside it")
    s.chord("ctrl+e")
    time.sleep(2.2)
    s.scroll("down", ticks=10, gap=0.11)
    time.sleep(0.7)
    s.scroll("up", ticks=10, gap=0.11)
    time.sleep(1.0)

    s.say("a chat splitting into the middle of all three")
    r.split("right", server="Return", pick="4", hold=2.8)
    r.w("z", hold=1.8)
    r.w("z", hold=1.2)
    r.w("h", hold=0.8)

    s.say("the chat list, in and out")
    for _ in range(3):
        s.chord("ctrl+b")
        time.sleep(0.8)

    s.chord("ctrl+e")
    time.sleep(1.0)
    s.chord("ctrl+t")
    time.sleep(1.4)
    r.w("q", hold=1.8)


def chrome(s):
    r = Reel(s)
    r.reset()
    s.say("the command palette")
    s.tap("colon")
    time.sleep(1.4)
    s.write("spl", speed=0.14)
    time.sleep(1.3)
    s.tap("Escape")
    time.sleep(0.9)

    s.say("every shortcut there is")
    s.tap("question")
    time.sleep(2.6)
    s.scroll("down", ticks=6, gap=0.14)
    time.sleep(0.9)
    s.tap("Escape")
    time.sleep(0.9)

    s.say("the chat list, in and out")
    for _ in range(3):
        s.chord("ctrl+b")
        time.sleep(0.85)

    s.say("the whole window growing and shrinking")
    for _ in range(5):
        s.chord("ctrl+equal")
        time.sleep(0.33)
    time.sleep(1.0)
    for _ in range(6):
        s.chord("ctrl+minus")
        time.sleep(0.3)
    time.sleep(0.8)
    s.chord("ctrl+0")
    time.sleep(1.2)

    s.say("a slash, and the server's own catalog answering it")
    s.glide(*COMPOSER, seconds=0.3)
    s.click()
    time.sleep(0.4)
    s.tap("i")
    time.sleep(0.3)
    s.tap("slash")
    time.sleep(1.4)
    s.write("co", speed=0.16)
    time.sleep(1.6)
    s.keys("Down", gap=0.5)
    s.keys("Down", gap=0.6)
    s.tap("Escape")
    time.sleep(0.4)
    s.chord("ctrl+a")
    s.tap("BackSpace")
    s.tap("Escape")
    time.sleep(0.8)

    s.say("a new conversation, and the folders it already knows")
    s.tap("n")
    time.sleep(2.2)
    s.write("tails", speed=0.13)
    time.sleep(1.6)
    s.keys("Down", gap=0.5)
    s.keys("Up", gap=0.6)
    s.tap("Escape")
    time.sleep(1.2)

    s.say("scrolling a long answer")
    s.glide(*TRANSCRIPT, seconds=0.4)
    s.scroll("up", ticks=14, gap=0.07)
    time.sleep(0.7)
    s.scroll("down", ticks=14, gap=0.07)
    time.sleep(1.0)


PROMPT = (
    "In four short lines, say why coding from a phone over Tailscale beats sitting at the desk."
)


def stream(s):
    r = Reel(s)
    r.reset()
    s.say("the prompt")
    s.glide(*COMPOSER, seconds=0.4)
    s.click()
    time.sleep(0.4)
    s.tap("i")
    time.sleep(0.3)
    s.write(PROMPT, speed=0.05)
    time.sleep(1.0)
    s.tap("Return")
    s.say("and the answer, written rather than pasted")
    time.sleep(34.0)
    s.scroll("up", ticks=6, gap=0.1)
    time.sleep(1.2)
    s.scroll("down", ticks=8, gap=0.1)
    time.sleep(22.0)


def tour(s):
    """The three regions at once — the chat, the project it works in, and a shell on the machine.

    Shot separately from `panes` because both of those regions have to be open before the window
    is built: showing a GtkPaned child that was hidden at startup leaves the handle where it was
    clamped, so the pane comes back with no width at all."""
    r = Reel(s)
    r.reset()
    s.say("the project tree the server is serving")
    s.glide(700, 900, 0.4)
    s.scroll("down", ticks=6, gap=0.16)
    time.sleep(1.0)
    s.scroll("up", ticks=6, gap=0.16)
    time.sleep(1.4)

    s.say("a shell on the same machine, under the same conversation")
    s.chord("ctrl+t")
    time.sleep(1.2)
    s.write("git -C ~/Dev/iOS/Tailscode log --oneline --graph --color=always | head -40",
            speed=0.028)
    s.tap("Return")
    time.sleep(4.2)
    s.write("ls -la ~/Dev/iOS/Tailscode/TailscodeLinux/Sources/TailscodeLinux | head -30",
            speed=0.028)
    s.tap("Return")
    time.sleep(4.0)

    s.say("all three, and the chat list folding away to make room")
    s.chord("ctrl+b")
    time.sleep(1.6)
    s.chord("ctrl+b")
    time.sleep(1.8)


REELS = {"grid": grid, "panes": panes, "chrome": chrome, "stream": stream, "tour": tour}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("reel", nargs="?")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--quiet", action="store_true")
    a = ap.parse_args()
    if a.list or not a.reel:
        print("\n".join(REELS))
        return
    if a.reel not in REELS:
        raise SystemExit(f"unknown reel: {a.reel}")
    stage = Stage(verbose=not a.quiet)
    REELS[a.reel](stage)
    stage.say("cut")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(130)
