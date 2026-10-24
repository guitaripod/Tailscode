#!/usr/bin/env python3
"""A scripted take of the Linux client on a film display: real pointer and keyboard input through
XTEST, a recorder that draws no pointer, and a log of everything that was done and when, so the cut
can lay a cursor and a click on top of the picture instead of filming X's own.

A shot script imports this, is run with the display's own python (the one record-linuxapp.sh uses),
and looks like

    rig = Rig(display_num=78, name="party")
    rig.record()
    rig.mark("open the party")
    rig.click(1620, 1010, label="the model pill")
    rig.hold(2.5)
    rig.stop()

Coordinates are LOGICAL, the ones a screenshot made by `rig.shot` shows: the film display is
scaled, and the rig multiplies. Times in the log are seconds from the first recorded frame.
"""
import json
import os
import subprocess
import sys
import time
import importlib.util
from pathlib import Path

from Xlib import X, display
from Xlib.ext import xtest

REPO = Path(__file__).resolve().parent.parent


def _input_module():
    spec = importlib.util.spec_from_file_location("dev_input", REPO / "scripts" / "dev-input.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class Rig:
    def __init__(self, display_num=78, name="take", state_dir=None, scale=2, fps=30):
        self.display_num = display_num
        self.name = name
        self.scale = scale
        self.fps = fps
        self.state = Path(state_dir or f"/mnt/nvme8tb/film/tailscode-carry-party/{name}")
        self.state.mkdir(parents=True, exist_ok=True)
        os.environ["DISPLAY"] = f":{display_num}"
        self.dpy = display.Display(f":{display_num}")
        screen = self.dpy.screen()
        self.width, self.height = screen.width_in_pixels, screen.height_in_pixels
        self.keyboard = _input_module().Keyboard(self.dpy)
        self.events = []
        self.marks = []
        self.pointer = (self.width // 2, self.height // 2)
        self.t0 = None
        self.ffmpeg = None
        self.take = self.state / f"{name}.mkv"

    def fit_window(self):
        """The film display has no window manager, so the main window keeps whatever size it
        asked for; this gives it the whole screen, the way a maximised window would have it."""
        best = None
        for child in self.dpy.screen().root.query_tree().children:
            try:
                geometry = child.get_geometry()
                attributes = child.get_attributes()
            except Exception:
                continue
            if attributes.override_redirect or attributes.map_state != X.IsViewable:
                continue
            area = geometry.width * geometry.height
            if best is None or area > best[0]:
                best = (area, child)
        if best:
            best[1].configure(x=0, y=0, width=self.width, height=self.height)
            self.dpy.sync()
            time.sleep(0.6)

    def now(self):
        return time.time() - self.t0 if self.t0 is not None else 0.0

    def log(self, kind, **fields):
        self.events.append({"t": round(self.now(), 3), "kind": kind, **fields})

    def record(self):
        self.take.unlink(missing_ok=True)
        command = [
            "ffmpeg", "-hide_banner", "-loglevel", "warning", "-y",
            "-f", "x11grab", "-framerate", str(self.fps),
            "-video_size", f"{self.width}x{self.height}", "-draw_mouse", "0",
            "-thread_queue_size", "1024", "-i", f":{self.display_num}",
            "-c:v", "libx264", "-preset", "ultrafast", "-qp", "0", "-pix_fmt", "yuv444p",
            "-g", "60", str(self.take),
        ]
        self.ffmpeg = subprocess.Popen(
            command, stderr=open(self.state / "ffmpeg.log", "w"), stdin=subprocess.PIPE
        )
        time.sleep(0.8)
        self.t0 = time.time()
        self.log("start", width=self.width, height=self.height, scale=self.scale, fps=self.fps)

    def stop(self):
        self.log("stop")
        if self.ffmpeg:
            self.ffmpeg.stdin.write(b"q")
            self.ffmpeg.stdin.flush()
            self.ffmpeg.wait(timeout=60)
            self.ffmpeg = None
        stop_at = self.events[-1]["t"]
        length = float(
            subprocess.run(
                ["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0",
                 str(self.take)],
                capture_output=True, text=True,
            ).stdout.strip()
            or 0
        )
        (self.state / f"{self.name}.events.json").write_text(
            json.dumps(
                {"take": str(self.take), "scale": self.scale, "offset": round(length - stop_at, 3),
                 "marks": self.marks, "events": self.events},
                indent=1,
            )
        )

    def mark(self, label, **fields):
        self.marks.append({"t": round(self.now(), 3), "label": label})
        self.log("mark", label=label, **fields)

    def hold(self, seconds):
        time.sleep(seconds)

    def _physical(self, x, y):
        return int(round(x * self.scale)), int(round(y * self.scale))

    def _motion(self, px, py):
        xtest.fake_input(self.dpy, X.MotionNotify, x=px, y=py)
        self.dpy.sync()
        self.pointer = (px, py)

    def glide(self, x, y, seconds=0.45):
        px, py = self._physical(x, y)
        sx, sy = self.pointer
        steps = max(8, int(seconds * 60))
        for step in range(1, steps + 1):
            fraction = step / steps
            eased = fraction * fraction * (3 - 2 * fraction)
            self._motion(int(sx + (px - sx) * eased), int(sy + (py - sy) * eased))
            self.log("pointer", x=self.pointer[0] / self.scale, y=self.pointer[1] / self.scale)
            time.sleep(seconds / steps)

    def click(self, x, y, button=1, label="", seconds=0.45, settle=0.12):
        self.glide(x, y, seconds)
        time.sleep(settle)
        self.log("press", x=x, y=y, button=button, label=label)
        xtest.fake_input(self.dpy, X.ButtonPress, button)
        self.dpy.sync()
        time.sleep(0.07)
        xtest.fake_input(self.dpy, X.ButtonRelease, button)
        self.dpy.sync()
        self.log("release", x=x, y=y, button=button)

    def drag(self, x1, y1, x2, y2, seconds=0.7, label=""):
        self.glide(x1, y1, 0.4)
        time.sleep(0.1)
        self.log("press", x=x1, y=y1, button=1, label=label)
        xtest.fake_input(self.dpy, X.ButtonPress, 1)
        self.dpy.sync()
        time.sleep(0.12)
        self.glide(x2, y2, seconds)
        time.sleep(0.12)
        xtest.fake_input(self.dpy, X.ButtonRelease, 1)
        self.dpy.sync()
        self.log("release", x=x2, y=y2, button=1)

    def key(self, chord, label=""):
        self.log("key", chord=chord, label=label)
        parts = chord.split("+")
        modules = _input_module()
        modules.chord(self.keyboard, chord)
        self.dpy.sync()

    def type(self, text, delay=0.07):
        self.log("type", text=text)
        for char in text:
            self.keyboard.tap("space" if char == " " else char)
            self.dpy.sync()
            time.sleep(delay)

    def shot(self, path, logical=True):
        raw = Path(str(path) + ".raw.png")
        subprocess.run(
            ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-f", "x11grab",
             "-video_size", f"{self.width}x{self.height}", "-draw_mouse", "0",
             "-i", f":{self.display_num}", "-frames:v", "1", str(raw)],
            check=True,
        )
        if logical and self.scale != 1:
            subprocess.run(
                ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", str(raw), "-vf",
                 f"scale={self.width // self.scale}:{self.height // self.scale}:flags=lanczos", str(path)],
                check=True,
            )
            raw.unlink()
        else:
            raw.rename(path)
        return path


if __name__ == "__main__":
    sys.exit("film-rig.py is a module: import it from a shot script")
