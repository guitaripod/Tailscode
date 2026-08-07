#!/usr/bin/env bash
# One reel, start to finish: a clean single-pane app, the recorder, the reel, the file.
#
#   scripts/film-shoot.sh <reel> <out.mkv> [theme]
#
# Every reel starts from the same window so the pool isn't half snapshots of the previous reel's
# leftover grid, and each one lands in its own file so the assigner can spread consecutive cuts
# across sources. `theme` re-seeds the saved theme before launch — two palettes in the pool give
# the cut colour contrast a single grade can't.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
REEL=${1:?reel}
OUT=${2:?out.mkv}
THEME=${3:-}
PANES=${TAILSCODE_FILM_PANES:-}
STATE=${TAILSCODE_FILM_STATE:-/tmp/tailscode-film/${TAILSCODE_FILM_DISPLAY_NUM:-78}}
UI=$STATE/home/config/tailscode/ui.json
export TAILSCODE_FILM_RENDERER=${TAILSCODE_FILM_RENDERER:-ngl}

python3 - "$UI" "$THEME" "$PANES" <<'PY'
import json, sys
path, theme, panes = sys.argv[1], sys.argv[2], sys.argv[3]
s = json.load(open(path))
pane, profile, session = ("5CD0EE67-CEC3-4743-8D1A-9047A6D06214",
                          "D3C88EEB-A792-4D9A-B3E7-842CE921388E",
                          "8D539B0F-EDE3-435E-B0F7-79AF0CF56D52")
s["tailscode.layout.tree"] = json.dumps({
    "sessions": {pane: {"profileID": profile, "sessionID": session}},
    "videos": {}, "pages": {},
    "layout": {"focusHistory": [pane], "root": {"pane": {"_0": pane}}, "focusedPane": pane}})
s["tailscode.window.width"] = 1920
s["tailscode.window.height"] = 1080
s["tailscode.pane.sidebar"] = True
s["tailscode.pane.files"] = bool(panes)
s["tailscode.pane.terminal"] = bool(panes)
if panes:
    s["tailscode.divider.project"] = 1010
    s["tailscode.divider.terminal"] = 540
s["tailscode.scale.prose"] = 1.2
for key in ("chrome", "mono", "terminal"):
    s[f"tailscode.scale.{key}"] = 1
if theme:
    s["tailscode.theme"] = theme
json.dump(s, open(path, "w"), indent=2)
PY

pid=$(cat "$STATE/app.pid" 2>/dev/null || true)
[ -n "$pid" ] && kill -9 "$pid" 2>/dev/null || true
rm -f "$STATE/app.pid"
sleep 1.5

bash "$REPO/scripts/record-linuxapp.sh" up >/dev/null
sleep 5
bash "$REPO/scripts/record-linuxapp.sh" rec-start "$OUT"
bash "$REPO/scripts/record-linuxapp.sh" in \
    "${XDG_CACHE_HOME:-$HOME/.cache}/tailscode-dev/xvenv/bin/python" \
    "$REPO/scripts/film-reel.py" "$REEL"
sleep 0.6
bash "$REPO/scripts/record-linuxapp.sh" rec-stop
