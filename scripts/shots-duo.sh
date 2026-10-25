#!/usr/bin/env bash
# Photograph the iPhone Duo masters: ten captures per locale on a dedicated iPhone Duo simulator,
# each in the pose its caption is best told in, written where scripts/market-compose-duo.py reads them.
#
# Which screen, in which pose, for which slug is the Duo table of marketing/captions/layout.json; what
# launches each screen (the app's DEBUG hooks, the same ones scripts/shots.sh uses) is below. Run it on
# the Mac that holds the simulator, from a tree of its own:
#
#   TAILSCODE_DUO_UDID=<iPhone Duo simulator on the iOS 27.1 runtime> \
#   TAILSCODE_DUO_APP=<Tailscode.app, Debug, built with Xcode 27.1 for that simulator> \
#   scripts/shots-duo.sh                       # en-US
#   scripts/shots-duo.sh de-DE ja              # these locales
#   scripts/shots-duo.sh --all                 # every caption locale
#
# The app must be linked against the iOS 27.1 SDK or the Duo never adapts (a black rail); the script
# refuses a binary that vtool does not stamp 27.1. TAILSCODE_DUO_CAPTURE is the iphone-duo skill's
# capture.py, TAILSCODE_DUO_PYTHON a Python with Pillow, and `duoctl` and `frames` must be on PATH.
# Two screens need a fresh install, because the demo world and a queued message both outlive a launch:
# the setup guide (it is what a first launch shows) and the steer (one queued message, not one per pose).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE=com.guitaripod.tailscode
UDID="${TAILSCODE_DUO_UDID:?set TAILSCODE_DUO_UDID to the iPhone Duo simulator}"
APP="${TAILSCODE_DUO_APP:?set TAILSCODE_DUO_APP to the Debug Tailscode.app}"
CAPTURE="${TAILSCODE_DUO_CAPTURE:-$HOME/scratch-duo/capture.py}"
PYTHON="${TAILSCODE_DUO_PYTHON:-python3}"
RUNS="${TAILSCODE_DUO_RUNS:-$HOME/scratch-duo/runs}"
SETTLE="${TAILSCODE_DUO_SETTLE:-14}"
TABLE="$ROOT/marketing/captions/layout.json"
CAPTIONS="$ROOT/marketing/captions"

language_args() {
  case "$1" in
    en-US) echo "" ;;
    de-DE) echo "-AppleLanguages (de) -AppleLocale de_DE" ;;
    es-ES) echo "-AppleLanguages (es) -AppleLocale es_ES" ;;
    fr-FR) echo "-AppleLanguages (fr) -AppleLocale fr_FR" ;;
    it) echo "-AppleLanguages (it) -AppleLocale it_IT" ;;
    pt-BR) echo "-AppleLanguages (pt-BR) -AppleLocale pt_BR" ;;
    ja) echo "-AppleLanguages (ja) -AppleLocale ja_JP" ;;
    pl) echo "-AppleLanguages (pl) -AppleLocale pl_PL" ;;
    ko) echo "-AppleLanguages (ko) -AppleLocale ko_KR" ;;
    zh-Hans) echo "-AppleLanguages (zh-Hans) -AppleLocale zh_CN" ;;
    zh-Hant) echo "-AppleLanguages (zh-Hant) -AppleLocale zh_TW" ;;
    *) echo "unknown locale $1" >&2; exit 1 ;;
  esac
}

# The language and region the whole simulator speaks, so the status column's clock reads 9:41 and the
# system strings follow the app. Korean and Traditional Chinese take a 24-hour clock, as in shots.sh.
system_language() {
  case "$1" in
    en-US) echo "en en_US" ;;
    de-DE) echo "de de_DE" ;;
    es-ES) echo "es es_ES" ;;
    fr-FR) echo "fr fr_FR" ;;
    it) echo "it it_IT" ;;
    pt-BR) echo "pt-BR pt_BR" ;;
    ja) echo "ja ja_JP" ;;
    ko) echo "ko ko_KR@hours=h23" ;;
    pl) echo "pl pl_PL" ;;
    zh-Hans) echo "zh-Hans zh_CN" ;;
    zh-Hant) echo "zh-Hant zh_TW@hours=h23" ;;
  esac
}

speak_locale() {
  local pair language region
  pair=$(system_language "$1")
  language=${pair% *}
  region=${pair#* }
  [ "$(xcrun simctl spawn "$UDID" defaults read -g AppleLocale 2>/dev/null)" = "$region" ] && return
  xcrun simctl spawn "$UDID" defaults write -g AppleLanguages -array "$language"
  xcrun simctl spawn "$UDID" defaults write -g AppleLocale -string "$region"
  xcrun simctl shutdown "$UDID"
  xcrun simctl boot "$UDID"
  xcrun simctl bootstatus "$UDID" >/dev/null 2>&1 || true
}

# Launch arguments of a screen, as the app's DEBUG hooks read them.
screen_launch() {
  case "$1" in
    agents) echo "--demo --agents" ;;
    peek) echo "--demo --agent-peek" ;;
    costs) echo "--demo --analytics" ;;
    setup) echo "" ;;
    *) echo "--demo" ;;
  esac
}

# Launch variables of a screen, comma separated for capture.py.
screen_env() {
  case "$1" in
    agents | peek | costs) echo "TAILSCODE_DUO=1" ;;
    home) echo "TAILSCODE_DUO=1" ;;
    homeo1) echo "TAILSCODE_OPEN_SESSION=demo-o1" ;;
    models) echo "TAILSCODE_OPEN_SESSION=demo-o1,TAILSCODE_OPEN_MODELS=1,TAILSCODE_MODELS_DELAY=8" ;;
    setup) echo "TAILSCODE_OPEN_GUIDE=1,TAILSCODE_SETUP_AGENT=claude,TAILSCODE_SETUP_WAY=install,TAILSCODE_FAKE_TAILNET=up" ;;
    steer) echo "TAILSCODE_OPEN_SESSION=demo-c1,TAILSCODE_DIAL=level:max,TAILSCODE_AUTOSEND=also add a test for the jitter bound,TAILSCODE_NEURAL_OPEN=1" ;;
    gpu) echo "TAILSCODE_OPEN_SESSION=demo-o5,TAILSCODE_INSPECT=tool" ;;
    carry) echo "TAILSCODE_OPEN_SESSION=demo-o6" ;;
    party) echo "TAILSCODE_OPEN_SESSION=demo-c2,TAILSCODE_DIAL=fleetparty" ;;
  esac
}

# Prints "slug screen state" for every slug of the Duo table.
table_rows() {
  "$PYTHON" -I - "$TABLE" <<'PY'
import json, sys
for slug, e in json.load(open(sys.argv[1]))["duo"].items():
    print(slug, e["screen"], e["state"])
PY
}

refuse_unstamped_app() {
  local stamp
  stamp=$(xcrun vtool -show-build "$APP/Tailscode.debug.dylib" | awk '$1 == "sdk" {print $2}')
  [ "$stamp" = "27.1" ] || { echo "the app is stamped sdk $stamp, not 27.1: it would never adapt" >&2; exit 1; }
}

install_fresh() {
  xcrun simctl terminate "$UDID" "$BUNDLE" >/dev/null 2>&1 || true
  xcrun simctl uninstall "$UDID" "$BUNDLE" >/dev/null 2>&1 || true
  xcrun simctl install "$UDID" "$APP"
}

# One capture.py run over the given screen:state cells. The first screen defined is the one the
# warm-up launches, so `agents` leads every run that is not the setup guide.
capture_cells() {
  local out=$1 locale=$2 cells=$3 first=$4
  local flags=() screens=() screen word
  for word in $(language_args "$locale"); do flags+=("--arg=$word"); done
  for screen in $first $(echo "$cells" | tr ',' '\n' | cut -d: -f1 | sort -u); do
    case " ${screens[*]:-} " in *" $screen "*) continue ;; esac
    screens+=("$screen")
    flags+=(--screen "$screen:$(screen_env "$screen")")
    local launch
    launch=$(screen_launch "$screen")
    [ -n "$launch" ] && flags+=(--screen-arg "$screen=$launch")
  done
  "$PYTHON" -W ignore "$CAPTURE" --udid "$UDID" --bundle-id "$BUNDLE" --out "$out" --appearance dark \
    --settle "$SETTLE" --env TAILSCODE_HIDE_DEMO_BADGE=1 --only "$cells" "${flags[@]}"
}

shoot_locale() {
  local locale=$1 run="$RUNS/$1" rows main="" steer="" setup=""
  rows=$(table_rows)
  while read -r slug screen state; do
    case "$screen" in
      steer) steer="$screen:$state" ;;
      setup) setup="$screen:$state" ;;
      *) main="${main:+$main,}$screen:$state" ;;
    esac
  done <<<"$rows"
  speak_locale "$locale"
  xcrun simctl ui "$UDID" appearance dark >/dev/null 2>&1 || true
  rm -rf "$run"
  mkdir -p "$run"
  install_fresh
  capture_cells "$run/main" "$locale" "$main" agents
  install_fresh
  capture_cells "$run/steer" "$locale" "$steer" agents
  install_fresh
  capture_cells "$run/setup" "$locale" "$setup" setup
  place_masters "$locale" "$run"
}

# Copies each slug's raw capture to the folder the composer reads.
place_masters() {
  local locale=$1 run=$2 destination
  if [ "$locale" = en-US ]; then
    destination="$ROOT/marketing/appstore/duo"
  else
    destination="$ROOT/marketing/appstore/l10n/$locale/duo"
  fi
  mkdir -p "$destination"
  while read -r slug screen state; do
    local file="${screen}__${state}.png" found=""
    for part in main steer setup; do
      [ -f "$run/$part/raw/$file" ] && found="$run/$part/raw/$file"
    done
    [ -n "$found" ] || { echo "no capture of $file for $slug" >&2; exit 1; }
    cp "$found" "$destination/$slug.png"
    echo "  $locale/$slug.png <- $file"
  done <<<"$(table_rows)"
}

refuse_unstamped_app
locales=("$@")
if [ "${1:-}" = "--all" ]; then
  locales=($(cd "$CAPTIONS" && ls *.json | grep -v '^layout' | sed 's/\.json$//'))
fi
[ ${#locales[@]} -gt 0 ] || locales=(en-US)
for locale in "${locales[@]}"; do
  echo "== $locale"
  shoot_locale "$locale"
done
