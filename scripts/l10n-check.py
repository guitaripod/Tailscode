#!/usr/bin/env python3
"""Keeps Resources/Localizable.xcstrings honest.

  scripts/l10n-check.py                  list every Localized.text key the Swift sources use that the catalog lacks,
                                         and every catalog entry missing a language or disagreeing on format specifiers
  scripts/l10n-check.py --strict         exit 1 when anything is listed
  scripts/l10n-check.py --since REV      only the keys the Swift sources gained since REV (the gate for a change: the
                                         catalog already carries a backlog of Linux-only strings and plural entries)
  scripts/l10n-check.py --add FILE.json  add translations: {"English key": {"de": "...", "es": "...", ...}} for the ten
                                         non-English languages (the key itself is the English text)
  scripts/l10n-check.py --roundtrip      prove the writer reproduces the committed catalog byte for byte

Every key goes in with extractionState manual, the way the existing entries are, and the file is serialised so the
entries already there stay byte-identical (check with `git diff --patience`).
"""
import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CATALOG = ROOT / "Resources" / "Localizable.xcstrings"
LANGUAGES = ["de", "en", "es", "fr", "it", "ja", "ko", "pl", "pt-BR", "zh-Hans", "zh-Hant"]
SOURCES = ["Tailscode", "TailscodeCore/Sources", "TailscodeLinux/Sources", "TailscodeMac", "TailscodeWidget", "TailscodeNSE"]
LITERAL = re.compile(r'Localized\.text\(\s*"((?:[^"\\]|\\.)*)"')
SPECIFIER = re.compile(r"%(?:\d+\$)?(?:ll|l|hh|h)?[@dDfsSuUxXcC]|%%")


def unescape(literal: str):
    if "\\(" in literal:
        return None
    return (
        literal.replace('\\"', '"')
        .replace("\\n", "\n")
        .replace("\\t", "\t")
        .replace("\\\\", "\\")
        .replace("\\u{2026}", "…")
    )


def used_keys():
    keys = {}
    for source in SOURCES:
        base = ROOT / source
        if not base.exists():
            continue
        for path in base.rglob("*.swift"):
            if "/.build/" in str(path) or "/build" in str(path.relative_to(ROOT)).split("/")[0]:
                continue
            text = path.read_text(encoding="utf-8", errors="replace")
            for match in LITERAL.finditer(text):
                key = unescape(match.group(1))
                if key:
                    keys.setdefault(key, str(path.relative_to(ROOT)))
    return keys


def load():
    return json.loads(CATALOG.read_text(encoding="utf-8"))


def dump(catalog):
    return json.dumps(catalog, indent=2, ensure_ascii=False, separators=(",", ": ")) + "\n"


def specifier_shape(text: str):
    found = [re.sub(r"\d+\$", "", s) for s in SPECIFIER.findall(text) if s != "%%"]
    return sorted(re.sub(r"ll|l|hh|h", "", s) for s in found)


def keys_since(rev: str):
    diff = subprocess.run(
        ["git", "-C", str(ROOT), "diff", "--unified=0", rev, "--", "*.swift"],
        capture_output=True, text=True, check=True,
    ).stdout
    keys = {}
    for line in diff.splitlines():
        if line.startswith("+") and not line.startswith("+++"):
            for match in LITERAL.finditer(line):
                key = unescape(match.group(1))
                if key:
                    keys[key] = rev
    return keys


def check(strict: bool, since: str = None):
    catalog = load()
    strings = catalog["strings"]
    problems = []
    scope = keys_since(since) if since else None
    for key, where in sorted((scope if scope is not None else used_keys()).items()):
        if key not in strings:
            problems.append(f"missing key: {key!r} ({where})")
    for key, entry in strings.items():
        if scope is not None and key not in scope:
            continue
        localizations = entry.get("localizations", {})
        for language in LANGUAGES:
            localized = localizations.get(language)
            if language == "en" and localized is None:
                continue
            if localized is None:
                problems.append(f"missing {language}: {key!r}")
                continue
            unit = localized.get("stringUnit", {}).get("value")
            if unit is None:
                if "variations" not in localized:
                    problems.append(f"missing {language}: {key!r}")
            elif language != "en" and specifier_shape(unit) != specifier_shape(key):
                problems.append(f"format specifiers differ in {language}: {key!r}")
    for problem in problems:
        print(problem)
    print(f"{len(problems)} problem(s) across {len(strings)} catalog entries")
    return 1 if (problems and strict) else 0


def add(path: str):
    catalog = load()
    additions = json.loads(Path(path).read_text(encoding="utf-8"))
    for key, translations in additions.items():
        missing = [language for language in LANGUAGES if language != "en" and language not in translations]
        if missing:
            sys.exit(f"{key!r} lacks {missing}")
        for language, text in translations.items():
            if language not in LANGUAGES:
                sys.exit(f"{key!r}: unknown language {language}")
            if specifier_shape(text) != specifier_shape(key):
                sys.exit(f"{key!r}: format specifiers differ in {language}")
        localizations = {"en": {"stringUnit": {"state": "translated", "value": key}}}
        for language in LANGUAGES:
            if language != "en":
                localizations[language] = {"stringUnit": {"state": "translated", "value": translations[language]}}
        catalog["strings"][key] = {"extractionState": "manual", "localizations": localizations}
    CATALOG.write_text(dump(catalog), encoding="utf-8")
    print(f"added {len(additions)} key(s)")
    return 0


def roundtrip():
    original = CATALOG.read_text(encoding="utf-8")
    same = dump(json.loads(original)) == original
    print("roundtrip: " + ("byte-identical" if same else "DIFFERENT"))
    return 0 if same else 1


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--strict", action="store_true")
    parser.add_argument("--add")
    parser.add_argument("--roundtrip", action="store_true")
    parser.add_argument("--since")
    args = parser.parse_args()
    if args.roundtrip:
        sys.exit(roundtrip())
    if args.add:
        sys.exit(add(args.add))
    sys.exit(check(args.strict, args.since))
