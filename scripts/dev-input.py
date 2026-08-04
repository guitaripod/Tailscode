#!/usr/bin/env python3
"""Synthesize real pointer and keyboard input on the harness display via XTEST.

Coordinates are screen coordinates, and with no window manager on the harness display the app's
window sits at the origin, so a widget coordinate the app itself reports is a screen coordinate
too. Everything here goes through the X server, so the app cannot tell it from a person.
"""
import sys
import time

from Xlib import X, XK, display
from Xlib.ext import xtest

MODIFIERS = {
    "ctrl": "Control_L",
    "control": "Control_L",
    "shift": "Shift_L",
    "alt": "Alt_L",
    "meta": "Alt_L",
    "super": "Super_L",
    "cmd": "Super_L",
}


class Keyboard:
    def __init__(self, dpy):
        self.dpy = dpy

    def code(self, keysym):
        return self.dpy.keysym_to_keycode(keysym)

    def sym(self, name):
        keysym = XK.string_to_keysym(name)
        if keysym == 0 and len(name) == 1:
            keysym = ord(name)
        if keysym == 0:
            raise SystemExit(f"unknown key: {name}")
        return keysym

    def needs_shift(self, keysym, code):
        return self.dpy.keycode_to_keysym(code, 0) != keysym

    def tap(self, name, held=()):
        keysym = self.sym(name)
        code = self.code(keysym)
        if code == 0:
            raise SystemExit(f"no keycode for: {name}")
        held = list(held)
        if self.needs_shift(keysym, code) and "Shift_L" not in held:
            held.append("Shift_L")
        for modifier in held:
            xtest.fake_input(self.dpy, X.KeyPress, self.code(self.sym(modifier)))
        xtest.fake_input(self.dpy, X.KeyPress, code)
        xtest.fake_input(self.dpy, X.KeyRelease, code)
        for modifier in reversed(held):
            xtest.fake_input(self.dpy, X.KeyRelease, self.code(self.sym(modifier)))
        self.dpy.sync()


def chord(keyboard, text):
    parts = text.split("+")
    held = [MODIFIERS[p.lower()] for p in parts[:-1] if p.lower() in MODIFIERS]
    unknown = [p for p in parts[:-1] if p.lower() not in MODIFIERS]
    if unknown:
        raise SystemExit(f"unknown modifier: {unknown[0]}")
    keyboard.tap(parts[-1], held)


def main():
    if len(sys.argv) < 2:
        raise SystemExit("usage: dev-input.py {click|move|key|type} …")
    dpy = display.Display()
    keyboard = Keyboard(dpy)
    verb, args = sys.argv[1], sys.argv[2:]

    if verb == "move":
        xtest.fake_input(dpy, X.MotionNotify, x=int(args[0]), y=int(args[1]))
    elif verb == "click":
        button = int(args[2]) if len(args) > 2 else 1
        xtest.fake_input(dpy, X.MotionNotify, x=int(args[0]), y=int(args[1]))
        dpy.sync()
        time.sleep(0.05)
        xtest.fake_input(dpy, X.ButtonPress, button)
        dpy.sync()
        time.sleep(0.05)
        xtest.fake_input(dpy, X.ButtonRelease, button)
    elif verb == "drag":
        x1, y1, x2, y2 = (int(v) for v in args[:4])
        xtest.fake_input(dpy, X.MotionNotify, x=x1, y=y1)
        dpy.sync()
        time.sleep(0.05)
        xtest.fake_input(dpy, X.ButtonPress, 1)
        dpy.sync()
        steps = 12
        for i in range(1, steps + 1):
            xtest.fake_input(
                dpy,
                X.MotionNotify,
                x=x1 + (x2 - x1) * i // steps,
                y=y1 + (y2 - y1) * i // steps,
            )
            dpy.sync()
            time.sleep(0.02)
        xtest.fake_input(dpy, X.ButtonRelease, 1)
    elif verb == "scroll":
        button = 4 if args[0] in ("up", "4") else 5
        for _ in range(int(args[1]) if len(args) > 1 else 3):
            xtest.fake_input(dpy, X.ButtonPress, button)
            xtest.fake_input(dpy, X.ButtonRelease, button)
            dpy.sync()
            time.sleep(0.02)
    elif verb == "key":
        for text in args:
            chord(keyboard, text)
            time.sleep(0.04)
    elif verb == "type":
        for char in " ".join(args):
            keyboard.tap("space" if char == " " else char)
            time.sleep(0.012)
    else:
        raise SystemExit(f"unknown verb: {verb}")
    dpy.sync()


if __name__ == "__main__":
    main()
