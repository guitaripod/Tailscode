import sys, json, base64, io
from pathlib import Path
from PIL import Image
from playwright.sync_api import sync_playwright

root = Path(sys.argv[1]); work = Path(sys.argv[2]); work.mkdir(parents=True, exist_ok=True)
STATES = [
 ("settled","Working",None),
]
ARGS = ["--use-gl=angle","--use-angle=swiftshader","--enable-unsafe-swiftshader","--ignore-gpu-blocklist"]
T = {"thinking":.95,"reading":.95,"editing":.95,"running":.95,"writing":.95,"delegating":.95,"background":1.5,"approval":.128,"question":.128,"retrying":.5,"compacting":1.3,"connecting":.5,"reconnecting":.5}
IDS = ["idle","settled","thinking","reading","editing","running","writing","delegating","background","approval","question","stalled","retrying","compacting","queued","connecting","reconnecting","failed","stopped","offline"]
CROPS = {
 "ctx42":("?state=settled&ctx=0.42",(190,356,390,420)),
 "ctx65":("?state=settled&ctx=0.65",(190,356,390,420)),
 "ctx90":("?state=settled&ctx=0.92",(190,356,390,420)),
 "eff1":("?state=settled&effort=low",(520,170,640,260)),
 "eff3":("?state=settled&effort=high",(520,170,640,260)),
 "eff5":("?state=settled&effort=max",(520,170,640,260)),
 "effU":("?state=settled&effort=ultracode&t=1",(520,170,640,260)),
 "effS":("?state=settled&effort=server%20decides",(520,170,640,260)),
 "callL":("?state=idle&call=listening&t=.95",(270,290,410,382)),
 "callH":("?state=idle&call=hearing",(270,290,410,382)),
 "callD":("?state=idle&call=degraded",(270,290,410,382)),
}
def uri(img, q=82):
    buf = io.BytesIO(); img.convert("RGB").save(buf, "WEBP", quality=q, method=6)
    return "data:image/webp;base64," + base64.b64encode(buf.getvalue()).decode()
out = {"states": {}, "crops": {}}
with sync_playwright() as p:
    b = p.chromium.launch(args=ARGS)
    pg = b.new_page(viewport={"width":1180,"height":1200}, device_scale_factor=1)
    for sid in IDS:
        t = T.get(sid, 0)
        pg.goto(f"file://{root}/G.html?state={sid}&t={t}")
        pg.wait_for_function("window.__heroReady===true", timeout=20000); pg.wait_for_timeout(700)
        el = pg.locator("#stage"); el.screenshot(path=str(work/f"{sid}.png"))
        out["states"][sid] = uri(Image.open(work/f"{sid}.png").resize((620, 407)))
        print("shot", sid)
    for cid,(q,box) in CROPS.items():
        pg.goto(f"file://{root}/G.html{q}")
        pg.wait_for_function("window.__heroReady===true", timeout=20000); pg.wait_for_timeout(700)
        el = pg.locator("#stage"); bb = el.bounding_box()
        sx, sy = bb["width"]/640, bb["height"]/420
        x0,y0,x1,y1 = box
        pg.screenshot(path=str(work/f"{cid}.png"), clip={"x":bb["x"]+x0*sx,"y":bb["y"]+y0*sy,"width":(x1-x0)*sx,"height":(y1-y0)*sy})
        im = Image.open(work/f"{cid}.png"); im = im.resize((int(im.width*1.6), int(im.height*1.6)))
        out["crops"][cid] = uri(im, 88)
        print("crop", cid)
    b.close()
json.dump(out, open(work/"sheet.json","w"))
