import json, sys
from pathlib import Path
here = Path(__file__).parent
work = Path(sys.argv[1]); out = Path(sys.argv[2])
data = json.load(open(work / "sheet.json"))
css = (here / "base.css").read_text()
S = {
 "idle": ("Idle","idle","quiet","still","Nothing is happening. The head rests, the eye dim."),
 "settled": ("A settled turn","a turn that ended well","quiet","still","Wears no tone, so the eye shows who answered and how hard: Fable's hue, four bars."),
 "thinking": ("Thinking","thinking","live","breath 1.9 s","PLAN breathes."),
 "reading": ("Reading","usingTool(Read)","live","breath 1.9 s","SENSE breathes: the node being read is running."),
 "editing": ("Editing","usingTool(Edit)","live","breath 1.9 s","ACT breathes."),
 "running": ("Running","usingTool(Bash)","live","breath 1.9 s","SHELL breathes."),
 "writing": ("Writing","writing","live","breath 1.9 s","SAY breathes: the agent is writing its note or answer."),
 "delegating": ("Delegating","delegating","live","breath 1.9 s","DELEGATE breathes; a Task node can open a smaller head."),
 "background": ("Background work","inBackground","live","breath 1.9 s","The turn is over and work goes on: the eye breathes, one satellite circles the dome."),
 "approval": ("Needs approval","needsApproval","attention","heartbeat 1.6 s","The waiting tool beats twice; its zone and the eye turn attention."),
 "question": ("Needs an answer","needsAnswer","attention","heartbeat 1.6 s","The question beats in PLAN; the dock holds the options."),
 "stalled": ("Stalled","stalled","attention","still","Work the machine found stuck: attention, held still."),
 "retrying": ("Retrying","retrying","attention","sweep 1.05 s","A band of light crosses the dome."),
 "compacting": ("Compacting","compacting","attention","sweep + crunch","The galaxies draw in while the band sweeps; the ribs drop to what was kept."),
 "queued": ("Queued","queued(n)","quiet","still","Held still and dim until its turn."),
 "connecting": ("Connecting","connecting","quiet","sweep 1.05 s","A quiet band crosses the dome."),
 "reconnecting": ("Reconnecting","reconnecting","attention","sweep 1.05 s","An attention band while the line comes back."),
 "failed": ("Failed","failed · also a quota wall","danger","still","The eye and the failing zone hold danger; everything else steps back."),
 "stopped": ("Stopped or interrupted","no face in the app","quiet","still","A record, not a fault: neutral, the last node dashed. The card carries the news."),
 "offline": ("Offline","offline","quiet","still","The machine is down: the head is dark.")
}
G = [("WORKING",["thinking","reading","editing","running","writing","delegating","background"]),("NEEDS YOU",["approval","question","stalled","retrying","compacting","reconnecting"]),("QUIET",["idle","settled","queued","connecting"]),("ENDED",["failed","stopped","offline"])]
tone = {"live":"#39ff88","attention":"#f2c14e","danger":"#ff5c7a","quiet":"#6f8f7d"}
def tile(i):
    n,k,t,m,s = S[i]
    return f'<figure class="tile"><img src="{data["states"][i]}" alt="{n}"><figcaption><b>{n}</b><span class="tn" style="background:{tone[t]}"></span><code>{k}</code><em>{t} · {m}</em><span>{s}</span></figcaption></figure>'
def crop(i, cap):
    return f'<figure class="crop"><img src="{data["crops"][i]}" alt="{cap}"><figcaption>{cap}</figcaption></figure>'
sections = "".join(f'<h2>{g}</h2><div class="grid">{"".join(tile(i) for i in ids)}</div>' for g, ids in G)
meters = (
 '<h2>CONTEXT FILL · THE NECK RIBS</h2><div class="strip">' + crop("ctx42","42% · quiet") + crop("ctx65","65% · attention (from 50%)") + crop("ctx90","92% · danger (from 80%)") + '</div>'
 '<h2>EFFORT · THE VISOR BARS</h2><div class="strip">' + crop("eff1","low · one bar") + crop("eff3","high · three bars") + crop("eff5","max · five bars") + crop("effU","ultracode · all five, rainbow") + crop("effS","the server decides · hollow") + '</div>'
 '<h2>VOICE CALL · THE EAR</h2><div class="strip">' + crop("callL","listening · breathes") + crop("callH","hearing · lit steady") + crop("callD","degraded · danger, still") + '</div>'
)
html = f"""<!doctype html>
<html lang="en" data-theme="dark"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>H · State sheet</title>
<style>{css}
.page{{max-width:1180px;margin:0 auto;padding:18px 16px 44px}}
.eyebrow{{letter-spacing:.2em;font-size:11px;color:var(--accent)}}
h1{{font-size:22px;color:var(--ink);margin:6px 0 4px;font-weight:600}}
.lead{{color:var(--ink2);max-width:92ch;margin:0 0 18px}}
h2{{font-size:11px;letter-spacing:.2em;color:var(--ink3);margin:26px 0 10px;font-weight:600}}
.grid{{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:14px}}
.tile{{margin:0;border:1px solid var(--rule);border-radius:14px;overflow:hidden;background:var(--panel)}}
.tile img{{display:block;width:100%;height:auto}}
.tile figcaption{{padding:10px 12px 12px;display:grid;gap:3px;font-size:12px;color:var(--ink2)}}
.tile figcaption b{{color:var(--ink);font-size:13px}}
.tile .tn{{display:inline-block;width:8px;height:8px;border-radius:50%;margin-left:8px}}
.tile code{{color:var(--ink3);font-size:11px}}
.tile em{{font-style:normal;color:var(--ink3);font-size:11px}}
.strip{{display:flex;flex-wrap:wrap;gap:14px}}
.crop{{margin:0;border:1px solid var(--rule);border-radius:12px;overflow:hidden;background:var(--panel)}}
.crop img{{display:block;max-height:150px;width:auto}}
.crop figcaption{{padding:7px 10px;font-size:11.5px;color:var(--ink2)}}
.legend{{margin-top:26px;border:1px solid var(--rule);border-radius:12px;padding:12px 14px;color:var(--ink2);font-size:12px;line-height:1.7}}
.legend b{{color:var(--ink)}}
@media (max-width:860px){{.grid{{grid-template-columns:1fr 1fr}}}}
@media (max-width:560px){{.grid{{grid-template-columns:1fr}}}}
</style></head><body><main class="page">
<div class="eyebrow">H · STATE SHEET</div>
<h1>Every state, on the head</h1>
<p class="lead">One sheet, captured from the real shader. Each state is an ActivityKind the app already has, so the head, the header's status line, the orb and Home's rows say the same thing. The tone is the eye and the active zone, the motion is the activity's own, and the zone that lights is the tool family the header names. Stillness is meaning: every still state is one frame.</p>
{sections}{meters}
<div class="legend"><b>Tone</b> live = the theme's accent · attention = warn · danger = danger · quiet = the muted ink. <b>Motion</b> breath 1.9 s (floor .34) · heartbeat 1.6 s, two beats · sweep 1.05 s · still. Reduced motion holds every state still in the same tone; the node glyph and the header's words still say it. <b>Context</b> attention at 50%, danger at 80%, an estimate (~) draws the ribs at half strength. <b>Effort</b> the five-bar meter from the model dial: a level lights its rank, a power lights all five in the rainbow, the server's choice is five hollow bars, and below low is one ember bar.</div>
</main><script>window.__heroReady=true</script></body></html>"""
Path(out).write_text(html)
print("built H", Path(out).stat().st_size // 1024, "KB")
