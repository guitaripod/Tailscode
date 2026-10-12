#!/usr/bin/env python3
"""The ten Mac App Store masters, photographed from the store build's own compositing.

Every master is one launch of the **store** target (`TailscodeMacStore`, TAILSCODE_MAS) in `--demo`,
so only what the sandboxed build ships is in a picture. The build is a Debug one because the verb
that photographs it (`--shot-live`, MacShot.swift, DEBUG only) is not in a Release binary.

Liquid Glass is the window server sampling what sits behind a window, so an offscreen bitmap of the
view tree (`--shot`) comes back flat. This script instead holds a *virtual* HiDPI display open — the
native size of a 13-inch MacBook Air, 1280x832 points at 2x — and the app puts its windows on it,
over a wallpaper window of its own, then asks the window server for that display's picture. Nothing is
ever drawn on the real desktop and nothing of it can show through a material, and no screen-recording
right is involved because a process may always read its own windows. The Debug product is never run
directly: it is copied under a bundle id of its own, re-signed with the store's sandbox entitlements,
so every file it writes lands in that id's container and not in the installed app's data.

  scripts/shots-mac-panels.py                       # every master, English
  scripts/shots-mac-panels.py 03-git 05-spend       # some
  scripts/shots-mac-panels.py --locale de-DE        # every master in another language
  scripts/shots-mac-panels.py --no-build            # reuse the last build

Masters land in marketing/appstore/mac-masters/<locale>/<name>.png at 2560x1664, the screen as the
window server drew it, without the menu bar (the compose step draws that).
"""
import ctypes
import json
import os
import shutil
import subprocess
import sys
import time

import AppKit
import Foundation
import objc
from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRATCH = os.environ.get("TAILSCODE_PANELS_SCRATCH", "/tmp/tailscode-panels")
DERIVED = os.path.join(SCRATCH, "dd")
STAGE = os.path.join(SCRATCH, "app")
BUNDLE = "com.guitaripod.tailscode.panels"
CONTAINER = os.path.expanduser(f"~/Library/Containers/{BUNDLE}/Data")
OUT = os.path.join(ROOT, "marketing/appstore/mac-masters")
SCREEN_NAME = "Tailscode Panels"
POINTS = (1280, 832)
PIXELS = (POINTS[0] * 2, POINTS[1] * 2)

REQUIRED_GUARDS = {"Game Center", "StoreKit", "update checks", "global hot key", "activation"}

LANGUAGES = {
    "de-DE": "de", "es-ES": "es", "fr-FR": "fr", "it": "it", "ja": "ja", "ko": "ko", "pl": "pl",
    "pt-BR": "pt-BR", "zh-Hans": "zh-Hans", "zh-Hant": "zh-Hant",
}

CHAT_WINDOW = "20,40,1240,512"
ZOOM = 1.4

MASTERS = [
    {"name": "01-conversation", "session": "demo-c1", "args": [], "delay": 16},
    {"name": "02-split", "session": "demo-c1", "args": ["--open", "split:demo-o2"], "delay": 32,
     "drive": "9000:tile=focus,1;10000:tile=pin;11000:tile=focus,2;12000:tile=pin;13000:tile=focus,1;19000:tile=focus,1;500:shed=0;2000:shed=0;3500:shed=0;5000:shed=0;6500:shed=0;8000:shed=0;9500:shed=0;11000:shed=0;12500:shed=0;14000:shed=0;15500:shed=0;17000:shed=0;18500:shed=0;20000:shed=0;21500:shed=0;23000:shed=0;24500:shed=0;26000:shed=0;27500:shed=0;29000:shed=0", "window": "20,40,1240,512", "scale": 1.2,
     "strings": {"tailscode.liveBudget": "all"}},
    {"name": "03-git", "session": "demo-c1", "args": ["--open", "git:diff"], "delay": 18,
     "open_delay": 7, "surface": "30,56,1220,490"},
    {"name": "04-quickask", "session": "demo-c1", "args": ["--open", "quickask"], "delay": 16, "open_delay": 5,
     "hide_main": True, "backdrop": "editor", "window": "300,30,680,520", "scale": 1.1},
    {"name": "05-spend", "session": "demo-o1", "args": ["--open", "spend"], "delay": 18, "open_delay": 7,
     "window": "20,40,1240,560", "scale": 1.0},
    {"name": "06-analytics", "session": "demo-c1", "args": ["--open", "analytics"], "delay": 22,
     "hide_main": True, "surface": "190,40,900,512"},
    {"name": "07-approval", "session": "demo-c3", "args": [], "delay": 16},
    {"name": "08-keyboard", "session": "demo-c1", "args": ["--open", "cheatsheet"], "delay": 14,
     "surface": "40,40,1200,512"},
    {"name": "09-type", "session": "demo-c1", "args": ["--open", "typesize"], "delay": 14,
     "hide_main": True, "surface": "100,40,1080,512",
     "reals": {"tailscode.scale.prompt": 1.2, "tailscode.scale.answer": 1.1, "tailscode.scale.mono": 0.9}},
    {"name": "10-private", "session": None, "args": ["--open", "servers"], "delay": 16,
     "hide_main": True, "scale": 1.5, "surface": "230,46,820,512"},
]


def run(cmd, **kw):
    return subprocess.run(cmd, check=True, capture_output=True, text=True, **kw)


def build():
    log = os.path.join(SCRATCH, "build.log")
    with open(log, "w") as handle:
        code = subprocess.call(
            ["nice", "-n", "10", "xcodebuild", "-project", "Tailscode.xcodeproj", "-scheme",
             "TailscodeMacStore", "-configuration", "Debug", "-destination", "platform=macOS",
             "-derivedDataPath", DERIVED, "CODE_SIGNING_ALLOWED=NO", "build"],
            cwd=ROOT, stdout=handle, stderr=subprocess.STDOUT)
    if code != 0:
        subprocess.call(["grep", "-E", "error:|BUILD FAILED", log])
        sys.exit(f"build failed, see {log}")


def stage():
    """The built store app copied under a bundle id of its own and signed with the sandbox."""
    source = os.path.join(DERIVED, "Build/Products/Debug/Tailscode.app")
    if not os.path.isdir(source):
        sys.exit(f"no built app at {source}, drop --no-build")
    shutil.rmtree(STAGE, ignore_errors=True)
    os.makedirs(STAGE)
    app = os.path.join(STAGE, "Tailscode.app")
    run(["cp", "-R", source, app])
    run(["/usr/libexec/PlistBuddy", "-c", f"Set :CFBundleIdentifier {BUNDLE}",
         os.path.join(app, "Contents/Info.plist")])
    run(["codesign", "--force", "--deep", "--sign", "-", "--entitlements",
         os.path.join(ROOT, "TailscodeMac/TailscodeMac-Store.entitlements"), app])
    return app


class VirtualDisplay:
    """A HiDPI display that exists only while this process holds it."""

    def __init__(self):
        objc.loadBundle("CoreGraphics", globals(),
                        bundle_path="/System/Library/Frameworks/CoreGraphics.framework")
        descriptor = objc.lookUpClass("CGVirtualDisplayDescriptor").alloc().init()
        descriptor.setName_(SCREEN_NAME)
        descriptor.setMaxPixelsWide_(PIXELS[0])
        descriptor.setMaxPixelsHigh_(PIXELS[1])
        descriptor.setSizeInMillimeters_((286, 186))
        descriptor.setProductID_(0x7777)
        descriptor.setVendorID_(0x7778)
        descriptor.setSerialNum_(1)
        library = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
        queue = ctypes.addressof(ctypes.c_char.in_dll(library, "_dispatch_main_q"))
        descriptor.setQueue_(objc.objc_object(c_void_p=ctypes.c_void_p(queue)))
        self.display = objc.lookUpClass("CGVirtualDisplay").alloc().initWithDescriptor_(descriptor)
        settings = objc.lookUpClass("CGVirtualDisplaySettings").alloc().init()
        settings.setHiDPI_(1)
        mode = objc.lookUpClass("CGVirtualDisplayMode").alloc().initWithWidth_height_refreshRate_(
            POINTS[0], POINTS[1], 60.0)
        settings.setModes_([mode])
        if not self.display.applySettings_(settings):
            sys.exit("the virtual display refused its settings")
        self.spin(2.0)
        match = [s for s in AppKit.NSScreen.screens() if s.localizedName() == SCREEN_NAME]
        if not match or match[0].backingScaleFactor() != 2.0:
            sys.exit("the virtual display did not come up at 2x")

    @staticmethod
    def spin(seconds):
        Foundation.NSRunLoop.currentRunLoop().runUntilDate_(
            Foundation.NSDate.dateWithTimeIntervalSinceNow_(seconds))


def font(path, size, index=0):
    try:
        return ImageFont.truetype(path, size, index=index)
    except OSError:
        return ImageFont.load_default()


def wallpaper():
    """A neutral dark abstract desktop built in code: one blue-grey hue throughout, with soft pools of
    the same colour lifted a little and a faint diagonal sheen, enough structure for a glass material to
    have something to sample and no hue of its own for a panel to carry."""
    w, h = PIXELS
    base = Image.new("RGB", (w, h))
    top, bottom = (24, 30, 41), (11, 14, 21)
    column = Image.new("RGB", (1, h))
    for y in range(h):
        t = y / (h - 1)
        column.putpixel((0, y), tuple(round(a + (b - a) * t) for a, b in zip(top, bottom)))
    base = column.resize((w, h))
    for center, radius, color, alpha in (
        ((int(w * 0.14), int(h * 0.9)), 880, (58, 76, 104), 120),
        ((int(w * 0.88), int(h * 0.1)), 900, (50, 70, 98), 110),
        ((int(w * 0.62), int(h * 0.72)), 700, (46, 58, 84), 70),
        ((int(w * 0.12), int(h * 0.48)), 760, (60, 80, 108), 120),
        ((int(w * 0.8), int(h * 0.5)), 760, (48, 68, 96), 100),
    ):
        layer = Image.new("L", (w // 4, h // 4), 0)
        r = radius / 4
        cx, cy = center[0] / 4, center[1] / 4
        ImageDraw.Draw(layer).ellipse([cx - r, cy - r, cx + r, cy + r], fill=alpha)
        layer = layer.filter(ImageFilter.GaussianBlur(r / 2.2)).resize((w, h), Image.BILINEAR)
        base.paste(Image.new("RGB", (w, h), color), (0, 0), layer)
    sheen = Image.new("L", (w // 4, h // 4), 0)
    draw = ImageDraw.Draw(sheen)
    for k in range(5):
        x = int(w / 4 * (0.1 + k * 0.22))
        draw.polygon([(x, 0), (x + 60, 0), (x - 120, h // 4), (x - 180, h // 4)], fill=9)
    sheen = sheen.filter(ImageFilter.GaussianBlur(22)).resize((w, h), Image.BILINEAR)
    base.paste(Image.new("RGB", (w, h), (255, 255, 255)), (0, 0), sheen)
    return base


CODE = [
    [("import", 0xC678DD), (" Foundation", 0xABB2BF)],
    [],
    [("final class", 0xC678DD), (" ReconnectScheduler", 0xE5C07B), (" {", 0xABB2BF)],
    [("    var", 0xC678DD), (" baseDelay", 0xE06C75), (": Duration = ", 0xABB2BF), (".milliseconds(400)", 0x61AFEF)],
    [("    var", 0xC678DD), (" jitter", 0xE06C75), (": ClosedRange<Double> = ", 0xABB2BF), ("0.6...1.4", 0xD19A66)],
    [("    var", 0xC678DD), (" attempt", 0xE06C75), (" = ", 0xABB2BF), ("0", 0xD19A66)],
    [],
    [("    func", 0xC678DD), (" nextDelay", 0x61AFEF), ("() -> Duration {", 0xABB2BF)],
    [("        let", 0xC678DD), (" backoff = baseDelay * ", 0xABB2BF), ("pow(2.0, Double(attempt))", 0x61AFEF)],
    [("        let", 0xC678DD), (" factor = jitter.", 0xABB2BF), ("randomElement", 0x61AFEF), ("() ?? ", 0xABB2BF), ("1.0", 0xD19A66)],
    [("        return", 0xC678DD), (" min(backoff * factor, maxDelay)", 0xABB2BF)],
    [("    }", 0xABB2BF)],
    [],
    [("    func", 0xC678DD), (" reset", 0x61AFEF), ("() { attempt = ", 0xABB2BF), ("0", 0xD19A66), (" }", 0xABB2BF)],
    [("}", 0xABB2BF)],
]


def editor_backdrop(base):
    """Another program for the quick-ask box to float over: a generic dark code editor, drawn in code."""
    w, h = base.size
    x0, y0, x1, y1 = 150, 120, w - 130, h - 150
    shadow = Image.new("L", (w, h), 0)
    ImageDraw.Draw(shadow).rounded_rectangle([x0, y0 + 24, x1, y1 + 24], radius=28, fill=170)
    shadow = shadow.filter(ImageFilter.GaussianBlur(40))
    base.paste(Image.new("RGB", (w, h), (0, 0, 0)), (0, 0), shadow)
    draw = ImageDraw.Draw(base)
    draw.rounded_rectangle([x0, y0, x1, y1], radius=28, fill=(30, 33, 40))
    draw.rounded_rectangle([x0, y0, x1, y0 + 78], radius=28, fill=(38, 41, 50))
    draw.rectangle([x0, y0 + 50, x1, y0 + 78], fill=(38, 41, 50))
    for i, color in enumerate(((255, 95, 87), (254, 188, 46), (40, 200, 64))):
        draw.ellipse([x0 + 28 + i * 40, y0 + 28, x0 + 28 + i * 40 + 24, y0 + 52], fill=color)
    title = font("/System/Library/Fonts/SFNS.ttf", 26)
    label = "Reconnect.swift — pulse-server"
    draw.text(((x0 + x1) / 2 - draw.textlength(label, font=title) / 2, y0 + 25), label,
              font=title, fill=(170, 176, 190))
    draw.rectangle([x0, y0 + 78, x0 + 330, y1], fill=(34, 37, 45))
    side = font("/System/Library/Fonts/SFNS.ttf", 24)
    for i, (name, indent, tone) in enumerate((
        ("pulse-server", 0, 200), ("Sources", 1, 170), ("Pulse", 2, 170), ("Socket", 3, 170),
        ("Backoff.swift", 4, 150), ("Jitter.swift", 4, 150), ("Reconnect.swift", 4, 235),
        ("Tests", 1, 170), ("Package.swift", 1, 150),
    )):
        y = y0 + 112 + i * 44
        if name == "Reconnect.swift":
            draw.rectangle([x0, y - 8, x0 + 330, y + 36], fill=(52, 58, 72))
        draw.text((x0 + 28 + indent * 26, y), name, font=side, fill=(tone, tone, tone + 10))
    mono = font("/System/Library/Fonts/Menlo.ttc", 29)
    for i, line in enumerate(CODE):
        y = y0 + 118 + i * 46
        draw.text((x0 + 372, y), f"{i + 1:>2}", font=mono, fill=(88, 94, 108))
        x = x0 + 450
        for text, rgb in line:
            color = ((rgb >> 16) & 255, (rgb >> 8) & 255, rgb & 255)
            draw.text((x, y), text, font=mono, fill=color)
            x += draw.textlength(text, font=mono)
    return base


def backdrop_for(kind):
    image = wallpaper()
    if kind == "editor":
        image = editor_backdrop(image)
    return image


def seed_defaults(scale=1.0, reals=None, strings=None):
    """Preferences written where a sandboxed copy reads them, into a container nobody else uses."""
    folder = os.path.join(CONTAINER, "Library/Preferences")
    shutil.rmtree(os.path.join(CONTAINER, "Library"), ignore_errors=True)
    os.makedirs(folder, exist_ok=True)
    path = os.path.join(folder, f"{BUNDLE}.plist")
    run(["plutil", "-create", "xml1", path])
    run(["/usr/libexec/PlistBuddy", "-c", "Add :tailscode.appearance string dark", path])
    values = dict(reals or {})
    if scale != 1.0:
        values["tailscode.uiScale"] = scale
    for key, value in values.items():
        run(["/usr/libexec/PlistBuddy", "-c", f"Add :{key} real {value}", path])
    for key, value in (strings or {}).items():
        run(["/usr/libexec/PlistBuddy", "-c", f"Add :{key} string {value}", path])
    os.makedirs(os.path.join(CONTAINER, "tmp"), exist_ok=True)


def shoot(app, master, locale, display):
    tmp = os.path.join(CONTAINER, "tmp")
    seed_defaults(master.get("scale", ZOOM), master.get("reals"), master.get("strings"))
    backdrop = os.path.join(tmp, "backdrop.png")
    backdrop_for(master.get("backdrop")).save(backdrop)
    out = os.path.join(tmp, master["name"] + ".png")
    if os.path.exists(out):
        os.remove(out)
    environment = dict(os.environ)
    environment.pop("MTL_HUD_ENABLED", None)
    environment.update({
        "CFFIXED_USER_HOME": os.path.join(SCRATCH, "home"),
        "TAILSCODE_LIVE_BACKDROP": backdrop,
        "TAILSCODE_LIVE_SCREEN": SCREEN_NAME,
        "TAILSCODE_LIVE_WINDOW": master.get("window", CHAT_WINDOW),
        "TAILSCODE_DEMO_ONLY": "1",
    })
    if master.get("surface"):
        environment["TAILSCODE_LIVE_SURFACE"] = master["surface"]
    if master.get("hide_main"):
        environment["TAILSCODE_LIVE_HIDE_MAIN"] = "1"
    if master.get("session"):
        environment["TAILSCODE_OPEN_SESSION"] = master["session"]
    if master.get("open_delay"):
        environment["TAILSCODE_OPEN_DELAY"] = str(master["open_delay"])
    if master.get("drive"):
        environment["TAILSCODE_DRIVE"] = master["drive"]
    demo = ["--demo"] if master.get("demo", True) else []
    command = [os.path.join(app, "Contents/MacOS/Tailscode")] + demo + master["args"] + [
        "--shot-live", out, "--shot-delay", str(master["delay"])]
    if locale in LANGUAGES:
        command += ["-AppleLanguages", f"({LANGUAGES[locale]})", "-AppleLocale", LANGUAGES[locale]]
    started = time.time()
    process = subprocess.Popen(command, env=environment, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, text=True)
    deadline = started + master["delay"] + 90
    while process.poll() is None and time.time() < deadline:
        display.spin(0.5)
    if process.poll() is None:
        process.kill()
        sys.exit(f"{master['name']} never finished")
    report = process.stdout.read().strip().splitlines()
    for line in report:
        if os.environ.get("PANELS_VERBOSE"):
            print("   ", line)
    held = {line.split("held back ", 1)[1] for line in report if line.startswith("LIVESHOT held back ")}
    missing = REQUIRED_GUARDS - held
    with open(os.path.join(SCRATCH, "guards.log"), "a") as ledger:
        ledger.write(f"{locale} {master['name']} held back: {', '.join(sorted(held))}\n")
    if missing:
        sys.exit(f"{master['name']}: the launch guards for {sorted(missing)} did not fire; nothing was kept")
    if not os.path.exists(out):
        sys.exit(f"{master['name']} produced nothing:\n" + "\n".join(report[-8:]))
    folder = os.path.join(OUT, locale)
    os.makedirs(folder, exist_ok=True)
    final = os.path.join(folder, master["name"] + ".png")
    scrub(Image.open(out).convert("RGB")).save(final)
    print(f"  {master['name']}  {Image.open(final).size}  {time.time() - started:.0f}s")
    return final


MENU_BAR_ROWS = 76


def scrub(image):
    """The master without the window server's menu bar, which carries the front application's name and
    every status item of the machine the picture was taken on; the compose step draws its own."""
    clean = Image.open(os.path.join(OUT, "wallpaper.png")).convert("RGB")
    image.paste(clean.crop((0, 0, image.width, MENU_BAR_ROWS)), (0, 0))
    return image


def scrub_existing():
    write_wallpaper()
    for folder, _, files in os.walk(OUT):
        for name in sorted(files):
            if name.endswith(".png") and name != "wallpaper.png":
                path = os.path.join(folder, name)
                scrub(Image.open(path).convert("RGB")).save(path)
                print(f"  scrubbed {os.path.relpath(path, OUT)}")


def write_wallpaper():
    """The empty desktop, kept beside the masters: the compose step redraws the menu bar over its top
    strip, because the window server's own menu bar carries whatever the machine's owner has up there."""
    os.makedirs(OUT, exist_ok=True)
    wallpaper().save(os.path.join(OUT, "wallpaper.png"))


def main():
    args = sys.argv[1:]
    locale = "en-US"
    if "--locale" in args:
        index = args.index("--locale")
        locale = args[index + 1]
        del args[index:index + 2]
    wanted = [a for a in args if not a.startswith("--")]
    if "--scrub" in args:
        scrub_existing()
        return
    os.makedirs(SCRATCH, exist_ok=True)
    os.makedirs(os.path.join(SCRATCH, "home"), exist_ok=True)
    if "--no-build" not in args:
        build()
    app = stage()
    write_wallpaper()
    display = VirtualDisplay()
    for master in MASTERS:
        if wanted and master["name"] not in wanted:
            continue
        shoot(app, master, locale, display)


if __name__ == "__main__":
    main()
