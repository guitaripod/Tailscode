#!/usr/bin/env bash
# Sets up the machine that makes Tailscode's pictures and videos: ComfyUI at a pinned release in its
# own virtual environment, and every public model file the app submits, each from the repository it
# was verified against. The recipe, the sources and the reasons are docs/media-setup.md; the
# catalog the app checks a machine against is TailscodeCore/Sources/TailscodeCore/MediaRequirements.swift
# and a test keeps the two in step.
#
#   scripts/media-setup.sh --dry-run             print every action and touch nothing
#   scripts/media-setup.sh                       install ComfyUI and all the models into ~/comfyui
#   scripts/media-setup.sh --only images         the picture models only (about 52 GB)
#   scripts/media-setup.sh --only video          the video models only (about 71 GB)
#   scripts/media-setup.sh --only none           ComfyUI itself, no models
#   scripts/media-setup.sh --dir /data/comfyui   somewhere other than ~/comfyui
#
# Linux with an NVIDIA graphics card. Nothing is installed system-wide and nothing needs root. A
# model download resumes where it stopped when the script is run again.
set -euo pipefail

COMFYUI_REPOSITORY="https://github.com/Comfy-Org/ComfyUI.git"
COMFYUI_TAG="v0.41.2"
COMFYUI_COMMIT="b53f77a74e21091cbdebfdf7b85fc80326932646"
TORCH_INDEX="https://download.pytorch.org/whl/cu130"
PORT=8188

LTX_REPO="Lightricks/LTX-2.5"
LTX_REVISION="49b093a39c19169a8a81721dcc541e07e945232f"
QWEN_REPO="Comfy-Org/Qwen-Image-2.1"
QWEN_REVISION="a8342359c61979b06a8dafb1a47991fe1f30e994"
KLEIN_REPO="black-forest-labs/flux-3-image-klein-comfy"
KLEIN_REVISION="5c9b714851dc072b04a23ef6d2d36421f5ccb3a0"

VIDEO_FILES=(
    "diffusion_models/ltx-2.5-22b-distilled-transformer-bf16.safetensors"
    "text_encoders/gemma4-12b-with-proj-ltx-2.5-bf16.safetensors"
    "vae/ltx-2.5-video-vae-bf16.safetensors"
    "vae/ltx-2.5-audio-vae-bf16.safetensors"
    "latent_upscale_models/ltx-2.5-latent-spatial-upscaler-x2-bf16-1.0.safetensors"
)
QWEN_FILES=(
    "diffusion_models/qwen_image_2.1_int8_convrot.safetensors"
    "diffusion_models/qwen_image_2.1_turbo_bf16.safetensors"
    "text_encoders/qwen3vl_8b_int8_convrot.safetensors"
    "vae/qwen_image_2.1_vae_bf16.safetensors"
)
KLEIN_FILES=(
    "diffusion_models/flux3_image_klein_sd_bf16.safetensors"
    "text_encoders/qwen3vl_4b_bf16.safetensors"
    "vae/flux2-vae.safetensors"
)

VIDEO_BYTES=71114917404
QWEN_BYTES=31513371728
KLEIN_BYTES=20309335212
ENVIRONMENT_BYTES=12000000000

DRY_RUN=no
ONLY=all
ROOT="$HOME/comfyui"

# Prints a line on stderr.
say() { printf '%s\n' "$*" >&2; }

# Prints a line and stops.
die() {
    say "media-setup: $*"
    exit 1
}

# Runs a command, or only prints it under --dry-run.
run() {
    if [ "$DRY_RUN" = yes ]; then
        say "+ $*"
        return 0
    fi
    "$@"
}

# Reads the command line.
parse_arguments() {
    while [ $# -gt 0 ]; do
        case "$1" in
        --dry-run) DRY_RUN=yes ;;
        --only)
            [ $# -ge 2 ] || die "--only needs video, images or none"
            ONLY=$2
            shift
            ;;
        --dir)
            [ $# -ge 2 ] || die "--dir needs a folder"
            ROOT=$2
            shift
            ;;
        -h | --help)
            sed -n '2,17p' "$0" >&2
            exit 0
            ;;
        *) die "unknown option $1" ;;
        esac
        shift
    done
    case "$ONLY" in
    all | video | images | none) ;;
    *) die "--only takes all, video, images or none" ;;
    esac
}

# Whether a lane's models were asked for.
wants() {
    [ "$ONLY" = all ] || [ "$ONLY" = "$1" ]
}

# The bytes the chosen models and the environment will take.
bytes_needed() {
    local total=$ENVIRONMENT_BYTES
    wants video && total=$((total + VIDEO_BYTES))
    if wants images; then
        total=$((total + QWEN_BYTES + KLEIN_BYTES))
    fi
    echo "$total"
}

# The newest Python this machine has that ComfyUI supports (3.13 is the best supported, 3.10 the
# oldest).
find_python() {
    local candidate
    for candidate in python3.13 python3.12 python3.11 python3.10 python3; do
        if command -v "$candidate" >/dev/null 2>&1 &&
            "$candidate" -c 'import sys; sys.exit(0 if (3, 10) <= sys.version_info[:2] < (3, 15) else 1)' 2>/dev/null; then
            echo "$candidate"
            return 0
        fi
    done
    return 1
}

# Proves the machine can do this before anything is written: a card, git, a Python and room for
# the files. Under --dry-run it says what it would check and what it found.
check_machine() {
    say "checking this machine"
    command -v git >/dev/null 2>&1 || say "  git is not installed; the real run needs it"
    if command -v nvidia-smi >/dev/null 2>&1; then
        say "  graphics card: $(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader | head -n 1)"
    else
        say "  nvidia-smi not found; the real run needs an NVIDIA card and its driver"
    fi
    local python
    if python=$(find_python); then
        say "  python: $python ($($python --version 2>&1))"
    else
        say "  no Python between 3.10 and 3.14 found; the real run needs one with venv"
    fi
    local need free existing=$ROOT
    need=$(bytes_needed)
    while [ ! -d "$existing" ] && [ "$existing" != "/" ]; do existing=$(dirname "$existing"); done
    free=$(df -B1 --output=avail "$existing" 2>/dev/null | tail -n 1 | tr -d ' ' || echo 0)
    say "  room needed: $((need / 1000000000)) GB, free where $ROOT goes: $((${free:-0} / 1000000000)) GB"
    if [ "$DRY_RUN" = no ]; then
        command -v git >/dev/null 2>&1 || die "git is not installed"
        command -v nvidia-smi >/dev/null 2>&1 || die "no NVIDIA graphics card found (nvidia-smi is missing)"
        find_python >/dev/null || die "no Python between 3.10 and 3.14 with venv was found"
        [ "${free:-0}" -ge "$need" ] || die "not enough room: $((need / 1000000000)) GB needed"
    fi
}

# Clones ComfyUI and puts it on the pinned commit.
install_comfyui() {
    local directory="$ROOT/ComfyUI"
    say "ComfyUI $COMFYUI_TAG ($COMFYUI_COMMIT)"
    if [ -d "$directory/.git" ]; then
        say "  already cloned at $directory"
        run git -C "$directory" fetch --tags --quiet
    else
        run mkdir -p "$ROOT"
        run git clone --quiet "$COMFYUI_REPOSITORY" "$directory"
    fi
    run git -C "$directory" checkout --quiet --detach "$COMFYUI_COMMIT"
    if [ "$DRY_RUN" = no ]; then
        [ "$(git -C "$directory" rev-parse HEAD)" = "$COMFYUI_COMMIT" ] || die "ComfyUI is not at $COMFYUI_COMMIT"
    fi
}

# Makes the virtual environment and installs torch for CUDA, ComfyUI's requirements and the
# Hugging Face downloader into it.
install_environment() {
    local python environment="$ROOT/venv"
    say "Python environment $environment"
    if [ "$DRY_RUN" = yes ]; then
        python=$(find_python || echo python3)
    else
        python=$(find_python)
    fi
    [ -x "$environment/bin/python" ] || run "$python" -m venv "$environment"
    run "$environment/bin/pip" install --quiet --upgrade pip
    run "$environment/bin/pip" install --quiet torch torchvision torchaudio --extra-index-url "$TORCH_INDEX"
    run "$environment/bin/pip" install --quiet -r "$ROOT/ComfyUI/requirements.txt"
    run "$environment/bin/pip" install --quiet --upgrade "huggingface_hub[cli]"
}

# Stops with the two steps a licence-gated repository needs when this machine is not signed in.
require_hugging_face_login() {
    if [ "$DRY_RUN" = yes ]; then
        say "  would check that 'hf auth whoami' answers; the LTX and Klein repositories are gated"
        return 0
    fi
    "$ROOT/venv/bin/hf" auth whoami >/dev/null 2>&1 && return 0
    say "The LTX-2.5 and FLUX 3 Klein repositories are gated: accept each licence on its page while signed in,"
    say "then sign this machine in once with a token that can read them:"
    say "  https://huggingface.co/$LTX_REPO"
    say "  https://huggingface.co/$KLEIN_REPO"
    say "  $ROOT/venv/bin/hf auth login"
    die "not signed in to Hugging Face"
}

# One repository's files at the pinned revision, into ComfyUI's models folder. The downloader
# resumes a file it was stopped on.
fetch() {
    local repository=$1 revision=$2
    shift 2
    say "  $repository: $*"
    run "$ROOT/venv/bin/hf" download "$repository" --revision "$revision" "$@" --local-dir "$ROOT/ComfyUI/models"
}

# Downloads the lanes that were asked for.
download_models() {
    wants video || wants images || {
        say "no models asked for"
        return 0
    }
    say "models into $ROOT/ComfyUI/models"
    require_hugging_face_login
    if wants video; then
        fetch "$LTX_REPO" "$LTX_REVISION" "${VIDEO_FILES[@]}"
    fi
    if wants images; then
        fetch "$QWEN_REPO" "$QWEN_REVISION" "${QWEN_FILES[@]}"
        fetch "$KLEIN_REPO" "$KLEIN_REVISION" "${KLEIN_FILES[@]}"
    fi
}

# The one command that starts ComfyUI where the app can reach it. ComfyUI has no sign-in, so it
# listens on loopback and on this machine's tailnet address and nowhere else: never on every
# interface of a machine that is on other networks too. Without a tailnet address it listens on
# loopback only and says so, which fails safe: nothing else can reach it until Tailscale is up.
print_start_command() {
    local address=""
    if command -v tailscale >/dev/null 2>&1; then
        address=$(tailscale ip -4 2>/dev/null | head -n 1)
    fi
    local listen="127.0.0.1"
    if [ -n "$address" ]; then
        listen="127.0.0.1,$address"
    else
        say "Tailscale gave no address here, so the command below listens on this machine only."
        say "Other machines cannot reach it until Tailscale is up; ComfyUI has no password, so it is"
        say "never started on every interface."
    fi
    say ""
    say "start it with:"
    printf '  cd %s/ComfyUI && %s/venv/bin/python main.py --listen "%s" --port %s\n' "$ROOT" "$ROOT" "$listen" "$PORT"
    say ""
    say "then open Video or Images in Tailscode: it finds this machine and checks what is installed."
}

# Runs the recipe in order.
main() {
    parse_arguments "$@"
    [ "$DRY_RUN" = yes ] && say "dry run: nothing below is done"
    check_machine
    install_comfyui
    install_environment
    download_models
    print_start_command
}

main "$@"
