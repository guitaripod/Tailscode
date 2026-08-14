#!/usr/bin/env bash
# Build and stage the Linux client the way a package manager wants it.
#
# This is the producer of every distributed artifact. scripts/install-linuxapp.sh stays the
# development loop — it kills the running app, rebuilds against the sibling Kit and restarts a
# systemd scope, which is exactly what a packager must never do.
#
# The two things it does that a bare `swift build` does not:
#   * --static-swift-stdlib, so the machine that runs this needs no Swift toolchain. Without it the
#     binary carries a RUNPATH into the author's swiftly directory and starts nowhere else.
#   * a real install tree — binary, desktop entry, metainfo, the whole icon ramp, man page,
#     completions, licence — under $DESTDIR$PREFIX, so a PKGBUILD's package() is one call.
#
# Usage:
#   scripts/package-linux.sh build                       # binary only, into TailscodeLinux/.build
#   scripts/package-linux.sh install [DESTDIR]           # stage a tree (PREFIX=/usr by default)
#   scripts/package-linux.sh tarball                     # a relocatable tar.gz of that tree
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
APP_ID=io.github.guitaripod.Tailscode
PREFIX=${PREFIX:-/usr}
BUILD_DIR=${BUILD_DIR:-$ROOT/TailscodeLinux/.build}
PACK=$ROOT/packaging/linux

# A release artifact is never built against a working copy nobody else can fetch: the manifest
# resolves the published tag when this is set, so a build that would have quietly used unpublished
# Kit sources fails at resolution instead of shipping.
export TAILSCODE_KIT_REMOTE=${TAILSCODE_KIT_REMOTE:-1}

version() {
    sed -n 's/.*static let current = "\([^"]*\)".*/\1/p' \
        "$ROOT/TailscodeLinux/Sources/TailscodeLinux/TailscodeVersion.swift" | head -1
}

binary() { echo "$BUILD_DIR/release/tailscode"; }

do_build() {
    echo "== building tailscode $(version) (static stdlib)"
    ( cd "$ROOT/TailscodeLinux" && swift build -c release --static-swift-stdlib \
        --scratch-path "$BUILD_DIR" )
    strip --strip-unneeded "$(binary)"
    # The whole point of the static link is that nothing outside the system libraries is needed.
    if ldd "$(binary)" | grep -q 'libswiftCore\|libFoundation'; then
        echo "!! the Swift runtime is still dynamic — --static-swift-stdlib did not take" >&2
        exit 1
    fi
    echo "== built $(binary) ($(du -h "$(binary)" | cut -f1))"
}

do_install() {
    local dest=${1:-${DESTDIR:-$ROOT/build/linux-stage}}
    [ -x "$(binary)" ] || do_build
    echo "== staging into $dest$PREFIX"

    install -Dm0755 "$(binary)" "$dest$PREFIX/bin/tailscode"
    install -Dm0644 "$PACK/$APP_ID.desktop" "$dest$PREFIX/share/applications/$APP_ID.desktop"
    install -Dm0644 "$PACK/$APP_ID.metainfo.xml" "$dest$PREFIX/share/metainfo/$APP_ID.metainfo.xml"
    install -Dm0644 "$PACK/$APP_ID.service" \
        "$dest$PREFIX/share/dbus-1/services/$APP_ID.service"
    install -Dm0644 "$PACK/tailscode.1" "$dest$PREFIX/share/man/man1/tailscode.1"
    install -Dm0644 "$ROOT/LICENSE" "$dest$PREFIX/share/licenses/tailscode/LICENSE"

    install -Dm0644 "$PACK/completions/tailscode.bash" \
        "$dest$PREFIX/share/bash-completion/completions/tailscode"
    install -Dm0644 "$PACK/completions/_tailscode" \
        "$dest$PREFIX/share/zsh/site-functions/_tailscode"
    install -Dm0644 "$PACK/completions/tailscode.fish" \
        "$dest$PREFIX/share/fish/vendor_completions.d/tailscode.fish"

    ( cd "$PACK/icons" && find . -type f -print0 |
        while IFS= read -r -d '' icon; do
            install -Dm0644 "$icon" "$dest$PREFIX/share/icons/${icon#./}"
        done )

    # The D-Bus service file names an absolute path, so a tree staged for a prefix other than /usr
    # would activate a binary that is not there.
    sed -i "s|^Exec=/usr/bin/tailscode|Exec=$PREFIX/bin/tailscode|" \
        "$dest$PREFIX/share/dbus-1/services/$APP_ID.service"

    echo "== staged $(find "$dest" -type f | wc -l) files"
}

do_tarball() {
    local stage=$ROOT/build/linux-tarball
    local name=tailscode-$(version)-linux-x86_64
    rm -rf "$stage"
    PREFIX=/usr do_install "$stage"
    mkdir -p "$ROOT/build"
    tar -C "$stage" -czf "$ROOT/build/$name.tar.gz" .
    ( cd "$ROOT/build" && sha256sum "$name.tar.gz" > "$name.tar.gz.sha256" )
    echo "== $ROOT/build/$name.tar.gz"
    cat "$ROOT/build/$name.tar.gz.sha256"
}

case "${1:-install}" in
    build) do_build ;;
    install) shift || true; do_install "${1:-}" ;;
    tarball) do_tarball ;;
    *) echo "usage: $0 {build|install [DESTDIR]|tarball}" >&2; exit 2 ;;
esac
