#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

CORE=TailscodeCore/Sources/TailscodeCore/Parity.swift
CLIENTS=(iOS linux mac)

dir_for() {
  case "$1" in
    iOS) echo Tailscode ;;
    linux) echo TailscodeLinux/Sources/TailscodeLinux ;;
    mac) echo TailscodeMac ;;
  esac
}

manifest_for() {
  case "$1" in
    iOS) echo Tailscode/App/Parity.swift ;;
    linux) echo TailscodeLinux/Sources/TailscodeLinux/Parity.swift ;;
    mac) echo TailscodeMac/Parity.swift ;;
  esac
}

fact_set() { eval "_${1}_${2}_${3}=\$4"; }
fact_get() { eval "printf '%s' \"\${_${1}_${2}_${3}:-}\""; }

CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1
errors=()

caps=($(awk '/^public enum AppCapability/,/^}/' "$CORE" | sed -n 's/^ *case \([A-Za-z]*\)$/\1/p'))
[[ ${#caps[@]} -gt 0 ]] || { echo "parity: could not parse AppCapability cases from $CORE" >&2; exit 1; }

for cap in "${caps[@]}"; do
  grep -q "id: \.$cap," "$CORE" || errors+=("registry: no CapabilityDefinition for .$cap in $CORE")
done

for c in "${CLIENTS[@]}"; do
  mf=$(manifest_for "$c")
  [[ -f "$mf" ]] || { echo "parity: missing manifest $mf" >&2; exit 1; }
  if grep -nE '(^|[^A-Za-z])default *:' "$mf" >/dev/null; then
    errors+=("$c: 'default:' found in $mf — the switch must stay exhaustive, one case per line")
  fi
  if grep -nE 'case \.[A-Za-z]+ *,' "$mf" >/dev/null; then
    errors+=("$c: grouped cases found in $mf — one case per line so the script can parse evidence")
  fi
  for cap in "${caps[@]}"; do
    line=$({ grep -A3 -E "case \.$cap:( |$)" "$mf" || true; } | tr '\n' ' ' \
      | sed -e 's/( */(/g' -e 's/  */ /g' -e 's/^ *//')
    line=${line%% case .*}
    if [[ -z "$line" ]]; then
      errors+=("$c: no answer for .$cap in $mf")
      fact_set KIND "$c" "$cap" "?"
      continue
    fi
    case "$line" in
      *".implemented("*)
        fact_set KIND "$c" "$cap" "implemented"
        fact_set ANCHOR "$c" "$cap" "$(sed 's/.*\.implemented("\([^"]*\)").*/\1/' <<<"$line")"
        ;;
      *".partial("*)
        fact_set KIND "$c" "$cap" "partial"
        fact_set ANCHOR "$c" "$cap" "$(sed 's/.*\.partial("\([^"]*\)".*/\1/' <<<"$line")"
        fact_set NOTE "$c" "$cap" "$(sed 's/.*missing: "\([^"]*\)").*/\1/' <<<"$line")"
        ;;
      *".gap("*)
        fact_set KIND "$c" "$cap" "gap"
        fact_set NOTE "$c" "$cap" "$(sed 's/.*\.gap("\([^"]*\)").*/\1/' <<<"$line")"
        ;;
      *".notApplicable("*)
        fact_set KIND "$c" "$cap" "n/a"
        fact_set NOTE "$c" "$cap" "$(sed 's/.*\.notApplicable("\([^"]*\)").*/\1/' <<<"$line")"
        ;;
      *)
        errors+=("$c: unparseable evidence for .$cap: $line")
        fact_set KIND "$c" "$cap" "?"
        ;;
    esac
    anchor=$(fact_get ANCHOR "$c" "$cap")
    if [[ -n "$anchor" ]]; then
      if ! grep -rF --include='*.swift' --exclude='Parity.swift' -l -- "$anchor" "$(dir_for "$c")" >/dev/null; then
        errors+=("$c: anchor '$anchor' for .$cap not found anywhere under $(dir_for "$c")")
      fi
    fi
    note=$(fact_get NOTE "$c" "$cap")
    if [[ "$(fact_get KIND "$c" "$cap")" != "implemented" && -z "$note" ]]; then
      errors+=("$c: .$cap is $(fact_get KIND "$c" "$cap") but carries no reason")
    fi
  done
done

if [[ $CHECK -eq 0 ]]; then
  printf '%-24s %-12s %-12s %-12s\n' "capability" "iOS" "linux" "mac"
  printf '%-24s %-12s %-12s %-12s\n' "----------" "---" "-----" "---"
  for cap in "${caps[@]}"; do
    row=()
    for c in "${CLIENTS[@]}"; do
      case "$(fact_get KIND "$c" "$cap")" in
        implemented) row+=("ok") ;;
        partial) row+=("PARTIAL") ;;
        gap) row+=("GAP") ;;
        "n/a") row+=("n/a") ;;
        *) row+=("??") ;;
      esac
    done
    printf '%-24s %-12s %-12s %-12s\n' "$cap" "${row[0]}" "${row[1]}" "${row[2]}"
  done
  echo
  for c in "${CLIENTS[@]}"; do
    for cap in "${caps[@]}"; do
      k=$(fact_get KIND "$c" "$cap")
      if [[ "$k" == "gap" || "$k" == "partial" ]]; then
        echo "$c .$cap ($k): $(fact_get NOTE "$c" "$cap")"
      fi
    done
  done
  echo
  total=$(( ${#caps[@]} * ${#CLIENTS[@]} ))
  done_count=0; partial=0; gaps=0; na=0
  for c in "${CLIENTS[@]}"; do
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
