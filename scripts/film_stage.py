"""XTEST plumbing shared by everything that performs for the camera.

A take is not a test: the pointer travels instead of teleporting, keys land on their own rhythm,
and letters arrive at a hand's speed. Both `film-take.py` (one scripted scene) and `film-reel.py`
(the montage reels) drive the app through this, so the app cannot tell any of it from a person.
"""
import random
import time

from Xlib import X, XK, display
from Xlib.ext import xtest

MODIFIERS = {"ctrl": "Control_L", "shift": "Shift_L", "alt": "Alt_L", "super": "Super_L"}


class Stage:
    def __init__(self, verbose=True, seed=11):
        self.dpy = display.Display()
        self.root = self.dpy.screen().root
        self.verbose = verbose
        self.clock = time.monotonic()
        self.random = random.Random(seed)

    def say(self, note):
        if self.verbose:
            print(f"{time.monotonic() - self.clock:7.2f}  {note}", flush=True)

    def hold(self, seconds):
        time.sleep(seconds)

    def pointer(self):
        reply = self.root.query_pointer()
        return reply.root_x, reply.root_y

    def glide(self, x, y, seconds=0.55):
        """A pointer that cuts from one place to another reads as a dropped frame."""
        start = self.pointer()
        steps = max(12, int(seconds * 90))
        for step in range(1, steps + 1):
            fraction = step / steps
            eased = fraction * fraction * (3 - 2 * fraction)
            xtest.fake_input(
                self.dpy,
                X.MotionNotify,
                x=int(start[0] + (x - start[0]) * eased),
                y=int(start[1] + (y - start[1]) * eased),
            )
            self.dpy.sync()
            time.sleep(seconds / steps)

    def click(self, x=None, y=None):
        if x is not None:
            xtest.fake_input(self.dpy, X.MotionNotify, x=x, y=y)
            self.dpy.sync()
            time.sleep(0.08)
        xtest.fake_input(self.dpy, X.ButtonPress, 1)
        self.dpy.sync()
        time.sleep(0.07)
        xtest.fake_input(self.dpy, X.ButtonRelease, 1)
        self.dpy.sync()

    def scroll(self, direction, ticks=3, gap=0.09):
        button = 4 if direction == "up" else 5
        for _ in range(ticks):
            xtest.fake_input(self.dpy, X.ButtonPress, button)
            xtest.fake_input(self.dpy, X.ButtonRelease, button)
            self.dpy.sync()
            time.sleep(gap)

    def keysym(self, name):
        value = XK.string_to_keysym(name)
        if value == 0 and len(name) == 1:
            value = ord(name)
        if value == 0:
            raise SystemExit(f"unknown key: {name}")
        return value

    def tap(self, name, held=()):
        sym = self.keysym(name)
        code = self.dpy.keysym_to_keycode(sym)
        if code == 0:
            raise SystemExit(f"no keycode for: {name}")
        held = list(held)
        if self.dpy.keycode_to_keysym(code, 0) != sym and "Shift_L" not in held:
            held.append("Shift_L")
        for modifier in held:
            xtest.fake_input(self.dpy, X.KeyPress, self.dpy.keysym_to_keycode(self.keysym(modifier)))
        xtest.fake_input(self.dpy, X.KeyPress, code)
        xtest.fake_input(self.dpy, X.KeyRelease, code)
        for modifier in reversed(held):
            xtest.fake_input(
                self.dpy, X.KeyRelease, self.dpy.keysym_to_keycode(self.keysym(modifier))
            )
        self.dpy.sync()

    def chord(self, text):
        parts = text.split("+")
        self.tap(parts[-1], [MODIFIERS[p] for p in parts[:-1]])

    def keys(self, *chords, gap=0.42):
        for text in chords:
            self.chord(text)
            time.sleep(gap)

    def write(self, text, speed=0.055):
        """A hand types unevenly, and rests a beat where the sentence does."""
        for character in text:
            self.tap("space" if character == " " else character)
            pause = speed * self.random.uniform(0.55, 1.6)
            if character in ",.—":
                pause += 0.16
            time.sleep(pause)
