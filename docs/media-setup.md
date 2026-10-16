# Pictures and video: the machine that makes them

Tailscode never renders on the phone or the laptop. One machine on your tailnet runs ComfyUI with a
graphics card, and every client points at it. This is the recipe for a stranger to build that machine,
every file it needs with the place it was verified, and what the app checks before it lets you press
Render.

Verified 2026-10-16 against Hugging Face and the ComfyUI repository. `scripts/media-setup.sh` performs
the recipe; its real run is **unverified** (only `--dry-run` and `shellcheck` were run, because the
machine it was written on has other jobs and limited disk). Everything below that says "verified" was
read from the source named next to it.

## What you need

| Need | Why |
| --- | --- |
| Linux with an NVIDIA card and its driver | the install script and the CUDA build of torch target it; macOS and AMD are not covered here |
| Tailscale, signed in to the same tailnet as your devices | the app only talks to machines on the tailnet |
| About 123 GB for every model, plus about 12 GB for the environment | the video lane is 71.1 GB, the picture engines 52 GB; you can install one lane only |
| Video memory | the video lane peaked at about 72 GB on the author's 96 GB card (5 s, 1280 by 704, 24 fps, distilled bf16); below that ComfyUI offloads to system memory and may be slow or fail. Nothing smaller was measured, and the picture engines were not measured at all |
| A Hugging Face account | two of the three repositories are gated behind a licence you accept in a browser |

## The recipe

```
scripts/media-setup.sh --dry-run          read every action first
scripts/media-setup.sh                    install into ~/comfyui
scripts/media-setup.sh --only images      pictures only
scripts/media-setup.sh --only video       video only
```

By hand, the same steps:

1. **ComfyUI at a pinned release.** `git clone https://github.com/Comfy-Org/ComfyUI.git`, then
   `git checkout --detach b53f77a74e21091cbdebfdf7b85fc80326932646` (tag `v0.41.2`, ComfyUI 0.41.2,
   GPL-3.0). Both `Comfy-Org/ComfyUI` and `comfyanonymous/ComfyUI` name that commit for the tag. The
   official manual install (docs.comfy.org/installation/manual_install, the README) is: a Python
   environment (the README calls 3.13 the best supported, 3.12 the fallback), a clone, torch from the
   CUDA index, `pip install -r requirements.txt`, `python main.py`. The script uses a venv instead of
   conda and the index the README gives for NVIDIA cards,
   `pip install torch torchvision torchaudio --extra-index-url https://download.pytorch.org/whl/cu130`.
2. **No custom nodes.** Every node class the app submits is part of ComfyUI itself; see the table
   below. Nothing from ComfyUI-Manager or any node pack is needed, and the app never installs one.
3. **The models**, below, into `ComfyUI/models/<folder>/`. `hf download <repo> --revision <sha> <paths>
   --local-dir ComfyUI/models` puts each file in the right folder because the repositories use ComfyUI's
   folder names as their paths. `pip install -U "huggingface_hub[cli]"` provides `hf`; run
   `hf auth login` once, after accepting the two licences. An interrupted download resumes when the
   command is run again.
4. **Start it where the app can reach it, and nowhere else.**

   ```
   cd ComfyUI && ../venv/bin/python main.py --listen "127.0.0.1,$(tailscale ip -4)" --port 8188
   ```

   ComfyUI listens on 127.0.0.1 unless told otherwise. `--listen` takes a list of addresses split on
   commas (`127.2.2.2,127.3.3.3` in its own help, verified in `comfy/cli_args.py` and `server.py` at the
   pinned tag), and with no argument it means every interface, `0.0.0.0,::`. ComfyUI has no sign-in of
   its own, so binding every interface publishes an unauthenticated render queue to every network the
   machine is on; the recipe binds loopback and the tailnet address only. One trap, read from the same
   source: an empty entry in the list (what `$(tailscale ip -4)` becomes on a machine where Tailscale
   is down or absent, `127.0.0.1,`) is handed to the socket layer as an empty host, which listens on
   every interface. So the command the app copies reads the address first and starts nothing without
   one:

   ```
   ts=$(tailscale ip -4 | head -n 1); if [ -n "$ts" ]; then python main.py --listen "127.0.0.1,$ts" --port 8188; else echo "Tailscale gave no address, so ComfyUI was not started"; fi
   ```

   `scripts/media-setup.sh` prints the same bind with the address filled in, and falls back to loopback
   only, never to `0.0.0.0`, when Tailscale gives none. The binding is IPv4; a client that resolves the
   machine's name to its IPv6 tailnet address first would not reach it, which was equally true of the
   `0.0.0.0` this replaces and was not tested here.
5. Open Video or Images in Tailscode. It guesses this machine from the agent server's address, asks it
   silently and shows the checklist below.

## Node classes

All 36 classes the video graph and the three picture graphs submit are defined in ComfyUI 0.41.2
(`comfy_extras/` or `nodes.py`), verified by reading the source at that tag. A test holds the catalog to
the graphs the code builds, so this list cannot drift from what is sent.

| Lane | First ComfyUI that has every class | Classes outside the basic loaders and samplers |
| --- | --- | --- |
| Video, LTX-2.5 distilled | 0.33.0 (classes only; that LTX-2.5's own loader support exists in 0.33.0 was not checked) | `LTXVConditioning`, `EmptyLTXVLatentVideo`, `LTXVConcatAVLatent`, `LTXVSeparateAVLatent`, `LTXVDualCFGGuider`, `LTXVPreprocess`, `LTXVImgToVideoInplace` (`nodes_lt.py`); `LTXVEmptyLatentAudio`, `LTXVAudioVAEDecode` (`nodes_lt_audio.py`); `LTXVLatentUpsampler` (`nodes_lt_upsampler.py`); `LatentUpscaleModelLoader` (`nodes_hunyuan.py`); `CreateVideo`, `SaveVideo`, `LoadVideo`, `GetVideoComponents` (`nodes_video.py`); `ImageFromBatch` (`nodes_images.py`); `RandomNoise`, `KSamplerSelect`, `ManualSigmas`, `SamplerCustomAdvanced` (`nodes_custom_sampler.py`) |
| Picture, Qwen Quality and Turbo | 0.37.0 (0.36.x lacks them) | `TextEncodeQwenImage21`, `QwenImage21Cache` (`nodes_qwen.py`); Turbo also `SamplerCustom`, `KSamplerSelect`, `ManualSigmas` |
| Picture, Klein | 0.41.0 (`ReferenceMultiLatent`, and the `flux3` text-encoder type, are not in 0.40) | `EmptyFlux2LatentImage` (`nodes_flux.py`), `ReferenceMultiLatent` (`nodes_edit_model.py`), `ConditioningZeroOut` |

The rest (`UNETLoader`, `CLIPLoader`, `VAELoader`, `CLIPTextEncode`, `KSampler`, `VAEDecode`,
`VAEDecodeTiled`, `EmptyLatentImage`, `LoadImage`, `SaveImage`) are in `nodes.py` of every release.

## Model files

Sizes are bytes from the repository's file listing; every command was also run with
`hf download --dry-run`, which printed the same sizes without downloading. Revisions are the commits
the listing was read at.

| Role | File (folder) | Bytes | Repository, revision | Licence | Gated |
| --- | --- | ---: | --- | --- | --- |
| Video model | `ltx-2.5-22b-distilled-transformer-bf16.safetensors` (`diffusion_models`) | 42,018,190,584 | [Lightricks/LTX-2.5](https://huggingface.co/Lightricks/LTX-2.5) `49b093a39c19` | ltx-2.x-community-license-agreement ([text](https://github.com/Lightricks/LTX-2/blob/main/LICENSE-2_x), not read) | yes, automatic once accepted |
| Video text encoder | `gemma4-12b-with-proj-ltx-2.5-bf16.safetensors` (`text_encoders`) | 26,263,858,182 | same | same | same |
| Video decoder | `ltx-2.5-video-vae-bf16.safetensors` (`vae`) | 1,472,223,346 | same | same | same |
| Audio decoder | `ltx-2.5-audio-vae-bf16.safetensors` (`vae`) | 364,866,540 | same | same | same |
| Video upscaler | `ltx-2.5-latent-spatial-upscaler-x2-bf16-1.0.safetensors` (`latent_upscale_models`) | 995,778,752 | same | same | same |
| Qwen model (Quality) | `qwen_image_2.1_int8_convrot.safetensors` (`diffusion_models`) | 7,256,783,064 | [Comfy-Org/Qwen-Image-2.1](https://huggingface.co/Comfy-Org/Qwen-Image-2.1) `a8342359c619` | qwen-research ([text](https://huggingface.co/Qwen/Qwen-Image-2.1/blob/main/LICENSE), read) | no |
| Qwen model (Turbo) | `qwen_image_2.1_turbo_bf16.safetensors` (`diffusion_models`) | 14,230,280,616 | same | same | no |
| Qwen text encoder | `qwen3vl_8b_int8_convrot.safetensors` (`text_encoders`) | 9,350,798,360 | same | same (the file is also in the Apache-2.0 [Comfy-Org/Qwen3-VL](https://huggingface.co/Comfy-Org/Qwen3-VL), same size) | no |
| Qwen decoder | `qwen_image_2.1_vae_bf16.safetensors` (`vae`) | 675,509,688 | same | same | no |
| Klein model | `flux3_image_klein_sd_bf16.safetensors` (`diffusion_models`) | 11,097,404,512 | [black-forest-labs/flux-3-image-klein-comfy](https://huggingface.co/black-forest-labs/flux-3-image-klein-comfy) `5c9b714851dc` | flux-kommunity-license (the text is behind the gate and was not read) | yes, automatic once accepted |
| Klein text encoder | `qwen3vl_4b_bf16.safetensors` (`text_encoders`) | 8,875,719,408 | same | same | same |
| Klein decoder | `flux2-vae.safetensors` (`vae`) | 336,211,292 | same | same | same |

Totals: video 71,114,917,404; Qwen (all four files) 31,513,371,728; Klein 20,309,335,212.

Two things a stranger should read before installing:

- **The Qwen licence is a research licence.** The verified text grants use "for non-commercial purposes
  only" and says commercial use needs a licence from the vendor. Pictures made with Quality or Turbo for
  a product are not covered by it.
- **The Klein and LTX licences were not read.** The LTX terms are linked above and unread; the Klein text
  is not downloadable without accepting the gate. Read both on their pages before relying on either for
  anything but your own use.

One caution on the Klein text encoder: the Klein repository's copy of `qwen3vl_4b_bf16.safetensors` is
8,875,719,408 bytes and the ungated Apache-2.0 `Comfy-Org/Qwen3-VL` copy is 8,875,719,384, 24 bytes
apart. The catalog and script use the Klein repository's, the file that repository ships beside the
model. Whether the other loads identically was not tested.

## What the app checks

The client (`MediaDoctor`, Core) asks ComfyUI `/system_stats` (card, memory, version, how it was
started), `/object_info` (node classes) and `/models/<folder>` (the files in each folder; the loaders'
own choices when a ComfyUI is too old to answer that). The answer is a `SetupReport` of capability
`media`: `media.comfy`, `media.gpu`, `media.video.nodes`, `media.video.models`, `media.image.nodes`,
`media.image.models`, `media.enhancer`, and one row per missing file (`media.video.model.<role>`,
`media.image.model.<role>`) with the one `hf download` line that fetches it. The reports are ready when ComfyUI answers and either the video lane or at least one picture engine
is complete. A file inside a subfolder of its folder is reported as misplaced, because the graphs name
files by their bare name.

Every road to this answer opens the one checklist the other capabilities use (`docs/setup.md`): the
video button on a machine that cannot render, the studio's machine pill, the render button's "See what is
missing" and the server screen's Capabilities row. The checklist is led by where the person came from.
From video it lists the five video files in order and folds pictures into one optional row; from
pictures it lists the files of the engine nearest to complete (three files, Qwen Quality by default) as
required and every other engine's as optional; from the server screen it leads with whichever lane is
already usable. An optional row never holds the checklist back. The button copies the next missing
file's command, then says Render or Open the studio. The licences are said once each, in the row that
needs them: the gate on LTX-2.5 and on FLUX Klein (accept the licence on the repository's page while
signed in, run `hf auth login` once) and the Qwen research licence ("For personal and research use
only").

ComfyUI being out of reach has six faces and the app says which: nothing is listening on the port,
running here but for this machine only, silent (asleep or off the tailnet), a name that does not
resolve, something else answering, and starting. A ComfyUI that is
loading behind a socket that already accepts connections answers 503 or not at all for a while; that is
"starting, ready in a minute", asked again every few seconds, and never a failure.

"Running here but for this machine only" can only be told from "not running" on the machine ComfyUI is
on, because it takes a connection to the loopback address.

## What the author has that the public does not

| Author's | In the app? | For a stranger |
| --- | --- | --- |
| `wf2api.py`, a converter from ComfyUI's saved workflows (subgraphs included) to API graphs | no, the app builds the API graphs itself in `ForgeGraph` and `ImageGenClient` | not needed |
| Socket activation: `comfyui.socket`, a proxy unit that starts ComfyUI on first contact, `--exit-idle-time=15min`, an idle timer that frees video memory | the app is built to wait for it (the "starting" state) | not published; ComfyUI answers plainly without it, started by hand or by your own service manager |
| `Qwen-Image-2.1-Turbo` merged from the diffusers shards into one file | the app names `qwen_image_2.1_turbo_bf16.safetensors` | Comfy-Org now publishes a file of that name (14,230,280,616 bytes, matching the author's 14.2 GB); that it is byte-identical to the author's merge was not checked |
| `gemma4_e2b_it_bf16` as the prompt enhancer inside the stock LTX workflows | no | not needed |
| The dev (undistilled) LTX transformer, the temporal upscaler, the distilled LoRA | no, the app drives the distilled model on its fixed sigmas only | public in the LTX repository, unused |
| A language model behind llama-swap that rewrites short prompts | optional (`media.enhancer`) | any OpenAI-shaped server (Ollama, llama-swap, llama.cpp, LM Studio, vLLM) on the renderer's machine; absent is fine |
| A daemon fix that fetches the models from the checklist | not yet | every file is public, so one could exist; it would still need the person to accept two licences, which is why the checklist hands over the `hf` command today |

No file or node class the app submits is unpublished. The catalog marks anything that is with
`source: .unpublished`, which today is nothing.

## Not verified

- That `scripts/media-setup.sh` runs to the end: it was only run with `--dry-run`, and checked with
  `bash -n` and `shellcheck`. No model was downloaded and nothing was installed.
- That ComfyUI 0.41.2 loads LTX-2.5 and Qwen Image 2.1 files as published. The nodes exist; running them
  on a stranger's card was not done here; the author's own box renders with these lanes, on a ComfyUI
  whose exact version was not asked.
- Video memory for the picture engines, and for video below 96 GB.
- The Klein and LTX licence texts, and byte-equality of the two Klein text-encoder copies.
- The torch index. `cu130` is what the README gives for NVIDIA cards today.
