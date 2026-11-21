#!/usr/bin/env bash
# Puts the terminal engine (libghostty-vt, MIT) where TailscodeCore's manifest looks for it on
# Linux: TailscodeCore/Vendor/ghostty-vt/{lib/libghostty-vt.a,include/}. Apple platforms take the
# same release as an XCFramework straight from the manifest and never run this.
#
# The library is built from the release's own source and dependency tarballs, both checked against
# the checksums below, with the Zig the release names, itself checked when it has to be fetched. A
# finished build is kept under ~/.cache/tailscode so every checkout after the first is a copy.
#
#   scripts/ghostty-vt.sh            build if missing, then install into this checkout
#   scripts/ghostty-vt.sh --check    exit 0 when this checkout already has the pinned build
#   scripts/ghostty-vt.sh --force    rebuild even when the cache holds one
#
# TAILSCODE_GHOSTTY_SOURCES names a folder that already holds the tarballs (and Zig's), for a
# build that may not reach the network: a Flatpak declares them as sources and points here.
set -euo pipefail

VERSION=1.0.1
SOURCE_SHA=333dfce97641ef9b536bb9e08907ad86abaaada50e8f7417b70d9284adef37aa
DEPS_SHA=91a4e10960a52bf5bf4b15aa2a2cddaff8a89d6cd903d3055bda4fd17de3356d
ZIG_SERIES=0.17
ZIG_VERSION=0.17.1
ZIG_SHA_x86_64=3581863e3cbcfd0fce0efc682ce7e9e93da96668a977791d356a26d2a7e9b17a
ZIG_SHA_aarch64=a1546d5646eb184437918d6635ca6b762a0e889eac09cef720ee7a1ed3fe7795
GLIBC_FLOOR=2.36
BASE="https://release.files.ghostty.org/libghostty-vt/$VERSION"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/TailscodeCore/Vendor/ghostty-vt"
ARCH="$(uname -m)"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/tailscode/ghostty-vt/$VERSION-$ARCH"
STAMP="$VERSION-$ARCH-glibc$GLIBC_FLOOR"

installed() { [[ -f "$DEST/lib/libghostty-vt.a" && "$(cat "$DEST/STAMP" 2>/dev/null)" == "$STAMP" ]]; }
cached() { [[ -f "$CACHE/out/lib/libghostty-vt.a" && "$(cat "$CACHE/out/STAMP" 2>/dev/null)" == "$STAMP" ]]; }

case "${1:-}" in
    --check) installed && exit 0 || exit 1 ;;
    --force) rm -rf "$CACHE/out" ;;
    "") installed && exit 0 ;;
    *) echo "usage: $0 [--check|--force]" >&2; exit 2 ;;
esac

[[ "$(uname -s)" == Linux ]] || { echo "ghostty-vt.sh: Linux only; Apple builds use the XCFramework" >&2; exit 2; }

fetch() {
    local name="$1" sha="$2" url="$3"
    if [[ -f "$CACHE/$name" ]] && echo "$sha  $CACHE/$name" | sha256sum -c --status; then return; fi
    if [[ -n "${TAILSCODE_GHOSTTY_SOURCES:-}" ]]; then
        cp "$TAILSCODE_GHOSTTY_SOURCES/$name" "$CACHE/$name.part"
    else
        curl -fsSL --retry 3 -o "$CACHE/$name.part" "$url"
    fi
    echo "$sha  $CACHE/$name.part" | sha256sum -c --status \
        || { echo "ghostty-vt.sh: $name does not match its pinned checksum" >&2; exit 1; }
    mv "$CACHE/$name.part" "$CACHE/$name"
}

zig_binary() {
    if command -v zig >/dev/null && [[ "$(zig version)" == "$ZIG_SERIES".* ]]; then
        command -v zig
        return
    fi
    local name="zig-$ARCH-linux-$ZIG_VERSION" sha_name="ZIG_SHA_$ARCH"
    [[ -n "${!sha_name:-}" ]] || { echo "ghostty-vt.sh: no pinned Zig for $ARCH; install Zig $ZIG_SERIES" >&2; exit 1; }
    if [[ ! -x "$CACHE/$name/zig" ]]; then
        fetch "$name.tar.xz" "${!sha_name}" "https://ziglang.org/download/$ZIG_VERSION/$name.tar.xz" >&2
        tar -xJf "$CACHE/$name.tar.xz" -C "$CACHE"
    fi
    echo "$CACHE/$name/zig"
}

build() {
    mkdir -p "$CACHE"
    fetch "libghostty-vt-$VERSION.tar.gz" "$SOURCE_SHA" "$BASE/libghostty-vt-$VERSION.tar.gz"
    fetch "libghostty-vt-$VERSION-deps.tar.gz" "$DEPS_SHA" "$BASE/libghostty-vt-$VERSION-deps.tar.gz"
    local work="$CACHE/work"
    rm -rf "$work" "$CACHE/out"
    mkdir -p "$work"
    tar -xzf "$CACHE/libghostty-vt-$VERSION.tar.gz" -C "$work"
    tar -xzf "$CACHE/libghostty-vt-$VERSION-deps.tar.gz" -C "$work"
    local zig
    zig="$(zig_binary)"
    (
        cd "$work/libghostty-vt-$VERSION"
        DESTDIR="$work/stage" ZIG_GLOBAL_CACHE_DIR="$work/zig-cache" "$zig" build \
            --prefix /usr \
            --system "../libghostty-vt-$VERSION-deps" \
            -Doptimize=ReleaseFast \
            -Dcpu=baseline \
            -Dstrip=true \
            -Dtarget="$ARCH-linux-gnu.$GLIBC_FLOOR"
    )
    mkdir -p "$CACHE/out/lib"
    cp "$work/stage/usr/lib/libghostty-vt.a" "$CACHE/out/lib/"
    cp -r "$work/stage/usr/include" "$CACHE/out/include"
    cp "$work/libghostty-vt-$VERSION/LICENSE" "$CACHE/out/LICENSE"
    echo "$STAMP" > "$CACHE/out/STAMP"
    rm -rf "$work"
}

# SwiftPM keeps a manifest's plan until the manifest changes, and whether the engine is linked is
# decided by whether the vendor folder exists when the manifest is read.
replan_manifest() { touch "$ROOT/TailscodeCore/Package.swift"; }

cached || build
rm -rf "$DEST"
mkdir -p "$DEST"
cp -r "$CACHE/out/." "$DEST/"
replan_manifest
echo "ghostty-vt $VERSION installed at $DEST"
