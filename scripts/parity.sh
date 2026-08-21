#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

CORE=TailscodeCore/Sources/TailscodeCore/Parity.swift
GATING=scripts/lib/gating.awk
COLUMNS=(iOS linux mac macStore)

label_for() {
  case "$1" in
    macStore) echo mac-store ;;
    *) echo "$1" ;;
  esac
}

dir_for() {
  case "$1" in
    iOS) echo Tailscode ;;
    linux) echo TailscodeLinux/Sources/TailscodeLinux ;;
    mac | macStore) echo TailscodeMac ;;
  esac
}

manifest_for() {
  case "$1" in
    iOS) echo Tailscode/App/Parity.swift ;;
    linux) echo TailscodeLinux/Sources/TailscodeLinux/Parity.swift ;;
    mac | macStore) echo TailscodeMac/Parity.swift ;;
  esac
}

store_for() {
  case "$1" in
    macStore) echo 1 ;;
    *) echo 0 ;;
  esac
}

half_for() {
  case "$1" in
    mac) echo direct ;;
    macStore) echo appStore ;;
    *) echo "" ;;
  esac
}

fact_set() { eval "_${1}_${2}_${3}=\$4"; }
fact_get() { eval "printf '%s' \"\${_${1}_${2}_${3}:-}\""; }

flatten_manifest() {
  awk '
    function flush(   text) {
      if (cap == "") return
      text = buf
      gsub(/[ \t]+/, " ", text)
      gsub(/\( +/, "(", text)
      gsub(/" \+ "/, "", text)
      sub(/^ +/, "", text)
      sub(/ +$/, "", text)
      sub(/( \})+$/, "", text)
      if (cap ~ /^[A-Za-z][A-Za-z0-9]*$/) print cap "\t" text
      cap = ""
      buf = ""
    }
    done { next }
    /^[ \t]*case \./ {
      flush()
      cap = $0
      sub(/^[ \t]*case \./, "", cap)
      sub(/[:,].*/, "", cap)
      buf = $0
      next
    }
    /^[ \t]*\}/ {
      if (cap != "" && index($0, "}") <= 5) { flush(); done = 1; next }
    }
    cap != "" { buf = buf " " $0 }
    END { flush() }
  ' "$1"
}

CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1
errors=()

[[ -f "$GATING" ]] || { echo "parity: missing $GATING" >&2; exit 1; }

caps=($(awk '/^public enum AppCapability/,/^}/' "$CORE" | sed -n 's/^ *case \([A-Za-z]*\)$/\1/p'))
[[ ${#caps[@]} -gt 0 ]] || { echo "parity: could not parse AppCapability cases from $CORE" >&2; exit 1; }

for cap in "${caps[@]}"; do
  grep -q "id: \.$cap," "$CORE" || errors+=("registry: no CapabilityDefinition for .$cap in $CORE")
done

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

checked_manifests=""
for c in "${COLUMNS[@]}"; do
  name=$(label_for "$c")
  mf=$(manifest_for "$c")
  half=$(half_for "$c")
  [[ -f "$mf" ]] || { echo "parity: missing manifest $mf" >&2; exit 1; }
  case " $checked_manifests " in
    *" $mf "*) ;;
    *)
      checked_manifests="$checked_manifests $mf"
      if grep -nE '(^|[^A-Za-z])default *:' "$mf" >/dev/null; then
        errors+=("$name: 'default:' found in $mf — the switch must stay exhaustive, one case per line")
      fi
      if grep -nE 'case \.[A-Za-z]+ *,' "$mf" >/dev/null; then
        errors+=("$name: grouped cases found in $mf — one case per line so the script can parse evidence")
      fi
      ;;
  esac

  flatten_manifest "$mf" >"$work/$c.blocks"
  while IFS=$'\t' read -r bcap btext; do
    [[ -n "$bcap" ]] && fact_set TEXT "$c" "$bcap" "$btext"
  done <"$work/$c.blocks"

  : >"$work/$c.anchors"
  : >"$work/$c.anchorcaps"

  for cap in "${caps[@]}"; do
    text=$(fact_get TEXT "$c" "$cap")
    if [[ -z "$text" ]]; then
      errors+=("$name: no answer for .$cap in $mf")
      fact_set KIND "$c" "$cap" "?"
      continue
    fi

    if [[ "$text" == *".varies("* ]]; then
      if [[ -z "$half" ]]; then
        errors+=("$name: .$cap answers with .varies, but this client ships exactly one way — a varies here is a bug")
        fact_set KIND "$c" "$cap" "?"
        continue
      fi
      body=${text#*.varies(}
      body=${body#*direct:}
      direct_half=${body%%, appStore:*}
      after=${body#*, appStore:}
      store_half=${after%%, because:*}
      because=${after#*, because:}
      if [[ "$body" != *", appStore:"* || "$after" != *", because:"* ]]; then
        errors+=("$name: .$cap has a .varies this script cannot split into direct:/appStore:/because:")
        fact_set KIND "$c" "$cap" "?"
        continue
      fi
      because=$(sed -e 's/^ *"//' -e 's/")* *$//' <<<"$because")
      if [[ -z "$because" ]]; then
        errors+=("$name: .$cap varies but says nothing about why")
      fi
      if [[ "$half" == direct ]]; then text=$direct_half; else text=$store_half; fi
      if [[ "$text" == *".varies("* ]]; then
        errors+=("$name: .$cap nests a .varies inside its $half half")
        fact_set KIND "$c" "$cap" "?"
        continue
      fi
    fi

    case "$text" in
      *".implemented("*)
        fact_set KIND "$c" "$cap" "implemented"
        fact_set ANCHOR "$c" "$cap" "$(sed 's/.*\.implemented("\([^"]*\)").*/\1/' <<<"$text")"
        ;;
      *".partial("*)
        fact_set KIND "$c" "$cap" "partial"
        fact_set ANCHOR "$c" "$cap" "$(sed 's/.*\.partial("\([^"]*\)".*/\1/' <<<"$text")"
        fact_set NOTE "$c" "$cap" "$(sed 's/.*missing: *"\(.*\)").*/\1/' <<<"$text")"
        ;;
      *".gap("*)
        fact_set KIND "$c" "$cap" "gap"
        fact_set NOTE "$c" "$cap" "$(sed 's/.*\.gap("\(.*\)").*/\1/' <<<"$text")"
        ;;
      *".notApplicable("*)
        fact_set KIND "$c" "$cap" "n/a"
        fact_set NOTE "$c" "$cap" "$(sed 's/.*\.notApplicable("\(.*\)").*/\1/' <<<"$text")"
        ;;
      *)
        errors+=("$name: unparseable evidence for .$cap: $text")
        fact_set KIND "$c" "$cap" "?"
        ;;
    esac

    anchor=$(fact_get ANCHOR "$c" "$cap")
    if [[ -n "$anchor" ]]; then
      printf '%s\n' "$anchor" >>"$work/$c.anchors"
      printf '%s\n' "$cap" >>"$work/$c.anchorcaps"
    fi
    note=$(fact_get NOTE "$c" "$cap")
    kind=$(fact_get KIND "$c" "$cap")
    if [[ "$kind" != "implemented" && "$kind" != "?" && -z "$note" ]]; then
      errors+=("$name: .$cap is $kind but carries no reason")
    fi
  done

  dir=$(dir_for "$c")
  sources=()
  while IFS= read -r f; do sources+=("$f"); done < <(find "$dir" -name '*.swift' ! -name 'Parity.swift' | sort)
  [[ ${#sources[@]} -gt 0 ]] || { echo "parity: no sources under $dir" >&2; exit 1; }
  if [[ -s "$work/$c.anchors" ]]; then
    awk -v store="$(store_for "$c")" -v anchors="$work/$c.anchors" -f "$GATING" "${sources[@]}" \
      >"$work/$c.hits"
    while IFS=$'\t' read -r count anchor acap; do
      if [[ "$count" -eq 0 ]]; then
        if [[ "$c" == macStore ]]; then
          errors+=("$name: anchor '$anchor' for .$acap is compiled out of the store target (or absent) — TAILSCODE_MAS gates it away, so this column may not claim it")
        else
          errors+=("$name: anchor '$anchor' for .$acap not found anywhere under $dir")
        fi
      fi
    done < <(paste "$work/$c.hits" "$work/$c.anchorcaps")
  fi
done

if [[ $CHECK -eq 0 ]]; then
  header=()
  for c in "${COLUMNS[@]}"; do header+=("$(label_for "$c")"); done
  printf '%-26s %-11s %-11s %-11s %-11s\n' "capability" "${header[@]}"
  printf '%-26s %-11s %-11s %-11s %-11s\n' "----------" "---" "-----" "---" "---------"
  for cap in "${caps[@]}"; do
    row=()
    for c in "${COLUMNS[@]}"; do
      case "$(fact_get KIND "$c" "$cap")" in
        implemented) row+=("ok") ;;
        partial) row+=("PARTIAL") ;;
        gap) row+=("GAP") ;;
        "n/a") row+=("n/a") ;;
        *) row+=("??") ;;
      esac
    done
    printf '%-26s %-11s %-11s %-11s %-11s\n' "$cap" "${row[@]}"
  done
  echo
  for c in "${COLUMNS[@]}"; do
    for cap in "${caps[@]}"; do
      k=$(fact_get KIND "$c" "$cap")
      if [[ "$k" == "gap" || "$k" == "partial" ]]; then
        echo "$(label_for "$c") .$cap ($k): $(fact_get NOTE "$c" "$cap")"
      fi
    done
  done
  echo
  total=$(( ${#caps[@]} * ${#COLUMNS[@]} ))
  done_count=0; partial=0; gaps=0; na=0
  for c in "${COLUMNS[@]}"; do
    for cap in "${caps[@]}"; do
      case "$(fact_get KIND "$c" "$cap")" in
        implemented) done_count=$((done_count+1)) ;;
        partial) partial=$((partial+1)) ;;
        gap) gaps=$((gaps+1)) ;;
        "n/a") na=$((na+1)) ;;
      esac
    done
  done
  echo "$done_count/$total implemented, $partial partial, $gaps gaps, $na n/a"
fi

if [[ ${#errors[@]} -gt 0 ]]; then
  echo >&2
  for e in "${errors[@]}"; do echo "parity: $e" >&2; done
  echo "PARITY_INVALID" >&2
  exit 1
fi
[[ $CHECK -eq 0 ]] && echo "PARITY_OK"
exit 0
