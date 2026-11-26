#!/usr/bin/env python3
"""One measured walk of the Linux client's surfaces, headless.

The app runs on the harness display (scripts/dev-linuxapp.sh), as this script's child so its
stdout, its CPU and its flight ring are all readable; the stages below are driven through the
app's own TAILSCODE_DRIVE_FILE verbs and through real XTEST pointer and key events, the same
paths a person uses. Every stage's CPU, its peak resident size and the flight ring's busy and
stall are printed as one table per run, so two builds can be compared line for line.

    TAILSCODE_DEV_GEOM=1920x2160x24 scripts/dev-linuxapp.sh run \
        ~/.cache/tailscode-dev/xvenv/bin/python scripts/bench-linuxapp.py

    TAILSCODE_BENCH_TEMPLATE=<dir>  restore the app's config from this directory before the run,
                                    so every run starts from the same saved session and layout
    TAILSCODE_BENCH_OUT=<path>      write the raw samples and parsed marks as JSON
    TAILSCODE_BENCH_SAMPLE=1        also sample the main thread with eu-stack during the
                                    chat-open and split stages, written beside the JSON
"""
import json
import os
import re
import signal
import subprocess
import sys
import time

from Xlib import X, XK, display
from Xlib.ext import xtest

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN = os.environ.get(
    "TAILSCODE_BIN", os.path.join(REPO, "TailscodeLinux/.build/release/tailscode"))
TEMPLATE = os.environ.get("TAILSCODE_BENCH_TEMPLATE", "")
OUT = os.environ.get("TAILSCODE_BENCH_OUT", "/tmp/tailscode-bench.json")
SAMPLE = os.environ.get("TAILSCODE_BENCH_SAMPLE") == "1"
SAMPLE_STAGES = set(
    (os.environ.get("TAILSCODE_BENCH_SAMPLE_STAGES") or "").split(",")) - {""}
SHED = os.environ.get("TAILSCODE_BENCH_SHED", "0")
DRIVE = os.environ["TAILSCODE_DRIVE_FILE"]

STAGES = [
    ("launch", 10.0, []),
    ("sidebar-scroll", 8.0, [("wheel", 0.3, 220, 900, "down", 260)]),
    ("chat-open", 10.0, []),
    ("transcript-scroll", 8.0, [("wheel", 0.3, 1200, 1100, "down", 300), ("drive", 7.0, "jump")]),
    ("typing", 8.0, [("click-composer", 0.2), ("type", 0.8, 0.03,
        "The reconnect path retries with a capped backoff and jitter, so a dropped link comes back without a burst of reconnects.")]),
    ("tablestream", 8.0, [("drive", 0.3, "tablestream")]),
    ("split", 10.0, [("drive", at, verb) for at, verb in (
        (0.3, "split=right"), (0.8, "split=down"), (1.3, "sfocus=right"),
        (1.8, "sxchg"), (2.3, "szoom"), (2.8, "szoom"), (3.3, "seq"))]
        + [("wheel", 4.0, 500, 1100, "down", 120)]),
    ("agents", 10.0, [("drive", 0.3, "agents"), ("drive", 1.6, "agents-watch=squad"),
                      ("drive", 3.0, "agents-bench=5"), ("drive", 8.6, "agents-close")]),
    ("brain", 12.0, [("drive", 0.3, "brain=demo=build"), ("drive", 0.9, "brain=open"),
                     ("drive", 1.6, "brain=live=8"), ("drive", 10.2, "brain=perf")]),
    ("panels", 9.0, [("drive", at, verb) for at, verb in (
        (0.3, "settings"), (1.6, "esc"), (2.2, "usage"), (3.5, "esc"),
        (4.1, "models"), (5.4, "esc"), (6.0, "servers"), (7.4, "esc"))]),
    ("theme", 5.0, [("drive", 0.3, "brain=theme=outerrim,dark"),
                    ("drive", 2.4, "brain=theme=nord,dark")]),
    ("settle", 3.0, []),
]


class Screen:
    def __init__(self):
        self.dpy = display.Display()
        self.keyboard = Keyboard(self.dpy)

    def move(self, x, y):
        xtest.fake_input(self.dpy, X.MotionNotify, x=int(x), y=int(y))
        self.dpy.sync()

    def click(self, x, y):
        self.move(x, y)
        time.sleep(0.05)
        xtest.fake_input(self.dpy, X.ButtonPress, 1)
        self.dpy.sync()
        time.sleep(0.05)
        xtest.fake_input(self.dpy, X.ButtonRelease, 1)
        self.dpy.sync()

    def wheel(self, button):
        xtest.fake_input(self.dpy, X.ButtonPress, button)
        xtest.fake_input(self.dpy, X.ButtonRelease, button)
        self.dpy.sync()

    def tap(self, key):
        self.keyboard.tap(key)

    def mapped(self):
        return bool(self.dpy.screen().root.query_tree().children)


class Keyboard:
    def __init__(self, dpy):
        self.dpy = dpy

    def code(self, keysym):
        return self.dpy.keysym_to_keycode(keysym)

    def tap(self, key):
        if key == "esc":
            keysym = XK.string_to_keysym("Escape")
        elif key == " ":
            keysym = XK.string_to_keysym("space")
        else:
            keysym = XK.string_to_keysym(key) or ord(key)
        code = self.code(keysym)
        if not code:
            return
        shift = 0
        if 0x20 <= keysym <= 0x7E:
            upper = XK.string_to_keysym(key.upper())
            if upper and self.code(upper) == code and key != key.lower():
                shift = self.code(XK.string_to_keysym("Shift_L"))
        if shift:
            xtest.fake_input(self.dpy, X.KeyPress, shift)
        xtest.fake_input(self.dpy, X.KeyPress, code)
        xtest.fake_input(self.dpy, X.KeyRelease, code)
        if shift:
            xtest.fake_input(self.dpy, X.KeyRelease, shift)
        self.dpy.sync()


def read_cpu(pid):
    try:
        with open("/proc/%d/stat" % pid) as handle:
            fields = handle.read().rsplit(") ", 1)[1].split()
        with open("/proc/%d/status" % pid) as handle:
            for line in handle:
                if line.startswith("VmRSS:"):
                    rss = int(line.split()[1]) / 1024
                    break
            else:
                rss = 0
        ticks = int(fields[11]) + int(fields[12])
        return ticks / os.sysconf("SC_CLK_TCK"), rss
    except (FileNotFoundError, ProcessLookupError, IndexError, ValueError):
        return None, 0


def read_threads(pid):
    """CPU ticks per thread id, with the thread's name, for saying where a busy second went."""
    threads = {}
    rate = os.sysconf("SC_CLK_TCK")
    try:
        for entry in os.listdir("/proc/%d/task" % pid):
            try:
                with open("/proc/%d/task/%s/stat" % (pid, entry)) as handle:
                    raw = handle.read()
                name = raw.rsplit(") ", 1)[0].rsplit("(", 1)[1]
                fields = raw.rsplit(") ", 1)[1].split()
                threads[entry] = (name, (int(fields[11]) + int(fields[12])) / rate)
            except (FileNotFoundError, ProcessLookupError, IndexError, ValueError):
                continue
    except FileNotFoundError:
        return {}
    return threads


def composer_point(stdout_path):
    try:
        with open(stdout_path, errors="ignore") as handle:
            lines = [line for line in handle if line.startswith("GEOM ")]
    except FileNotFoundError:
        return None
    if not lines:
        return None
    match = re.search(r"composer=([\d.]+),([\d.]+)", lines[-1])
    return (float(match.group(1)), float(match.group(2))) if match else None


def main():
    if TEMPLATE:
        config = os.path.join(os.environ["XDG_CONFIG_HOME"], "tailscode")
        subprocess.run(["rm", "-rf", config], check=False)
        subprocess.run(["cp", "-a", TEMPLATE, config], check=False)
    with open(DRIVE, "w") as handle:
        handle.write("")
    stdout_path = os.path.join(os.path.dirname(OUT), "tailscode-bench-app.log")
    os.makedirs(os.path.dirname(stdout_path), exist_ok=True)
    stdout = open(stdout_path, "w")
    env = dict(os.environ)
    env.setdefault("TAILSCODE_TRACE", "1")
    renderer = os.environ.get("TAILSCODE_BENCH_RENDERER")
    if renderer:
        env["GSK_RENDERER"] = renderer
        env.pop("LIBGL_ALWAYS_SOFTWARE", None)
    wall_start = time.time()
    started = time.monotonic()
    app = subprocess.Popen([BIN], stdout=stdout, stderr=subprocess.STDOUT, env=env,
                           start_new_session=True)
    startup_sampler = start_sampler(app.pid, stdout_path, "startup")
    screen = Screen()
    while not screen.mapped() and time.monotonic() - started < 30:
        time.sleep(0.05)
    mapped_at = time.monotonic() - started
    if SHED:
        with open(DRIVE, "a") as handle:
            handle.write("shed=%s\n" % SHED)

    schedule = []
    offset = 0.0
    stage_spans = []
    idle_indices = []
    sections_line = ""
    for _ in range(3):
        with open(DRIVE, "a") as handle:
            handle.write("sections\n")
        deadline = time.monotonic() + 1.5
        while time.monotonic() < deadline:
            try:
                with open(stdout_path, errors="ignore") as handle:
                    for line in handle:
                        if line.startswith("SECTIONS "):
                            sections_line = line.strip()
            except FileNotFoundError:
                pass
            if len(sections_line) > 200:
                break
            time.sleep(0.1)
        if len(sections_line) > 200:
            break
    if sections_line:
        for index, item in enumerate(sections_line[len("SECTIONS "):].split(" | ")[:400]):
            state = item.split(":", 1)[0]
            if state == "idle":
                idle_indices.append(index)
    primary = idle_indices[0] if idle_indices else 6
    with open(DRIVE, "a") as handle:
        handle.write("open=%d\n" % primary)
    print("BENCH idle indices %s, primary %d" % (idle_indices[:10], primary), flush=True)
    opens = (idle_indices[1:8] or [primary + step for step in range(1, 8)])[:7]
    for name, seconds, actions in STAGES:
        stage_spans.append((name, offset, offset + seconds))
        for action in actions:
            schedule.append((offset + action[1], action))
        offset += seconds
    schedule = [(when, action) for when, action in schedule]
    chat_open_start = next(start for name, start, end in stage_spans if name == "chat-open")
    for step, index in enumerate(opens):
        schedule.append((chat_open_start + 0.4 + step * 1.3, ("drive", 0.0, "open=%d" % index)))
    schedule.sort(key=lambda pair: pair[0])

    samples = []
    thread_before = read_threads(app.pid)
    thread_samples = []
    wheel_todo = []
    typer = None
    next_cpu = started
    sample_process = None
    index = 0
    while True:
        now = time.monotonic()
        elapsed = now - started
        if elapsed >= offset:
            break
        if now >= next_cpu:
            cpu, rss = read_cpu(app.pid)
            samples.append({"t": round(elapsed, 3), "cpu": cpu, "rss": rss})
            threads = read_threads(app.pid)
            delta = {}
            for tid, (name, ticks) in threads.items():
                before = thread_before.get(tid)
                if before is not None and ticks >= before[1]:
                    delta[name] = delta.get(name, 0) + (ticks - before[1])
            if thread_before:
                thread_samples.append({"t": round(elapsed, 3), "delta": delta})
            thread_before = threads
            next_cpu = now + 0.1
        while index < len(schedule) and schedule[index][0] <= elapsed:
            _, action = schedule[index]
            index += 1
            kind = action[0]
            if kind == "drive":
                with open(DRIVE, "a") as handle:
                    handle.write(action[2] + "\n")
            elif kind == "wheel":
                x, y, direction, count = action[2], action[3], action[4], action[5]
                screen.move(x, y)
                button = 4 if direction == "up" else 5
                until = next(end for name, start, end in stage_spans if start <= elapsed < end)
                wheel_todo.append({"button": button, "left": count, "due": now, "until": until})
            elif kind == "click-composer":
                with open(DRIVE, "a") as handle:
                    handle.write("geom\n")
                time.sleep(0.4)
                point = composer_point(stdout_path) or (1200, 2050)
                screen.click(*point)
            elif kind == "type":
                typer = {"chars": list(action[3]), "gap": action[2], "due": now}
            elif kind == "key":
                screen.tap(action[2])
        if wheel_todo:
            due = [item for item in wheel_todo
                   if item["left"] > 0 and now >= item["due"] and elapsed < item["until"]]
            for item in due:
                screen.wheel(item["button"])
                item["left"] -= 1
                item["due"] = now + 1 / 30
            wheel_todo[:] = [item for item in wheel_todo
                             if item["left"] > 0 and elapsed < item["until"]]
        if typer and typer["chars"] and now >= typer["due"]:
            screen.tap(typer["chars"].pop(0))
            typer["due"] = now + typer["gap"]
        current = next((name for name, start, end in stage_spans if start <= elapsed < end), None)
        if startup_sampler is not None and elapsed > 8:
            startup_sampler.terminate()
            startup_sampler = None
        want_sample = current is not None and (
            current in SAMPLE_STAGES or (SAMPLE and current not in ("launch", "settle")))
        if want_sample and sample_process is None:
            print("BENCH sampling %s" % current, flush=True)
            sample_process = start_sampler(app.pid, stdout_path, current)
        elif not want_sample and sample_process is not None:
            print("BENCH sampled %s" % current, flush=True)
            sample_process.terminate()
            sample_process = None
        time.sleep(0.02)
    if sample_process is not None:
        sample_process.terminate()
    wall_end = time.time()
    cpu_end, rss_end = read_cpu(app.pid)
    app.send_signal(signal.SIGTERM)
    try:
        app.wait(timeout=8)
    except subprocess.TimeoutExpired:
        app.kill()
    stdout.close()

    spans = {}
    for name, start, end in stage_spans:
        inside = [s for s in samples if start <= s["t"] < end]
        before = [s for s in samples if s["t"] < start]
        baseline = before[-1] if before else inside[0] if inside else None
        last = inside[-1] if inside else baseline
        seconds = max(0.001, (last["t"] if last else start) - (baseline["t"] if baseline else start))
        cost = (last["cpu"] - baseline["cpu"]) if baseline and last else 0
        spans[name] = {
            "wall": round(seconds, 2),
            "cpu": round(cost, 2),
            "share": round(100 * cost / seconds, 1) if seconds else 0,
            "rss_peak": round(max([s["rss"] for s in inside], default=0), 0),
        }
        thread_sums = {}
        for sample in thread_samples:
            if start <= sample["t"] < end:
                for thread, value in sample["delta"].items():
                    thread_sums[thread] = thread_sums.get(thread, 0) + value
        spans[name]["threads"] = sorted(thread_sums.items(), key=lambda pair: -pair[1])[:5]

    flight = subprocess.run([BIN, "--flight", "4"], capture_output=True, text=True, env=env)
    marks = []
    opens = {"first rows": [], "first frame": [], "revealed": [], "filled": []}
    with open(stdout_path, errors="ignore") as handle:
        for line in handle:
            if line.startswith("TRACE") and "open+" in line:
                marks.append(line.strip())
                match = re.search(r"open\+(\d+)ms (first rows|first frame|revealed|filled|placeholder)", line)
                if match and match.group(2) in opens:
                    opens[match.group(2)].append(int(match.group(1)))
    flight_rows = []
    start_label = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(wall_start - 2))
    end_label = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(wall_end + 1))
    for line in flight.stdout.splitlines():
        match = re.match(r"^(\S+ \S+)  +\d+  +\S+  +(\S+) +(\S+)ms", line)
        if match and start_label <= match.group(1) <= end_label:
            flight_rows.append({"time": match.group(1), "busy": match.group(2),
                                "stall": int(match.group(3))})

    report = {
        "binary": BIN,
        "mapped_after": round(mapped_at, 2),
        "stages": spans,
        "opens": {key: values for key, values in opens.items()},
        "flight": flight_rows,
        "samples": samples,
    }
    with open(OUT, "w") as handle:
        json.dump(report, handle, indent=1)
    print("%-18s %7s %6s %6s %8s  %s" % ("stage", "cpu s", "share", "rss MB", "wall s", "top thread"))
    for name, data in spans.items():
        top = data["threads"][0] if data["threads"] else ("-", 0)
        print("%-18s %7.2f %5.1f%% %6.0f %8.2f  %s %.2f"
              % (name, data["cpu"], data["share"], data["rss_peak"], data["wall"], top[0], top[1]))
    for key, values in opens.items():
        if values:
            values = sorted(values)
            print("open %-11s n=%d median %d ms p90 %d ms max %d ms"
                  % (key, len(values), values[len(values) // 2],
                     values[int(len(values) * 0.9)], values[-1]))
    if flight_rows:
        busy = [float(row["busy"]) for row in flight_rows if row["busy"] not in ("-",)]
        stalls = [row["stall"] for row in flight_rows]
        print("flight %d s: worst busy %.2f, worst stall %d ms"
              % (len(flight_rows), max(busy, default=0), max(stalls, default=0)))
    print("json %s" % OUT)


def start_sampler(pid, beside, stage):
    path = os.path.join(os.path.dirname(beside), "stacks-%s.txt" % stage)
    handle = open(path, "w")
    return subprocess.Popen(
        ["bash", "-c",
         'for i in $(seq 1 2000); do eu-stack -1 -q -m -b -p %d 2>/dev/null; sleep 0.01; done' % pid],
        stdout=handle, stderr=subprocess.DEVNULL)


if __name__ == "__main__":
    sys.exit(main())
