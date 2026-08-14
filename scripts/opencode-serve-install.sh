#!/usr/bin/env bash
# Sets up `opencode serve` on the machine with your code so Tailscode can reach it: opencode
# itself if it is missing, a service that survives a reboot, and a check that keeps the model
# list current. A long-lived server resolves its providers once at startup, so without the last
# part a model your plan gained today never appears in any client until someone restarts it by
# hand — which nobody knows to do.
#
#   curl -fsSL https://raw.githubusercontent.com/guitaripod/Tailscode/master/scripts/opencode-serve-install.sh | bash
#
# Honours OPENCODE_SERVER_PASSWORD (basic auth for the API) and OPENCODE_SERVE_PORT.
set -euo pipefail

MARKER='# managed by tailscode'
PORT="${OPENCODE_SERVE_PORT:-4096}"
PASSWORD="${OPENCODE_SERVER_PASSWORD:-}"
BIN_DIR="$HOME/.local/bin"
ENV_FILE="$HOME/.config/opencode-serve.env"
RUNNER="$BIN_DIR/opencode-serve-run"
REFRESHER="$BIN_DIR/opencode-catalog-refresh"
RESTARTER="$BIN_DIR/opencode-serve-restart"
UNIT_DIR="$HOME/.config/systemd/user"
AGENT_DIR="$HOME/Library/LaunchAgents"
LABEL=io.github.guitaripod.opencode-serve
REFRESH_MINUTES=15

say() { printf '\033[1m%s\033[0m\n' "$*"; }
warn() { printf '\033[33m%s\033[0m\n' "$*" >&2; }

## Writes a file only when nothing else owns it: a service somebody wrote themselves is theirs,
## and an install that silently replaces it would take a machine's setup away from its owner.
## The marker is looked for in the opening lines rather than the first, because a shebang and an
## XML declaration each insist on being line one.
write_managed() {
    local path=$1
    if [ -e "$path" ] && ! head -5 "$path" | grep -qF "$MARKER"; then
        warn "keeping your own $path — remove it and re-run to have this manage it"
        cat >/dev/null
        return 1
    fi
    mkdir -p "$(dirname "$path")"
    cat >"$path"
    return 0
}

## opencode's own installer, run only when the command is missing, and PATH widened to the
## places it lands in so the rest of this script can see it.
ensure_opencode() {
    export PATH="$HOME/.opencode/bin:$BIN_DIR:$PATH"
    if command -v opencode >/dev/null 2>&1; then return; fi
    say "installing opencode"
    curl -fsSL https://opencode.ai/install | bash
    command -v opencode >/dev/null 2>&1 || {
        warn "opencode is still not on PATH — open a new shell and re-run this"
        exit 1
    }
}

## The settings both units read, kept key by key: this file is also where somebody's own
## OPENCODE_CONFIG or API keys live, and an install is not a reason to lose them.
write_env() {
    mkdir -p "$(dirname "$ENV_FILE")"
    touch "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    set_key OPENCODE_SERVE_PORT "$PORT"
    if [ -n "$PASSWORD" ]; then set_key OPENCODE_SERVER_PASSWORD "$PASSWORD"; fi
}

set_key() {
    local key=$1 value=$2 tmp
    tmp=$(mktemp)
    grep -v "^$key=" "$ENV_FILE" >"$tmp" 2>/dev/null || true
    printf '%s=%s\n' "$key" "$value" >>"$tmp"
    cat "$tmp" >"$ENV_FILE"
    rm -f "$tmp"
}

## What the service actually runs. The signature is written before the server starts because it
## is the catalog the server is about to resolve — recording it here means any restart, by any
## hand, leaves the check with the truth rather than a guess.
write_runner() {
    write_managed "$RUNNER" <<EOF || true
#!/usr/bin/env bash
$MARKER
set -uo pipefail
export PATH="\$HOME/.opencode/bin:\$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:\$PATH"
[ -r "\$HOME/.config/opencode-serve.env" ] && set -a && . "\$HOME/.config/opencode-serve.env" && set +a
STATE="\${XDG_STATE_HOME:-\$HOME/.local/state}/opencode-serve/catalog.sig"
mkdir -p "\$(dirname "\$STATE")"
if command -v sha256sum >/dev/null 2>&1; then digest() { sha256sum; }; else digest() { shasum -a 256; }; fi
opencode models 2>/dev/null | digest | cut -d' ' -f1 >"\$STATE" || true
exec opencode serve --hostname 0.0.0.0 --port "\${OPENCODE_SERVE_PORT:-4096}"
EOF
    chmod +x "$RUNNER"
}

## The restart, as one command on the machine, so that everything which needs one — the check
## below, and a client that cannot open a terminal here — asks for it the same way and gets the
## same thing. A machine set up by hand has no such command, which is how a client can tell.
write_restarter() {
    write_managed "$RESTARTER" <<EOF || true
#!/usr/bin/env bash
$MARKER
set -euo pipefail
UNIT=opencode-serve.service
LABEL=$LABEL
if command -v systemctl >/dev/null 2>&1 && systemctl --user is-enabled --quiet "\$UNIT" 2>/dev/null; then
    exec systemctl --user restart "\$UNIT"
fi
if command -v launchctl >/dev/null 2>&1; then
    exec launchctl kickstart -k "gui/\$(id -u)/\$LABEL"
fi
echo "no supervisor here to restart opencode serve" >&2
exit 1
EOF
    chmod +x "$RESTARTER"
}

## The check that makes a new model appear without anyone being told to restart anything.
## `opencode models` resolves the catalog the same way the server does, in a fresh process, so
## it answers what the server would offer if it were started now — and a restart is worth it
## exactly when that differs from what it was started with.
write_refresher() {
    write_managed "$REFRESHER" <<EOF || true
#!/usr/bin/env bash
$MARKER
set -euo pipefail
export PATH="\$HOME/.opencode/bin:\$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:\$PATH"
ENV_FILE="\$HOME/.config/opencode-serve.env"
STATE="\${XDG_STATE_HOME:-\$HOME/.local/state}/opencode-serve/catalog.sig"
LABEL=$LABEL
UNIT=opencode-serve.service
[ -r "\$ENV_FILE" ] && set -a && . "\$ENV_FILE" && set +a
PORT="\${OPENCODE_SERVE_PORT:-4096}"

if command -v sha256sum >/dev/null 2>&1; then digest() { sha256sum | cut -d' ' -f1; }
else digest() { shasum -a 256 | cut -d' ' -f1; }; fi

body=\$(mktemp)
trap 'rm -f "\$body"' EXIT

## A GET against the server, with the password if there is one. Anything but an answer is
## treated as a reason not to touch it.
request() {
    local code auth=()
    [ -n "\${OPENCODE_SERVER_PASSWORD:-}" ] && auth=(-u "opencode:\$OPENCODE_SERVER_PASSWORD")
    code=\$(curl -s -o "\$body" -w '%{http_code}' --max-time 15 "\${auth[@]}" \\
        "http://127.0.0.1:\$PORT\$1") || return 1
    [ "\$code" = 200 ]
}

## opencode publishes no "busy", so a turn is read where it lands: the newest message of each
## session the server has touched lately. An assistant message with no completion on it is an
## answer still being written, and restarting under it would throw that answer away.
is_idle() {
    local id
    request "/session?limit=8" || return 1
    for id in \$(grep -o 'ses_[A-Za-z0-9]\\{1,\\}' "\$body" | sort -u); do
        request "/session/\$id/message?limit=1" || return 1
        grep -q '"role":"assistant"' "\$body" || continue
        grep -q '"completed"' "\$body" || return 1
    done
}

restart() { opencode-serve-restart; }

sig=\$(opencode models 2>/dev/null | digest)
[ -n "\$sig" ] || exit 0
if [ "\$sig" = "\$(cat "\$STATE" 2>/dev/null || true)" ]; then exit 0; fi
if ! is_idle; then
    echo "model list changed; server is mid-turn, retrying at the next check"
    exit 0
fi
echo "model list changed; restarting opencode serve so every client can see it"
restart || exit 0
mkdir -p "\$(dirname "\$STATE")"
printf '%s\n' "\$sig" >"\$STATE"
EOF
    chmod +x "$REFRESHER"
}

install_systemd() {
    write_managed "$UNIT_DIR/opencode-serve.service" <<EOF || true
$MARKER
[Unit]
Description=opencode headless server (HTTP + SSE API for Tailscode)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$RUNNER
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
EOF
    write_managed "$UNIT_DIR/opencode-serve-refresh.service" <<EOF || true
$MARKER
[Unit]
Description=Restart opencode serve when its model list changes
After=opencode-serve.service

[Service]
Type=oneshot
ExecStart=$REFRESHER
EOF
    write_managed "$UNIT_DIR/opencode-serve-refresh.timer" <<EOF || true
$MARKER
[Unit]
Description=Check every $REFRESH_MINUTES minutes for models opencode has gained

[Timer]
OnBootSec=10min
OnUnitActiveSec=${REFRESH_MINUTES}min
AccuracySec=1min
Persistent=true

[Install]
WantedBy=timers.target
EOF
    systemctl --user daemon-reload
    systemctl --user enable --now opencode-serve.service
    systemctl --user enable --now opencode-serve-refresh.timer
    loginctl enable-linger "$USER" >/dev/null 2>&1 ||
        warn "could not enable lingering — the server stops when you log out (sudo loginctl enable-linger $USER)"
}

install_launchd() {
    ## A brew formula's own service holds the port this install is about to claim. It is asked to
    ## let go, not killed by pid — a service a package manager started has its own opinion about
    ## being stopped, and bootout is how it is told.
    launchctl bootout "gui/$(id -u)/com.opencode.serve" >/dev/null 2>&1 || true
    agent "$LABEL" "$RUNNER" "" >/dev/null
    agent "$LABEL.refresh" "$REFRESHER" "$((REFRESH_MINUTES * 60))" >/dev/null
    for label in "$LABEL" "$LABEL.refresh"; do
        launchctl bootout "gui/$(id -u)/$label" >/dev/null 2>&1 || true
        launchctl bootstrap "gui/$(id -u)" "$AGENT_DIR/$label.plist"
    done
}

## One LaunchAgent, either kept alive or run on an interval — launchd has no timer unit, so the
## interval is the agent's own.
agent() {
    local label=$1 program=$2 interval=$3 schedule
    if [ -n "$interval" ]; then
        schedule="    <key>StartInterval</key><integer>$interval</integer>"
    else
        schedule="    <key>KeepAlive</key><true/>
    <key>RunAtLoad</key><true/>"
    fi
    write_managed "$AGENT_DIR/$label.plist" <<EOF || true
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<!-- $MARKER -->
<plist version="1.0">
<dict>
    <key>Label</key><string>$label</string>
    <key>ProgramArguments</key>
    <array><string>/bin/bash</string><string>-lc</string><string>exec $program</string></array>
$schedule
    <key>StandardOutPath</key><string>$HOME/Library/Logs/$label.log</string>
    <key>StandardErrorPath</key><string>$HOME/Library/Logs/$label.log</string>
</dict>
</plist>
EOF
}

mkdir -p "$BIN_DIR"
ensure_opencode
write_env
write_runner
write_restarter
write_refresher

case "$(uname -s)" in
    Linux)
        command -v systemctl >/dev/null 2>&1 || {
            warn "no systemd here — run '$RUNNER' yourself, and '$REFRESHER' every $REFRESH_MINUTES minutes"
            exit 0
        }
        install_systemd
        ;;
    Darwin)
        mkdir -p "$AGENT_DIR" "$HOME/Library/Logs"
        install_launchd
        ;;
    *)
        warn "unknown system — run '$RUNNER' yourself, and '$REFRESHER' every $REFRESH_MINUTES minutes"
        exit 0
        ;;
esac

## Says whether the thing this script exists to start is actually answering. The usual reason it
## is not is a server somebody already started by hand holding the port.
for _ in 1 2 3 4 5; do
    curl -s -o /dev/null --max-time 3 "http://127.0.0.1:$PORT/config" && break
    sleep 2
done
curl -s -o /dev/null --max-time 3 "http://127.0.0.1:$PORT/config" ||
    warn "nothing is answering on port $PORT — is a server already running there by hand?"

say "opencode serve is running on port $PORT and keeps its model list current."
if command -v tailscale >/dev/null 2>&1; then
    address=$(tailscale ip -4 2>/dev/null | head -1)
    [ -n "$address" ] && say "Point Tailscode at $address:$PORT"
fi
[ -n "$PASSWORD" ] && say "Password: $PASSWORD"
exit 0
