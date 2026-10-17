import sys, json
from pathlib import Path
from playwright.sync_api import sync_playwright
root=Path(sys.argv[1]); shots=Path(sys.argv[2]); jobs=json.loads(sys.argv[3])
with sync_playwright() as p:
    b=p.chromium.launch(args=["--use-gl=angle","--use-angle=swiftshader","--enable-unsafe-swiftshader","--ignore-gpu-blocklist"])
    for j in jobs:
        ctx=b.new_context(viewport={"width":j.get("w",1100),"height":j.get("h",800)},device_scale_factor=j.get("dpr",1))
        pg=ctx.new_page(); errs=[]
        pg.on("console",lambda m:errs.append(m.text) if m.type in("error","warning") else None); pg.on("pageerror",lambda e:errs.append(str(e)))
        pg.goto(f"file://{root}/{j['file']}{j.get('q','')}")
        try: pg.wait_for_function("window.__heroReady===true",timeout=20000)
        except Exception as e: errs.append("notready")
        for a in j.get("acts",[]):
            if a[0]=="hover": pg.hover(a[1])
            elif a[0]=="click": pg.click(a[1])
            elif a[0]=="dbl": pg.dblclick(a[1])
            elif a[0]=="wait": pg.wait_for_timeout(a[1])
        pg.wait_for_timeout(j.get("after",800))
        pg.screenshot(path=str(shots/j["out"]),full_page=True)
        print(j["out"],"errors:",errs[:5]); ctx.close()
    b.close()
