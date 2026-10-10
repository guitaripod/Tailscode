#!/usr/bin/env python3
"""A stand-in ComfyUI for screenshots and headless runs, for every client's image and video studio.

Serves a curated output folder as the machine's shelf (listing, thumbnails, ranged heads with
Last-Modified), answers the health and model probes, and paints on demand by replaying a
scripted render over a hand-rolled websocket, then hands back a prepared picture as the result.
A render sends what a real ComfyUI sends: status, execution_start, an executing frame per
loader and node, a progress frame per sampler step, and after each step a binary PREVIEW_IMAGE
frame (8-byte header, big-endian uint32 event 1 then uint32 format 1 = JPEG, then the JPEG
bytes) so the studios can draw a live sketch. The sketch is the result blurred and sharpened
toward itself as the steps advance, 256 px wide at the result's aspect. Every response is
HTTP/1.1 with a Content-Length, because URLSession refuses the websocket handshake of anything
older. A video studio's render is answered with the same picture; there is no encoder here.

    MOCK_OUTPUT=~/shots/output MOCK_PORT=8190 MOCK_RENDER_SECONDS=6 \\
    MOCK_PAUSE_AT_STEP=14 MOCK_PAUSE_FROM_JOB=2 \\
    MOCK_RESULTS="studio/a.png,b.png" scripts/mock-comfyui.py

Environment:
    MOCK_OUTPUT            the output folder to serve (default: ./output beside this script).
    MOCK_PORT              port to listen on (default 8190).
    MOCK_RENDER_SECONDS    how long the sampler's steps take in all (default 30).
    MOCK_PAUSE_AT_STEP     hold a job at this sampler step until it is interrupted (default off).
    MOCK_PAUSE_FROM_JOB    the first job number MOCK_PAUSE_AT_STEP applies to (default 1).
    MOCK_RESULTS_FROM      a folder outside MOCK_OUTPUT that MOCK_RESULTS entries are also looked
                           for in, so a picture can be handed back by a render without sitting on
                           the machine's shelf beforehand (default off).
    MOCK_RESULTS           comma-separated pictures the successive jobs hand back, wrapping
                           around after the last. Each entry is a bare filename or a path
                           relative to MOCK_OUTPUT (studio/a.png); a bare name is looked for in
                           MOCK_OUTPUT and then in MOCK_OUTPUT/studio. Unset, the pictures
                           under MOCK_OUTPUT/studio (or MOCK_OUTPUT) are used in name order.

The startup banner names every file that will be served and every entry that was not found.
Each finished job copies its picture to MOCK_OUTPUT/studio as tailscode-demo-new-<id>, which
is how it appears on the shelf. Point the harness at it with
TAILSCODE_IMAGE_ENDPOINT=http://<host>:8190 (debug builds only); a hostname rather than
127.0.0.1 is what makes the shelf read "On <machine>". Every websocket client hears every job.
Needs Pillow.
"""
import base64, hashlib, io, json, mimetypes, os, shutil, struct, sys, threading, time, uuid
from email.utils import formatdate
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs
from PIL import Image, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
OUTPUT = os.path.abspath(os.path.expanduser(os.environ.get("MOCK_OUTPUT", os.path.join(HERE, "output"))))
PORT = int(os.environ.get("MOCK_PORT", "8190"))
RENDER_SECONDS = float(os.environ.get("MOCK_RENDER_SECONDS", "30"))
PAUSE_AT = int(os.environ.get("MOCK_PAUSE_AT_STEP", "0"))
PAUSE_FROM_JOB = int(os.environ.get("MOCK_PAUSE_FROM_JOB", "1"))
RESULTS_FROM = os.path.abspath(os.path.expanduser(os.environ["MOCK_RESULTS_FROM"])) if os.environ.get("MOCK_RESULTS_FROM") else None
RESULT_NAMES = [r.strip() for r in os.environ.get("MOCK_RESULTS", "").split(",") if r.strip()]
IMAGE_EXTENSIONS = (".png", ".jpg", ".jpeg", ".webp")
GENERATED_PREFIX = "tailscode-demo-new-"
SKETCH_WIDTH = 256
PREVIEW_IMAGE = 1
FORMAT_JPEG = 1
WEBSOCKET_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

MODELS = {
    "UNETLoader": ("unet_name", ["flux-2-klein-4b.safetensors", "qwen_image_2.1_int8_convrot.safetensors"]),
    "CLIPLoader": ("clip_name", ["qwen_3_4b.safetensors", "qwen3vl_8b_int8_convrot.safetensors"]),
    "VAELoader": ("vae_name", ["qwen_image_2.1_vae_bf16.safetensors"]),
}

jobs = [0]
running = {}
history = {}
sockets = []
interrupts = {}
lock = threading.Lock()
results = []

def is_picture(name):
    return name.lower().endswith(IMAGE_EXTENSIONS)

def pictures_in(folder):
    if not os.path.isdir(folder): return []
    return sorted(os.path.join(folder, n) for n in os.listdir(folder)
                  if is_picture(n) and not n.startswith(GENERATED_PREFIX) and os.path.isfile(os.path.join(folder, n)))

def resolve(entry):
    """The file a MOCK_RESULTS entry names: relative to MOCK_OUTPUT, or a bare name under studio/."""
    for candidate in (os.path.join(OUTPUT, entry), os.path.join(OUTPUT, "studio", entry)):
        candidate = os.path.normpath(candidate)
        if candidate.startswith(OUTPUT + os.sep) and os.path.isfile(candidate): return candidate
    if RESULTS_FROM:
        candidate = os.path.normpath(os.path.join(RESULTS_FROM, entry))
        if candidate.startswith(RESULTS_FROM + os.sep) and os.path.isfile(candidate): return candidate
    return None

def choose_results():
    """Resolves MOCK_RESULTS, or falls back to the folder's own pictures; returns (files, missing)."""
    if RESULT_NAMES:
        found = [(n, resolve(n)) for n in RESULT_NAMES]
        return [p for _, p in found if p], [n for n, p in found if not p]
    return (pictures_in(os.path.join(OUTPUT, "studio")) or pictures_in(OUTPUT)), []

def banner(missing):
    print(f"mock-comfyui: http://0.0.0.0:{PORT}  output={OUTPUT}", flush=True)
    print(f"mock-comfyui: render {RENDER_SECONDS:g}s per job"
          + (f", paused at step {PAUSE_AT} from job {PAUSE_FROM_JOB}" if PAUSE_AT else ""), flush=True)
    origin = "MOCK_RESULTS" if RESULT_NAMES else "the output folder"
    print(f"mock-comfyui: jobs hand back, in turn and wrapping around ({origin}):", flush=True)
    for i, p in enumerate(results, 1): print(f"  {i}. {p if RESULTS_FROM and p.startswith(RESULTS_FROM) else os.path.relpath(p, OUTPUT)}", flush=True)
    for n in missing:
        print(f"  !  MOCK_RESULTS entry not found, skipped: {n} (looked in {OUTPUT} and {os.path.join(OUTPUT, 'studio')})",
              file=sys.stderr, flush=True)

def listing():
    files = []
    for root, _, names in os.walk(OUTPUT):
        for n in names:
            if is_picture(n):
                p = os.path.join(root, n)
                files.append((os.path.getmtime(p), os.path.relpath(p, OUTPUT)))
    files.sort(reverse=True)
    return [f"{rel} [output]" for _, rel in files]

def ws_frame(opcode, payload):
    n = len(payload)
    if n < 126: head = bytes([0x80 | opcode, n])
    elif n < 65536: head = bytes([0x80 | opcode, 126]) + struct.pack(">H", n)
    else: head = bytes([0x80 | opcode, 127]) + struct.pack(">Q", n)
    return head + payload

def send_all(frame):
    with lock:
        dead = []
        for s in sockets:
            try: s.sendall(frame)
            except OSError: dead.append(s)
        for s in dead: sockets.remove(s)

def broadcast(frame):
    send_all(ws_frame(0x1, json.dumps(frame).encode()))

def broadcast_preview(jpeg):
    send_all(ws_frame(0x2, struct.pack(">II", PREVIEW_IMAGE, FORMAT_JPEG) + jpeg))

def sketch_stages(path):
    """The result at SKETCH_WIDTH and a heavily blurred copy of it, for blending between."""
    final = Image.open(path).convert("RGB")
    height = max(1, round(final.height * SKETCH_WIDTH / final.width))
    final = final.resize((SKETCH_WIDTH, height), Image.LANCZOS)
    return final.filter(ImageFilter.GaussianBlur(SKETCH_WIDTH / 14)), final

def sketch_jpeg(stages, step, steps):
    """The sketch after `step` of `steps`: the blurred picture eased toward the final one."""
    blurred, final = stages
    t = step / steps
    eased = t * t * (3 - 2 * t)
    buf = io.BytesIO()
    Image.blend(blurred, final, eased).save(buf, "JPEG", quality=72)
    return buf.getvalue()

def node_named(graph, *classes):
    return next((k for k, v in graph.items() if v.get("class_type") in classes), None)

def step_count(node):
    """How many steps a sampling-ish node runs: its steps input, or the length of its sigma list."""
    inputs = node.get("inputs", {})
    if isinstance(inputs.get("steps"), int): return inputs["steps"]
    sigmas = inputs.get("sigmas")
    if isinstance(sigmas, str):
        values = [v for v in sigmas.replace(",", " ").split() if v]
        if len(values) > 1: return len(values) - 1
    return None

def find_sampler(graph):
    """The node the steps are reported against and how many there are; a graph naming neither gets 25."""
    for k, v in graph.items():
        if v.get("class_type", "").startswith(("KSampler", "SamplerCustom")) and isinstance(v.get("inputs", {}).get("steps"), int):
            return k, v["inputs"]["steps"]
    for k, v in graph.items():
        n = step_count(v)
        if n: return k, n
    return next((k for k, v in graph.items() if "Sampler" in v.get("class_type", "")), "65"), 25

def wait_or_interrupted(pid, seconds):
    return interrupts[pid].wait(seconds)

def run_job(pid, number, graph):
    source = results[(number - 1) % len(results)]
    sampler, steps = find_sampler(graph)
    steps = max(1, steps)
    save = node_named(graph, "SaveImage", "SaveVideo", "SaveAnimatedWEBP") or "9"
    loaders = [k for k, v in graph.items() if v.get("class_type") in ("UNETLoader", "CLIPLoader", "VAELoader")]
    stages = sketch_stages(source)
    with lock: running[pid] = number
    broadcast({"type": "status", "data": {"status": {"exec_info": {"queue_remaining": len(running)}}}})
    broadcast({"type": "execution_start", "data": {"prompt_id": pid}})
    interrupted = False

    def stop_here():
        nonlocal interrupted
        interrupted = True
        broadcast({"type": "execution_interrupted", "data": {"prompt_id": pid, "node_id": sampler, "node_type": "KSampler", "executed": []}})

    for node in loaders:
        broadcast({"type": "executing", "data": {"prompt_id": pid, "node": node}})
        if wait_or_interrupted(pid, 0.6): stop_here(); break
    enc = next((k for k, v in graph.items() if "TextEncode" in v.get("class_type", "")), None)
    if not interrupted and enc:
        broadcast({"type": "executing", "data": {"prompt_id": pid, "node": enc}})
        if wait_or_interrupted(pid, 0.8): stop_here()
    if not interrupted:
        broadcast({"type": "executing", "data": {"prompt_id": pid, "node": sampler}})
        per = RENDER_SECONDS / steps
        for step in range(1, steps + 1):
            broadcast({"type": "progress", "data": {"prompt_id": pid, "node": sampler, "value": step, "max": steps}})
            broadcast_preview(sketch_jpeg(stages, step, steps))
            if PAUSE_AT and number >= PAUSE_FROM_JOB and step >= PAUSE_AT:
                if interrupts[pid].wait(): stop_here(); break
            if wait_or_interrupted(pid, per): stop_here(); break
    if not interrupted:
        for cls in ("VAEDecode", "SaveImage"):
            node = node_named(graph, cls)
            if node:
                broadcast({"type": "executing", "data": {"prompt_id": pid, "node": node}})
                if wait_or_interrupted(pid, 0.5): stop_here(); break
    if interrupted:
        history[pid] = {"status": {"status_str": "error", "completed": False,
                                   "messages": [["execution_interrupted", {"prompt_id": pid}]]}, "outputs": {}}
    else:
        os.makedirs(os.path.join(OUTPUT, "studio"), exist_ok=True)
        name = f"{GENERATED_PREFIX}{pid[:6]}_00001_{os.path.splitext(source)[1].lower()}"
        shutil.copy(source, os.path.join(OUTPUT, "studio", name))
        os.utime(os.path.join(OUTPUT, "studio", name), None)
        image = {"filename": name, "subfolder": "studio", "type": "output"}
        history[pid] = {"status": {"status_str": "success", "completed": True, "messages": []},
                        "outputs": {save: {"images": [image]}}}
        broadcast({"type": "executed", "data": {"prompt_id": pid, "node": save, "output": {"images": [image]}}})
        broadcast({"type": "executing", "data": {"prompt_id": pid, "node": None}})
        broadcast({"type": "execution_success", "data": {"prompt_id": pid}})
    with lock: running.pop(pid, None)
    interrupts.pop(pid, None)
    broadcast({"type": "status", "data": {"status": {"exec_info": {"queue_remaining": len(running)}}}})

class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a): pass

    def _send(self, code, body=b"", ctype=None, headers=()):
        self.send_response(code)
        if ctype: self.send_header("Content-Type", ctype)
        for k, v in headers: self.send_header(k, v)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body and self.command != "HEAD": self.wfile.write(body)

    def _json(self, obj, code=200):
        self._send(code, json.dumps(obj).encode(), "application/json")

    def do_GET(self):
        u = urlparse(self.path); q = parse_qs(u.query)
        if u.path == "/ws": return self.websocket(q)
        if u.path == "/system_stats": return self._json({"system": {"os": "linux", "comfyui_version": "0.36.0"}, "devices": []})
        if u.path == "/object_info":
            return self._json({n: {"input": {"required": {f: [names]}}} for n, (f, names) in MODELS.items()})
        if u.path.startswith("/object_info/"):
            node = u.path.rsplit("/", 1)[1]
            field, names = MODELS.get(node, ("name", []))
            return self._json({node: {"input": {"required": {field: [names]}}}})
        if u.path == "/queue":
            with lock: live = sorted(running.items(), key=lambda kv: kv[1])
            return self._json({"queue_running": [[number, pid, {}, {}, []] for pid, number in live], "queue_pending": []})
        if u.path == "/internal/files/output": return self._json(listing())
        if u.path == "/history": return self._json(history)
        if u.path.startswith("/history/"):
            pid = u.path.rsplit("/", 1)[1]
            return self._json({pid: history[pid]} if pid in history else {})
        if u.path == "/view": return self.view(q)
        self._send(404)

    do_HEAD = do_GET

    def view(self, q):
        name = q.get("filename", [""])[0]; sub = q.get("subfolder", [""])[0]
        path = os.path.normpath(os.path.join(OUTPUT, sub, name))
        if not path.startswith(OUTPUT + os.sep) or not os.path.isfile(path): return self._send(404)
        mtime = os.path.getmtime(path)
        if q.get("preview"):
            im = Image.open(path).convert("RGB"); im.thumbnail((256, 256))
            buf = io.BytesIO(); im.save(buf, "JPEG", quality=85)
            return self._send(200, buf.getvalue(), "image/jpeg")
        with open(path, "rb") as f: data = f.read()
        ctype = mimetypes.guess_type(path)[0] or "application/octet-stream"
        modified = ("Last-Modified", formatdate(mtime, usegmt=True))
        rng = self.headers.get("Range")
        if rng and rng.startswith("bytes="):
            a, b = rng[6:].split("-"); a = int(a); b = int(b) if b else len(data) - 1
            chunk = data[a:b + 1]
            return self._send(206, chunk, ctype, [("Content-Range", f"bytes {a}-{a + len(chunk) - 1}/{len(data)}"), modified])
        self._send(200, data, ctype, [modified])

    def do_POST(self):
        u = urlparse(self.path)
        length = int(self.headers.get("Content-Length", "0")); body = self.rfile.read(length) if length else b""
        if u.path == "/prompt":
            try: graph = json.loads(body).get("prompt", {})
            except ValueError: return self._json({"error": "bad json"}, 400)
            pid = str(uuid.uuid4())
            with lock:
                jobs[0] += 1; number = jobs[0]
            interrupts[pid] = threading.Event()
            threading.Thread(target=run_job, args=(pid, number, graph), daemon=True).start()
            return self._json({"prompt_id": pid, "number": number, "node_errors": {}})
        if u.path == "/interrupt":
            for event in list(interrupts.values()): event.set()
            return self._send(200)
        if u.path == "/queue": return self._send(200)
        self._send(404)

    def do_DELETE(self):
        self._send(200)

    def read_frame(self):
        """One client frame as (opcode, unmasked payload), or None when the peer is gone."""
        head = self.rfile.read(2)
        if len(head) < 2: return None
        op = head[0] & 0x0F; ln = head[1] & 0x7F; masked = head[1] & 0x80
        if ln == 126: ln = struct.unpack(">H", self.rfile.read(2))[0]
        elif ln == 127: ln = struct.unpack(">Q", self.rfile.read(8))[0]
        mask = self.rfile.read(4) if masked else b""
        payload = self.rfile.read(ln)
        if len(payload) < ln: return None
        if masked: payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        return op, payload

    def websocket(self, q):
        key = self.headers.get("Sec-WebSocket-Key", "")
        accept = base64.b64encode(hashlib.sha1((key + WEBSOCKET_GUID).encode()).digest()).decode()
        self.send_response(101); self.send_header("Upgrade", "websocket"); self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", accept); self.end_headers()
        s = self.connection
        with lock: sockets.append(s)
        sid = q.get("clientId", ["mock"])[0]
        with lock:
            try: s.sendall(ws_frame(0x1, json.dumps({"type": "status", "data": {"status": {"exec_info": {"queue_remaining": len(running)}}, "sid": sid}}).encode()))
            except OSError: pass
        try:
            while True:
                frame = self.read_frame()
                if frame is None: break
                op, payload = frame
                if op == 8: break
                if op == 9:
                    with lock: s.sendall(ws_frame(0xA, payload))
        except OSError: pass
        with lock:
            if s in sockets: sockets.remove(s)
        self.close_connection = True

if __name__ == "__main__":
    results, missing = choose_results()
    banner(missing)
    if not results:
        sys.exit("mock-comfyui: no pictures to serve; put a .png in MOCK_OUTPUT/studio or fix MOCK_RESULTS")
    ThreadingHTTPServer.daemon_threads = True
    ThreadingHTTPServer(("0.0.0.0", PORT), H).serve_forever()
