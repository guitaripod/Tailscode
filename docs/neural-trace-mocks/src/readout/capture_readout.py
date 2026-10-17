import sys, json
from pathlib import Path
from playwright.sync_api import sync_playwright

page_url = sys.argv[1]
out_dir = Path(sys.argv[2])
jobs = json.loads(sys.argv[3])
dpr = float(sys.argv[4]) if len(sys.argv) > 4 else 2
with sync_playwright() as p:
    b = p.chromium.launch()
    for j in jobs:
        ctx = b.new_context(viewport={"width": j.get("w", 1500), "height": j.get("h", 1000)}, device_scale_factor=j.get("dpr", dpr))
        pg = ctx.new_page(); errs = []
        pg.on("console", lambda m: errs.append(m.text) if m.type in ("error", "warning") else None)
        pg.on("pageerror", lambda e: errs.append(str(e)))
        pg.goto(page_url + j.get("q", ""))
        try: pg.wait_for_function("window.__ready===true", timeout=20000)
        except Exception: errs.append("notready")
        pg.wait_for_timeout(j.get("after", 400))
        sel = j.get("sel")
        path = str(out_dir / j["out"])
        if sel: pg.locator(sel).first.screenshot(path=path)
        else: pg.screenshot(path=path, full_page=True)
        print(j["out"], "errors:", errs[:6]); ctx.close()
    b.close()
