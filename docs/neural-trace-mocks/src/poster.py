import sys, json, base64, io
from pathlib import Path
from PIL import Image
from playwright.sync_api import sync_playwright
here = Path(__file__).parent
root = Path(sys.argv[1]); work = Path(sys.argv[2]); out = Path(sys.argv[3]); work.mkdir(parents=True, exist_ok=True)
ARGS = ["--use-gl=angle","--use-angle=swiftshader","--enable-unsafe-swiftshader","--ignore-gpu-blocklist"]
def uri(img, q=88):
    buf = io.BytesIO(); img.convert("RGB").save(buf, "WEBP", quality=q, method=6)
    return "data:image/webp;base64," + base64.b64encode(buf.getvalue()).decode()
imgs = {}
with sync_playwright() as p:
    b = p.chromium.launch(args=ARGS)
    pg = b.new_page(viewport={"width":1180,"height":1000}, device_scale_factor=2)
    for th in ("matrix","rose"):
        pg.goto(f"file://{root}/E.html?mode=done&theme={th}")
        pg.wait_for_function("window.__heroReady===true", timeout=20000); pg.wait_for_timeout(900)
        pg.evaluate("document.querySelectorAll('.hint').forEach(e=>e.remove())")
        pg.locator("#stage").screenshot(path=str(work/f"poster-{th}.png"))
        imgs[th] = uri(Image.open(work/f"poster-{th}.png").resize((1936, 1270)))
    b.close()
data = (here / "data.js").read_text(); engine = (here / "engine.js").read_text(); css = (here / "base.css").read_text()
html = """<!doctype html><html lang="en" data-theme="dark"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>J · Share a turn</title><style>""" + css + """
.page{max-width:1180px;margin:0 auto;padding:18px 16px 44px}
.eyebrow{letter-spacing:.2em;font-size:11px;color:var(--accent)}
.lead{color:var(--ink2);max-width:92ch;margin:6px 0 18px}
.row{display:flex;flex-wrap:wrap;gap:24px;justify-content:center}
.frame{width:540px;height:675px;overflow:hidden;border-radius:18px;box-shadow:0 18px 50px rgba(0,0,0,.5)}
.poster{width:1080px;height:1350px;transform:scale(.5);transform-origin:top left;padding:56px;position:relative;color:var(--pi);font-family:ui-monospace,"Noto Sans Mono",monospace;display:flex;flex-direction:column}
.poster .brand{display:flex;justify-content:space-between;align-items:baseline;letter-spacing:.3em;font-size:22px;color:var(--pa)}
.poster .brand i{font-style:normal;letter-spacing:.2em;color:var(--pd);font-size:22px}
.poster img{display:block;width:968px;height:590px;object-fit:cover;object-position:center 40%;margin:22px 0 0;border-radius:36px}
.poster .hero{display:flex;align-items:baseline;gap:22px;margin-top:20px}
.poster .hero b{font-size:96px;line-height:1;font-weight:700;color:var(--pi)}
.poster .hero span{font-size:34px;color:var(--pd)}
.poster .sub{font-size:26px;color:var(--pd);margin-top:6px}
.poster .sub u{text-decoration:none;color:var(--pa)}
.poster .zones{margin-top:22px;display:grid;gap:9px}
.poster .z{display:grid;grid-template-columns:150px 1fr 60px;align-items:center;gap:16px;font-size:24px}
.poster .z .bar{height:18px;border-radius:9px;background:var(--pr);overflow:hidden}
.poster .z .bar i{display:block;height:100%;border-radius:9px}
.poster .z .n{text-align:right;color:var(--pi)}
.poster .quote{margin-top:24px;font-size:23px;line-height:1.45;color:var(--pd);border-left:6px solid var(--pa);padding-left:20px;max-height:68px;overflow:hidden}
.poster .foot{margin-top:auto;display:flex;justify-content:space-between;font-size:20px;color:var(--pd)}
""" + """</style></head><body><main class="page">
<div class="eyebrow">J · SHARE A TURN</div>
<p class="lead">A turn as a poster, laid out in pure geometry the way the analytics card is: the head as the hero, the numbers the transcript can prove (tools, time, lines changed, what each zone did), the question that started it, and nothing that is an estimate. Two looks, chosen before it leaves. A clip of the replay follows the same frame.</p>
<div class="row" id="row"></div>
</main><script>""" + f"const IMG={json.dumps(imgs)};" + data + engine + """
const L=TURN.filter(s=>s.fam!=='think'&&s.fam!=='say'),Z={think:0,sense:0,act:0,shell:0,delegate:0,say:0};TURN.forEach(s=>Z[s.fam]++);
const tools=Neural.toolCount(TURN),dif=Neural.diffTally(TURN);
const names={think:'PLAN',sense:'SENSE',act:'ACT',shell:'SHELL',delegate:'DELEGATE',say:'SAY'};
const LOOKS={
 matrix:{bg:'linear-gradient(160deg,#04120b 0%,#030806 55%,#020504 100%)',pi:'#d3f7e0',pd:'#7fae93',pa:'#39ff88',pr:'#0c1d14',tones:{think:'#d3f7e0',sense:'#6fd6ea',act:'#39ff88',shell:'#b79cff',delegate:'#89be9b',say:'#7ff0c8'},glow:'rgba(57,255,136,.10)'},
 rose:{bg:'linear-gradient(160deg,#26233a 0%,#191724 60%,#14121f 100%)',pi:'#e0def4',pd:'#908caa',pa:'#9ccfd8',pr:'#2a273f',tones:{think:'#e0def4',sense:'#c4a7e7',act:'#9ccfd8',shell:'#ebbcba',delegate:'#908caa',say:'#f6c177'},glow:'rgba(156,207,216,.10)'}
};
const row=document.getElementById('row');
Object.keys(LOOKS).forEach(k=>{
  const lk=LOOKS[k];
  const zones=Object.keys(Z).map(z=>`<div class="z"><span style="color:${lk.tones[z]}">${names[z]}</span><div class="bar"><i style="width:${Math.max(3,Z[z]/Z.shell*100)}%;background:${lk.tones[z]}"></i></div><span class="n">${Z[z]}</span></div>`).join('');
  row.insertAdjacentHTML('beforeend',`<div class="frame"><div class="poster" style="background:radial-gradient(900px 520px at 85% 12%,${lk.glow},transparent),${lk.bg};--pi:${lk.pi};--pd:${lk.pd};--pa:${lk.pa};--pr:${lk.pr}">
  <div class="brand"><span>TAILSCODE</span><i>ONE TURN</i></div>
  <img src="${IMG[k]}" alt="">
  <div class="hero"><b>${tools}</b><span>tools in 8m 25s</span></div>
  <div class="sub"><u>+${dif[0]} −${dif[1]}</u> lines · 1 command failed, then passed · 2 notes</div>
  <div class="zones">${zones}</div>
  <div class="quote">Make a product demonstration using mock data but the real apps .mp4 i can share on twitter…</div>
  <div class="foot"><span>counted from the transcript</span><span>tailscode</span></div></div></div>`);
});
window.__heroReady=true;
</script></body></html>"""
Path(out).write_text(html)
print("built J", Path(out).stat().st_size // 1024, "KB")
