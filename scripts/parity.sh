#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

CORE=TailscodeCore/Sources/TailscodeCore/Parity.swift
CLIENTS=(iOS linux mac)
declare -A DIRS=([iOS]=Tailscode [linux]=TailscodeLinux/Sources/TailscodeLinux [mac]=TailscodeMac)
declare -A MANIFESTS=(
  [iOS]=Tailscode/App/Parity.swift
  [linux]=TailscodeLinux/Sources/TailscodeLinux/Parity.swift
  [mac]=TailscodeMac/Parity.swift
)

CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1
errors=()

say() { [[ $CHECK -eq 0 ]] && echo "$@" || true; }

mapfile -t caps < <(awk '/^public enum AppCapability/,/^}/' "$CORE" | sed -n 's/^ *case \([A-Za-z]*\)$/\1/p')
[[ ${#caps[@]} -gt 0 ]] || { echo "parity: could not parse AppCapability cases from $CORE" >&2; exit 1; }

for cap in "${caps[@]}"; do
  grep -q "id: \.$cap," "$CORE" || errors+=("registry: no CapabilityDefinition for .$cap in $CORE")
done

declare -A KIND ANCHOR NOTE
for c in "${CLIENTS[@]}"; do
  mf="${MANIFESTS[$c]}"
  [[ -f "$mf" ]] || { echo "parity: missing manifest $mf" >&2; exit 1; }
  grep -nE '(^|[^A-Za-z])default *:' "$mf" >/dev/null && errors+=("$c: 'default:' found in $mf — the switch must stay exhaustive, one case per line")
  grep -nE 'case \.[A-Za-z]+ *,' "$mf" >/dev/null && errors+=("$c: grouped cases found in $mf — one case per line so the script can parse evidence")
  for cap in "${caps[@]}"; do
    line=$(grep -A3 -E "case \.$cap:( |$)" "$mf" | tr '\n' ' ' \
      | sed -e 's/( */(/g' -e 's/  */ /g' -e 's/^ *//')
    line=${line%% case .*}
    if [[ -z "$line" ]]; then
      errors+=("$c: no answer for .$cap in $mf")
      KIND[$c/$cap]="?"
      continue
    fi
    case "$line" in
      *".implemented("*)
        KIND[$c/$cap]="implemented"
        ANCHOR[$c/$cap]=$(sed 's/.*\.implemented("\([^"]*\)").*/\1/' <<<"$line")
        ;;
      *".partial("*)
        KIND[$c/$cap]="partial"
        ANCHOR[$c/$cap]=$(sed 's/.*\.partial("\([^"]*\)".*/\1/' <<<"$line")
        NOTE[$c/$cap]=$(sed 's/.*missing: "\([^"]*\)").*/\1/' <<<"$line")
        ;;
      *".gap("*)
        KIND[$c/$cap]="gap"
        NOTE[$c/$cap]=$(sed 's/.*\.gap("\([^"]*\)").*/\1/' <<<"$line")
        ;;
      *".notApplicable("*)
        KIND[$c/$cap]="n/a"
        NOTE[$c/$cap]=$(sed 's/.*\.notApplicable("\([^"]*\)").*/\1/' <<<"$line")
        ;;
      *)
        errors+=("$c: unparseable evidence for .$cap: $line")
        KIND[$c/$cap]="?"
        ;;
    esac
    anchor="${ANCHOR[$c/$cap]:-}"
    if [[ -n "$anchor" ]]; then
      if ! grep -rF --include='*.swift' --exclude='Parity.swift' -l -- "$anchor" "${DIRS[$c]}" >/dev/null; then
        errors+=("$c: anchor '$anchor' for .$cap not found anywhere under ${DIRS[$c]}")
      fi
    fi
    note="${NOTE[$c/$cap]:-}"
    if [[ "${KIND[$c/$cap]}" != "implemented" && -z "$note" ]]; then
      errors+=("$c: .$cap is ${KIND[$c/$cap]} but carries no reason")
    fi
  done
done

if [[ $CHECK -eq 0 ]]; then
  printf '%-24s %-12s %-12s %-12s\n' "capability" "iOS" "linux" "mac"
  printf '%-24s %-12s %-12s %-12s\n' "----------" "---" "-----" "---"
  for cap in "${caps[@]}"; do
    row=()
    for c in "${CLIENTS[@]}"; do
      case "${KIND[$c/$cap]}" in
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
      k="${KIND[$c/$cap]}"
      if [[ "$k" == "gap" || "$k" == "partial" ]]; then
        echo "$c .$cap ($k): ${NOTE[$c/$cap]:-}"
      fi
    done
  done
  echo
  total=$(( ${#caps[@]} * ${#CLIENTS[@]} ))
  done_count=0; partial=0; gaps=0; na=0
  for k in "${KIND[@]}"; do
    case "$k" in
      implemented) done_count=$((done_count+1)) ;;
      partial) partial=$((partial+1)) ;;
      gap) gaps=$((gaps+1)) ;;
      "n/a") na=$((na+1)) ;;
    esac
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
