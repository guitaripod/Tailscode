Real renders the landing-page Studio shots are made from, produced on the arch ComfyUI with the app's own Qwen quality graph.

`manifest.json` lists every picture in shelf order with its prompt, engine, size, seed, steps and seconds; `render.py <names|all> <tag> [seeds]` reproduces them (seeds are recorded). The PNGs live outside git in `~/Dev/marketing-art/tailscode-studio/` (with `mock-output/studio/` ready for `scripts/mock-comfyui.py` and the spare shots the page does not use).

Reshoot: `scripts/shots-landing.sh` (iPhone), `scripts/landing-shots-mac.sh` (Mac), `scripts/landing-linux/reshoot.sh` (Linux, on arch), each taking the art folder through its documented environment variable.
