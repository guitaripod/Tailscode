#!/usr/bin/env python3
"""The window manager a film display does not otherwise have.

Xvfb runs bare: nothing centres a dialog, and X's default PointerRoot focus means the keyboard
belongs to whatever the pointer happens to be over. Both matter on camera — a modal pinned to the
top-left corner reads as a bug, and a key press that lands in the window behind the modal ruins a
take. So this centres every window the app maps after its first one, raises it, and carries the
pointer into it; when that window goes away the pointer goes home to the main window.

Popup surfaces (menus, popovers, tooltips) are override-redirect and are left exactly where the
toolkit put them — they are positioned against a widget, not against the screen.
"""
import sys
import time

from Xlib import X, display, error
from Xlib.ext import xtest


class Stagehand:
    def __init__(self):
        self.dpy = display.Display()
        self.screen = self.dpy.screen()
        self.root = self.screen.root
        self.width = self.screen.width_in_pixels
        self.height = self.screen.height_in_pixels
        self.main = None
        self.staged = []
        self.root.change_attributes(event_mask=X.SubstructureNotifyMask)
        self.dpy.sync()

    def geometry(self, window):
        try:
            geometry = window.get_geometry()
            return geometry.x, geometry.y, geometry.width, geometry.height
        except (error.BadWindow, error.BadDrawable):
            return None

    def is_popup(self, window):
        try:
            return bool(window.get_attributes().override_redirect)
        except (error.BadWindow, error.BadDrawable):
            return True

    def pointer(self):
        try:
            reply = self.root.query_pointer()
            return reply.root_x, reply.root_y
        except (error.BadWindow, error.BadDrawable):
            return self.width // 2, self.height // 2

    def glide(self, x, y, seconds=0.22, steps=22):
        """A jump-cut of the pointer reads as a glitch on camera, so it travels instead."""
        start = self.pointer()
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

    def warp(self, window):
        box = self.geometry(window)
        if not box:
            return
        self.glide(box[0] + box[2] // 2, box[1] + box[3] // 2)

    def centre(self, window):
        box = self.geometry(window)
        if not box:
            return
        x = max(0, (self.width - box[2]) // 2)
        y = max(0, (self.height - box[3]) // 2)
        try:
            window.configure(x=x, y=y, stack_mode=X.Above)
            self.dpy.sync()
        except (error.BadWindow, error.BadDrawable):
            return
        print(f"staged {window.id:#x} {box[2]}x{box[3]} at {x},{y}", flush=True)

    def mapped(self, window):
        if self.is_popup(window):
            return
        box = self.geometry(window)
        if not box or box[2] < 80 or box[3] < 80:
            return
        if self.main is None:
            self.main = window
            print(f"main {window.id:#x} {box[2]}x{box[3]}", flush=True)
            return
        if window.id == self.main.id:
            return
        time.sleep(0.12)
        self.centre(window)
        self.warp(window)
        self.staged.append(window.id)

    def gone(self, window_id):
        if window_id in self.staged:
            self.staged.remove(window_id)
            if not self.staged and self.main is not None:
                self.warp(self.main)

    def run(self):
        while True:
            event = self.dpy.next_event()
            if event.type == X.MapNotify:
                self.mapped(event.window)
            elif event.type in (X.UnmapNotify, X.DestroyNotify):
                self.gone(event.window.id)


if __name__ == "__main__":
    try:
        Stagehand().run()
    except KeyboardInterrupt:
        sys.exit(0)
