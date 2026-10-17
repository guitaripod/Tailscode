import sys, json
from pathlib import Path

here = Path(__file__).parent
src = here.parent
assets = Path(sys.argv[1])
out = Path(sys.argv[2])
calls = sys.argv[3] if len(sys.argv) > 3 else None
pal = json.loads(assets.read_text().split("const PAL=")[1].rsplit(";", 1)[0])


def theme_css():
    css = []
    for k, p in pal.items():
        light = p["dark"] == "0"
        css.append(
            f'[data-theme="{k}"]{{--bg:{p["canvas"]};--raised:{p["raised"]};--rule:{p["rule"]};--ink:{p["text"]};--ink2:{p["textDim"]};'
            f'--accent:{p["accent"]};--info:{p["info"]};--special:{p["special"]};--warn:{p["warn"]};--danger:{p["danger"]};--code:{p["codeBg"]};'
            f'--lead-think:{p["text"]};--lead-sense:{p["info"]};--lead-act:{p["accent"]};--lead-shell:{p["special"]};--lead-delegate:{p["textDim"]};'
            f'--lead-say:color-mix(in srgb,{p["accent"]} 45%,{p["info"]})}}'
        )
        if light:
            m = lambda c: f"color-mix(in srgb,{c} 55%,#fff)"
            css.append(
                f'[data-theme="{k}"] .stage,[data-theme="{k}"] .pic,[data-theme="{k}"] .t-trav{{--accent:{m(p["accent"])};--info:{m(p["info"])};--special:{m(p["special"])};--warn:{m(p["warn"])};--danger:{m(p["danger"])};'
                f'--ink:#e6e1ee;--ink2:#b8b2c9;--ink3:#8d87a3;--panel:#0a1210;--bg:#0a1210;--rule2:#4a5b57;--rule:#26332f;'
                f'--t-think:var(--ink);--t-sense:var(--info);--t-act:var(--accent);--t-shell:var(--special);--t-delegate:var(--ink2);'
                f'--t-say:color-mix(in srgb,var(--accent) 45%,var(--info))}}'
            )
    css.append(".leader.f-think{--t:var(--lead-think)}.leader.f-sense{--t:var(--lead-sense)}.leader.f-act{--t:var(--lead-act)}.leader.f-shell{--t:var(--lead-shell)}.leader.f-delegate{--t:var(--lead-delegate)}.leader.f-say{--t:var(--lead-say)}")
    return "\n".join(css)


def read(p):
    return Path(p).read_text()


html = f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>K · Readout</title>
<style>{read(src / 'base.css')}
{read(here / 'readout.css')}
{theme_css()}</style></head>
<body><div class="board" id="board"><h1>NEURAL TRACE · THE CARD, THE DOCKED STAGE AND THE READOUT</h1></div>
<script>{read(assets)}</script>
<script>{read(src / 'engine.js')}</script>
<script>{read(here / 'fixtures.js')}</script>
<script>{read(here / 'readout.js')}</script>
<script>{read(here / 'stage.js')}</script>
<script>{read(here / 'transition.js')}</script>
<script>{read(here / 'brain.js')}</script>
<script>{read(here / 'transition2.js')}</script>
<script>{read(here / 'page2.js')}</script>
<script>{read(here / 'verdict.js')}</script>
<script>{read(here / 'account.js')}</script>
<script>{read(here / 'account5.js')}</script>
<script>{read(here / 'brain4.js')}</script>
<script>{read(here / 'page4.js')}</script>
<script>{read(here / 'page5.js')}</script>
<script>{read(here / 'live6.js')}</script>
<script>{read(here / 'page6.js')}</script>
<script>{read(here / 'page.js')}</script>
<script>{read(here / 'boot.js')}</script>
</body></html>"""
out.write_text(html)
def variant(name, only, title):
    v = html.replace("<title>K · Readout</title>", "<title>" + title + "</title>").replace("<script>(function () {\n  const q", "<script>window.__only='" + only + "';(function () {\n  const q")
    (out.parent / name).write_text(v)
variant("M-live.html", "W2", "W · The move, live")
variant("O-live.html", "O3", "O · Browse, live")
variant("T-live.html", "T8", "T · The account, live")
print("wrote", out, round(len(html) / 1e6, 2), "MB")
