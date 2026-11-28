#!/usr/bin/env bash
# Translates the keys the Swift sources use that the catalog lacks, through a delegate answer packet.
#
#   scripts/l10n-delegate.sh REV   the keys the sources gained since REV, usually the last release tag
#
# The model is asked once, for the missing keys only, with the catalog's own words for the terms in
# them. delegate refuses an answer that drops or invents a key, and `l10n-check.py --add` refuses one
# that lacks a language or changes a format specifier, so what lands in the catalog has passed both.
# The patch arrives unstaged; nothing here commits.
set -euo pipefail

[ $# -eq 1 ] || { echo "usage: scripts/l10n-delegate.sh REV" >&2; exit 2; }
cd "$(dirname "$0")/.."
work=".delegate/l10n"
mkdir -p "$work"
scripts/l10n-check.py --pending --since "$1" > "$work/pending.json"
count=$(python3 -c 'import json, sys; print(len(json.load(open(sys.argv[1]))))' "$work/pending.json")
if [ "$count" -eq 0 ]; then
    echo "nothing to translate"
    rm -rf "$work"
    rmdir .delegate 2>/dev/null || true
    exit 0
fi
scripts/l10n-check.py --glossary "$work/pending.json" > "$work/glossary.json"
languages=$(python3 -c 'import re, sys; print(", ".join(l for l in re.search(r"LANGUAGES = \[(.*?)\]", open(sys.argv[1]).read()).group(1).replace(chr(34), "").split(", ") if l != "en"))' scripts/l10n-check.py)
status=0
delegate new --class l10n \
    --goal "Translate $count UI strings of Tailscode, an app for running coding agents on your own machines, from English. Each key of the INPUT is an English string. Answer with the same keys, each mapped to an object holding its translation for every one of these language codes: $languages. Keep every format specifier (%@, %lld, %1\$@) exactly as written, and number them (%1\$@, %2\$lld) when a translation has to reorder two or more. Keep the ellipsis character, keep product and model names in English, and match the source's tone, capitalisation and length. Where an INPUT string uses a term from the glossary, use the glossary's translation of it." \
    --read "$work/glossary.json" \
    --input "$work/pending.json" --answer "$work/answer.json" \
    --verify 'scripts/l10n-check.py --add "$DELEGATE_ANSWER" && scripts/l10n-check.py --roundtrip' \
    --path "$work/answer.json" --path Resources/Localizable.xcstrings \
    -o "$work/packet.yml" --run -y || status=$?
rm -rf "$work"
rmdir .delegate 2>/dev/null || true
exit "$status"
