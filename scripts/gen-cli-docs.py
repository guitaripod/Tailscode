#!/usr/bin/env python3
"""Write the man page and the shell completions from the flags the binary actually accepts.

`tailscode --help` and the option set `main.swift` validates against are the two places the CLI is
already spelled out; a hand-written man page is a third that drifts within two releases. This reads
both and generates the rest, so a flag that is added or dropped changes every surface at once.
"""
from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LINUX = ROOT / "TailscodeLinux" / "Sources" / "TailscodeLinux"
OUT = ROOT / "packaging" / "linux"

DESCRIPTIONS = {
    "--ask": "Open the question box, raising the running window first. Bind this to a key.",
    "--connect": "Save a server by address and open it, without touching the setup screen.",
    "--demo": "Open the scripted demo world: two sample servers, no tailnet, nothing real.",
    "--force-desktop": "Render a build from .build/ on the real session anyway.",
    "--help": "Print the usage summary and exit.",
    "--name": "The name to file the server under, with --connect.",
    "--opencode": "Treat the address given to --connect as an opencode server.",
    "--password": "The server's password, with --connect. Prefer TAILSCODE_PASSWORD: an argument "
                  "is readable by every process on the machine.",
    "--probe-newchat": "Time the new-chat path end to end and print where it went.",
    "--selftest": "Check the whole chain with no display, and exit non-zero on the first failure.",
    "--themes": "Print every theme's palette, as corrected, with each slot's measured contrast.",
    "--version": "Print the version and exit.",
}


def read(path: Path) -> str:
    return (LINUX / path).read_text()


def version() -> str:
    found = re.search(r'static let current = "([^"]+)"', read(Path("TailscodeVersion.swift")))
    return found.group(1) if found else "0"


def usage() -> list[str]:
    body = read(Path("TailscodeVersion.swift"))
    block = re.search(r'static let usage = """\n(.*?)\n\s*"""', body, re.S)
    return [line.strip() for line in block.group(1).splitlines()] if block else []


def flags() -> list[str]:
    body = read(Path("main.swift"))
    block = re.search(r"let knownOptions: Set<String> = \[(.*?)\]", body, re.S)
    found = re.findall(r'"(-[^"]+)"', block.group(1)) if block else []
    return sorted(set(found))


def date() -> str:
    return subprocess.run(["git", "-C", str(ROOT), "log", "-1", "--format=%cs"],
                          capture_output=True, text=True, check=True).stdout.strip()


def man() -> str:
    lines = [
        f'.TH TAILSCODE 1 "{date()}" "tailscode {version()}" "User Commands"',
        ".SH NAME",
        "tailscode \\- drive your coding agents over Tailscale",
        ".SH SYNOPSIS",
        ".B tailscode",
        ".RI [ options ]",
        ".SH DESCRIPTION",
        "Tailscode is a GTK4 client for the coding agents running on your other machines: Claude",
        "Code through claude\\-bridge, and opencode. The agent stays where your code is; this is the",
        "window onto it, over your own tailnet.",
        ".PP",
        "Running it with no arguments opens the window. A second launch raises the window that",
        "already exists rather than starting a second app.",
        ".SH OPTIONS",
    ]
    for flag in flags():
        if flag == "-h":
            continue
        head = f"\\fB{flag}\\fR"
        if flag == "-h" or flag == "--help":
            head = "\\fB\\-h\\fR, \\fB\\-\\-help\\fR"
        lines += [".TP", head, DESCRIPTIONS.get(flag, "")]
    lines += [
        ".SH ENVIRONMENT",
        ".TP",
        "\\fBTAILSCODE_PASSWORD\\fR",
        "The password for \\fB\\-\\-connect\\fR, kept out of the process list.",
        ".TP",
        "\\fBTAILSCODE_TRACE\\fR",
        "Print timing for the paths that have been slow before: startup, new chat, streaming.",
        ".SH FILES",
        ".TP",
        ".I $XDG_CONFIG_HOME/tailscode/settings.json",
        "Every preference, the servers, and the layout the window was left in.",
        ".TP",
        ".I $XDG_STATE_HOME/tailscode/tailscode.log",
        "The diagnostics log, rotated at a size cap and kept one generation deep.",
        ".SH SEE ALSO",
        "The project page: https://github.com/guitaripod/Tailscode",
    ]
    return "\n".join(lines) + "\n"


def bash_completion() -> str:
    return f"""_tailscode() {{
    local cur="${{COMP_WORDS[COMP_CWORD]}}"
    COMPREPLY=($(compgen -W "{' '.join(flags())}" -- "$cur"))
}}
complete -F _tailscode tailscode
"""


def zsh_completion() -> str:
    entries = "\n".join(
        f"    '{flag}[{DESCRIPTIONS.get(flag, '').replace(chr(39), '')}]'" for flag in flags())
    return f"""#compdef tailscode

_arguments -s \\
{entries}
"""


def fish_completion() -> str:
    lines = []
    for flag in flags():
        if not flag.startswith("--"):
            continue
        note = DESCRIPTIONS.get(flag, "").replace("'", "")
        lines.append(f"complete -c tailscode -l {flag[2:]} -d '{note}'")
    return "\n".join(lines) + "\n"


def main() -> int:
    if not flags():
        print("!! could not read knownOptions from main.swift", file=sys.stderr)
        return 1
    (OUT / "completions").mkdir(parents=True, exist_ok=True)
    (OUT / "tailscode.1").write_text(man())
    (OUT / "completions" / "tailscode.bash").write_text(bash_completion())
    (OUT / "completions" / "_tailscode").write_text(zsh_completion())
    (OUT / "completions" / "tailscode.fish").write_text(fish_completion())
    print(f"wrote man page and completions for {len(flags())} flags")
    return 0


if __name__ == "__main__":
    sys.exit(main())
