import json, sys, time, uuid, random, math, urllib.request, urllib.error, os, datetime

BASE = os.environ.get("COMFY", "http://100.91.211.44:8188")
HERE = os.path.dirname(os.path.abspath(__file__))
CAND = os.path.join(HERE, "cand")
LOG = os.path.join(HERE, "renders.jsonl")
CLIENT = "landing-pic-" + uuid.uuid4().hex[:8]

JOBS = [
    ("lighthouse", "a lighthouse on a cliff at dusk, waves breaking below, last light on the lamp room", "landscape"),
    ("aurora-cabin", "northern lights over a small log cabin beside a frozen lake, snow, stars, long exposure", "landscape"),
    ("sauna", "a red wooden sauna on a lake shore at blue hour, steam rising from the chimney, warm light in the window", "landscape"),
    ("cat-roof", "a cat asleep on a warm tiled roof, late afternoon light", "landscape"),
    ("station", "an old railway station platform in falling snow at dawn, a single yellow lamp", "landscape"),
    ("fox", "a red fox crossing a birch forest at first light, low mist", "landscape"),
    ("ramen", "a bowl of ramen with rising steam, shallow depth of field, moody kitchen light", "landscape"),
    ("paper-boats", "paper boats floating down a rain-wet street at night, neon reflections", "landscape"),
    ("greenhouse", "a tiny glowing greenhouse in a snowy field at night", "landscape"),
    ("cabin-interior", "a mountain cabin interior, wood stove, a cup of coffee on the table, snow falling past the window", "square"),
    ("portrait-fjord", "a narrow fjord seen from a rock ledge at sunrise, layered mountains", "portrait"),
]
RATIOS = {"square": (1, 1), "landscape": (3, 2), "portrait": (2, 3)}

def rnd32(v):
    return max(256, int(round(v / 32)) * 32)

def pixels(aspect, megapixels=2.0):
    r = RATIOS[aspect]; ratio = r[0] / r[1]; budget = megapixels * 1_000_000
    return rnd32(math.sqrt(budget * ratio)), rnd32(math.sqrt(budget / ratio))

def graph(prompt, w, h, seed, steps=25):
    return {
        "12": {"class_type": "UNETLoader", "inputs": {"unet_name": "qwen_image_2.1_int8_convrot.safetensors", "weight_dtype": "default"}},
        "61": {"class_type": "CLIPLoader", "inputs": {"clip_name": "qwen3vl_8b_int8_convrot.safetensors", "type": "qwen_image", "device": "default"}},
        "10": {"class_type": "VAELoader", "inputs": {"vae_name": "qwen_image_2.1_vae_bf16.safetensors"}},
        "8": {"class_type": "VAEDecode", "inputs": {"samples": ["65", 0], "vae": ["10", 0]}},
        "9": {"class_type": "SaveImage", "inputs": {"images": ["8", 0], "filename_prefix": "tailscode-landing"}},
        "66": {"class_type": "EmptyLatentImage", "inputs": {"width": w, "height": h, "batch_size": 1}},
        "68": {"class_type": "TextEncodeQwenImage21", "inputs": {"clip": ["61", 0], "prompt": prompt, "negative_prompt": "", "resolution": 1024}},
        "65": {"class_type": "KSampler", "inputs": {"model": ["12", 0], "positive": ["68", 0], "negative": ["68", 1], "latent_image": ["66", 0], "seed": seed, "steps": steps, "cfg": 1.0, "sampler_name": "euler", "scheduler": "simple", "denoise": 1.0}},
    }

def call(path, body=None, timeout=60):
    req = urllib.request.Request(BASE + path, data=None if body is None else json.dumps(body).encode(), headers={"Content-Type": "application/json"})
    return urllib.request.urlopen(req, timeout=timeout).read()

def render(name, prompt, aspect, seed, tag):
    w, h = pixels(aspect)
    g = graph(prompt, w, h, seed)
    t0 = time.time()
    started = datetime.datetime.now().astimezone().isoformat(timespec="seconds")
    try:
        r = json.loads(call("/prompt", {"prompt": g, "client_id": CLIENT}))
    except urllib.error.HTTPError as e:
        raise SystemExit(e.read().decode())
    pid = r["prompt_id"]
    while True:
        time.sleep(1.0)
        hist = json.loads(call("/history/" + pid))
        run = hist.get(pid)
        if run and run["status"]["status_str"] in ("success", "error"):
            break
    seconds = time.time() - t0
    if run["status"]["status_str"] != "success":
        raise SystemExit("render failed: " + json.dumps(run["status"])[:600])
    img = next(i for o in run["outputs"].values() for i in o.get("images", []))
    q = "filename=%s&type=%s&subfolder=%s" % (img["filename"], img["type"], img.get("subfolder", ""))
    data = urllib.request.urlopen(BASE + "/view?" + q, timeout=120).read()
    out = os.path.join(CAND, "%s-%s.png" % (name, tag))
    open(out, "wb").write(data)
    rec = dict(name=name, file=out, prompt=prompt, engine="Qwen", engineModel="qwen_image_2.1_int8_convrot", width=w, height=h, seed=seed, steps=25,
               seconds=round(seconds, 1), renderedAt=started, machineFile=img["filename"], tag=tag)
    open(LOG, "a").write(json.dumps(rec) + "\n")
    print(json.dumps(rec), flush=True)
    return rec

if __name__ == "__main__":
    names = sys.argv[1].split(",") if len(sys.argv) > 1 and sys.argv[1] != "all" else [j[0] for j in JOBS]
    tag = sys.argv[2] if len(sys.argv) > 2 else "a"
    seeds = [int(s) for s in sys.argv[3].split(",")] if len(sys.argv) > 3 else None
    for name, prompt, aspect in JOBS:
        if name not in names:
            continue
        seed = seeds.pop(0) if seeds else random.randint(0, 0xFFFFFFFF)
        render(name, prompt, aspect, seed, tag)
