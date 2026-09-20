#!/usr/bin/env python3
"""A stand-in ComfyUI for screenshots and headless runs.

Serves a curated output folder as the machine's shelf (listing, thumbnails, ranged heads with
Last-Modified), answers the health and model probes, and paints on demand by replaying a
scripted render over a hand-rolled websocket — status, loaders, the sampler's steps, decode,
save — before handing back a prepared picture as the result.

    MOCK_OUTPUT=~/shots/output MOCK_PORT=8190 MOCK_RENDER_SECONDS=6 \
    MOCK_PAUSE_AT_STEP=14 MOCK_PAUSE_FROM_JOB=2 \
    MOCK_RESULTS="studio/a.png,studio/b.png" scripts/mock-comfyui.py

Point the harness at it with TAILSCODE_IMAGE_ENDPOINT=http://<host>:8190 (debug builds only);
a hostname rather than 127.0.0.1 is what makes the shelf read "On <machine>". Pictures live
under MOCK_OUTPUT/studio; MOCK_RESULTS names the file each successive job hands back;
MOCK_PAUSE_AT_STEP holds a job at that sampler step forever from MOCK_PAUSE_FROM_JOB on, which
is how a "painting" frame is captured. Needs Pillow for the thumbnails.
"""
import base64, hashlib, io, json, os, socket, struct, sys, threading, time, uuid, shutil
from email.utils import formatdate
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
OUTPUT = os.environ.get("MOCK_OUTPUT", os.path.join(HERE, "output"))
PORT = int(os.environ.get("MOCK_PORT", "8190"))
RENDER_SECONDS = float(os.environ.get("MOCK_RENDER_SECONDS", "30"))
PAUSE_AT = int(os.environ.get("MOCK_PAUSE_AT_STEP", "0"))
RESULTS = [r for r in os.environ.get("MOCK_RESULTS", "").split(",") if r]
PAUSE_FROM_JOB = int(os.environ.get("MOCK_PAUSE_FROM_JOB", "1"))
jobs = [0]

MODELS = {
    "UNETLoader": ("unet_name", ["flux-2-klein-4b.safetensors", "qwen_image_2.1_int8_convrot.safetensors"]),
    "CLIPLoader": ("clip_name", ["qwen_3_4b.safetensors", "qwen3vl_8b_int8_convrot.safetensors"]),
    "VAELoader": ("vae_name", ["qwen_image_2.1_vae_bf16.safetensors"]),
}

history = {}
sockets = []
lock = threading.Lock()

def listing():
    files = []
    for root, _, names in os.walk(OUTPUT):
        for n in names:
            if n.lower().endswith((".png", ".jpg", ".jpeg", ".webp")):
                p = os.path.join(root, n)
                files.append((os.path.getmtime(p), os.path.relpath(p, OUTPUT)))
    files.sort(reverse=True)
    return [f"{rel} [output]" for _, rel in files]

def broadcast(frame):
    data = json.dumps(frame).encode()
    header = bytes([0x81]) + (bytes([len(data)]) if len(data) < 126 else b"\x7e" + struct.pack(">H", len(data)))
    with lock:
        dead = []
        for s in sockets:
            try: s.sendall(header + data)
            except OSError: dead.append(s)
        for s in dead: sockets.remove(s)

def run_job(pid, graph):
    jobs[0] += 1
    job = jobs[0]
    sampler = next((k for k, v in graph.items() if v.get("class_type", "").startswith("KSampler")), "65")
    steps = int(graph.get(sampler, {}).get("inputs", {}).get("steps", 25))
    order = [k for k, v in graph.items() if v.get("class_type") in ("UNETLoader", "CLIPLoader", "VAELoader")]
    broadcast({"type": "status", "data": {"status": {"exec_info": {"queue_remaining": 1}}}})
    broadcast({"type": "execution_start", "data": {"prompt_id": pid}})
    for node in order:
        broadcast({"type": "executing", "data": {"prompt_id": pid, "node": node}})
        time.sleep(0.6)
    enc = next((k for k, v in graph.items() if "TextEncode" in v.get("class_type", "")), None)
    if enc:
        broadcast({"type": "executing", "data": {"prompt_id": pid, "node": enc}}); time.sleep(0.8)
    broadcast({"type": "executing", "data": {"prompt_id": pid, "node": sampler}})
    per = RENDER_SECONDS / steps
    for step in range(1, steps + 1):
        broadcast({"type": "progress", "data": {"prompt_id": pid, "node": sampler, "value": step, "max": steps}})
        if PAUSE_AT and job >= PAUSE_FROM_JOB and step >= PAUSE_AT:
            while True: time.sleep(3600)
        time.sleep(per)
    for cls in ("VAEDecode", "SaveImage"):
        node = next((k for k, v in graph.items() if v.get("class_type") == cls), None)
        if node:
            broadcast({"type": "executing", "data": {"prompt_id": pid, "node": node}}); time.sleep(0.5)
    src = RESULTS[job - 1] if job - 1 < len(RESULTS) else sorted(os.listdir(os.path.join(OUTPUT, "studio")))[0]
    name = f"tailscode-demo-new-{pid[:6]}_00001_.png"
    shutil.copy(os.path.join(OUTPUT, "studio", src), os.path.join(OUTPUT, "studio", name))
    os.utime(os.path.join(OUTPUT, "studio", name), None)
    history[pid] = {"status": {"status_str": "success", "completed": True, "messages": []},
                    "outputs": {"9": {"images": [{"filename": name, "subfolder": "studio", "type": "output"}]}}}
    broadcast({"type": "executing", "data": {"prompt_id": pid, "node": None}})
    broadcast({"type": "execution_success", "data": {"prompt_id": pid}})
    broadcast({"type": "status", "data": {"status": {"exec_info": {"queue_remaining": 0}}}})

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _json(self, obj, code=200):
        body = json.dumps(obj).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def do_GET(self):
        u = urlparse(self.path); q = parse_qs(u.query)
        if u.path == "/ws": return self.websocket(q)
        if u.path == "/system_stats": return self._json({"system": {"os": "linux", "comfyui_version": "0.36.0"}})
        if u.path.startswith("/object_info/"):
            node = u.path.rsplit("/", 1)[1]
            field, names = MODELS.get(node, ("name", []))
            return self._json({node: {"input": {"required": {field: [names]}}}})
        if u.path == "/queue": return self._json({"queue_running": [], "queue_pending": []})
        if u.path == "/internal/files/output": return self._json(listing())
        if u.path.startswith("/history/"):
            pid = u.path.rsplit("/", 1)[1]
            return self._json({pid: history[pid]} if pid in history else {})
        if u.path == "/view": return self.view(q)
        self.send_response(404); self.end_headers()
    def view(self, q):
        name = q.get("filename", [""])[0]; sub = q.get("subfolder", [""])[0]
        path = os.path.join(OUTPUT, sub, name)
        if not os.path.isfile(path): self.send_response(404); self.end_headers(); return
        mtime = os.path.getmtime(path)
        if q.get("preview"):
            im = Image.open(path).convert("RGB"); im.thumbnail((256, 256))
            buf = io.BytesIO(); im.save(buf, "JPEG", quality=85); body = buf.getvalue()
            self.send_response(200); self.send_header("Content-Type", "image/jpeg")
            self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body); return
        data = open(path, "rb").read()
        rng = self.headers.get("Range")
        if rng and rng.startswith("bytes="):
            a, b = rng[6:].split("-"); a = int(a); b = int(b) if b else len(data) - 1
            chunk = data[a:b + 1]
            self.send_response(206); self.send_header("Content-Type", "image/png")
            self.send_header("Content-Range", f"bytes {a}-{a+len(chunk)-1}/{len(data)}")
            self.send_header("Last-Modified", formatdate(mtime, usegmt=True))
            self.send_header("Content-Length", str(len(chunk))); self.end_headers(); self.wfile.write(chunk); return
        self.send_response(200); self.send_header("Content-Type", "image/png")
        self.send_header("Last-Modified", formatdate(mtime, usegmt=True))
        self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)
    def do_POST(self):
        u = urlparse(self.path)
        length = int(self.headers.get("Content-Length", "0")); body = self.rfile.read(length) if length else b""
        if u.path == "/prompt":
            graph = json.loads(body).get("prompt", {}); pid = str(uuid.uuid4())
            threading.Thread(target=run_job, args=(pid, graph), daemon=True).start()
            return self._json({"prompt_id": pid, "number": 1, "node_errors": {}})
        if u.path in ("/interrupt", "/queue"): self.send_response(200); self.end_headers(); return
        self.send_response(404); self.end_headers()
    def do_DELETE(self):
        self.send_response(200); self.end_headers()
    def websocket(self, q):
        key = self.headers.get("Sec-WebSocket-Key", "")
        accept = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
        self.send_response(101); self.send_header("Upgrade", "websocket"); self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", accept); self.end_headers()
        s = self.connection
        with lock: sockets.append(s)
        s.sendall(bytes([0x81, 0]) if False else b"")
        broadcast({"type": "status", "data": {"status": {"exec_info": {"queue_remaining": 0}}, "sid": "mock"}})
        try:
            while True:
                head = s.recv(2)
                if not head: break
                op = head[0] & 0x0F; ln = head[1] & 0x7F; masked = head[1] & 0x80
                if ln == 126: ln = struct.unpack(">H", s.recv(2))[0]
                elif ln == 127: ln = struct.unpack(">Q", s.recv(8))[0]
                mask = s.recv(4) if masked else b""
                payload = b""
                while len(payload) < ln: payload += s.recv(ln - len(payload))
                if op == 8: break
                if op == 9: s.sendall(bytes([0x8A, len(payload)]) + payload)
        except OSError: pass
        with lock:
            if s in sockets: sockets.remove(s)
        self.close_connection = True

if __name__ == "__main__":
    ThreadingHTTPServer.daemon_threads = True
    ThreadingHTTPServer(("0.0.0.0", PORT), H).serve_forever()
