import json,os,sys,base64
def blob(o): return {"__data": base64.b64encode(json.dumps(o,separators=(",",":")).encode()).decode()}
f=os.environ["XDG_RUNTIME_DIR"]+"/tailscode-dev/"+os.environ.get("DISP","87")+"/home/config/tailscode/ui.json"
port=os.environ.get("MOCK_PORT","8203")
d={
    "tailscode.compactTools": True,
    "tailscode.divider.sidebar": 305,
    "tailscode.divider.terminal": 675,
    "tailscode.divider.project": 1105,
    "tailscode.pane.terminal": False,
    "tailscode.scale.chrome": 1,
    "tailscode.scale.mono": 1,
    "tailscode.scale.prose": 1.0,
    "tailscode.scale.terminal": 1,
    "tailscode.theme": "suomi",
    "tailscode.appearance": "dark",
    "tailscode.window.height": 1080,
    "tailscode.window.width": 1920,
    "tailscode.window.maximized": False,
    "tailscode.image.endpoint": blob({"address":"http://arch:"+port}),
    "tailscode.forge.endpoint": blob({"host":"arch","port":int(port)}),
}
for kv in sys.argv[1:]:
    k,v=kv.split("=",1)
    if v=="DEL": d.pop(k,None)
    else: d[k]=json.loads(v)
os.makedirs(os.path.dirname(f),exist_ok=True)
json.dump(d,open(f,"w"))
print(d)
