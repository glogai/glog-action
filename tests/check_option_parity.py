#!/usr/bin/env python3
"""Fail when glog.sh and glog.ps1 do not offer the same interface.

The two scripts are hand-maintained ports of each other: the CI entry points
call glog.sh on Linux and glog.ps1 on Windows, so an option -- or an environment
variable forwarded into the scanner containers -- that exists in only one of
them is a scan that silently behaves differently per platform.

Two independent checks, both comparing glog.sh (the reference) with glog.ps1:

  options   the option literals declared in each argument parser
  env       the NAME of every `-e NAME=...` handed to `docker run`

The option check reads case/switch label position rather than every token in the
region, which is what keeps the parser's own helpers (`read -r -a FILES`) and the
command words (`clean|scan)`) out of the comparison.

Usage: python3 tests/check_option_parity.py [--action-dir DIR]
Exit: 0 when both surfaces match, 1 when they do not (prints the difference).
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

# A case/switch LABEL, which is the only place an option literal is declared:
#   bash: `-u|--upload) ...`   pwsh: `'--upload' {`
BASH_LABEL = re.compile(r"^\s*([^()]+)\)")
PSH_LABEL = re.compile(r"^\s*'([^']+)'\s*\{\s*$")
# The shape of an option, once split out of an alternation: this is what stops a
# body line that happens to carry a parenthesis from contributing a token.
OPTION = re.compile(r"^--?[a-zA-Z][a-zA-Z0-9-]*$")

# The loop that walks the arguments. Both scripts wrap it in a known
# opener/closer pair; everything between is the case/switch body.
REGIONS = {
    "glog.sh": (r'while \[\[ \$# -gt 0 \]\]; do', r'^done$', BASH_LABEL),
    "glog.ps1": (r'while \(\$index -lt \$scriptArgs\.Count\) \{', r'^}$', PSH_LABEL),
}

# The container environment, which decides as much of a scan's behaviour as the
# options do. Both spellings count, on both surfaces: `-e NAME=value` (bash,
# quoted or not) and `'-e', "NAME=..."` / `('-e', ("NAME=" + ...` (pwsh) set the
# variable from the argument, while a bare `-e NAME` copies it from the shell's
# own environment. glog.sh uses the bare form for the two credentials on purpose
# -- spelled `=value` the token lands in the docker-run argv, where any process
# on the host can read it out of `ps`. A reader that only knew the first
# spelling reads that as the variable having been dropped, and fails.
ENV_READERS = {
    "glog.sh": re.compile(r"""-e\s+"?([A-Z][A-Z0-9_]*)"?(?=[=\s\\]|$)"""),
    "glog.ps1": re.compile(r"""'-e',\s*\(?["']([A-Z][A-Z0-9_]*)["']?(?=[=\s),]|$)"""),
}

# There are no deliberate one-sided names on either surface today. If one ever
# needs to exist, add it here with the reason -- not to a blocklist in the
# comparison, so that the reason travels with the name.
ENV_EXCEPTIONS: dict[str, tuple[str, str]] = {}


def parser_region(text: str, opener: str, closer: str) -> str:
    m = re.search(opener, text, re.MULTILINE)
    if not m:
        raise SystemExit(f"could not find the argument parser opener: {opener!r}")
    rest = text[m.end():]
    end = re.search(closer, rest, re.MULTILINE)
    if not end:
        raise SystemExit(f"could not find the argument parser close: {closer!r}")
    return rest[: end.start()]


def declared_options(text: str, opener: str, closer: str, label_re: re.Pattern) -> set[str]:
    region = parser_region(text, opener, closer)
    found: set[str] = set()
    for line in region.splitlines():
        m = label_re.match(line)
        if not m:
            continue
        # bash labels are an alternation; pwsh labels are already single tokens.
        for token in m.group(1).split("|"):
            token = token.strip()
            if OPTION.match(token):
                found.add(token)
    return found


def forwarded_env(text: str, pattern: re.Pattern) -> set[str]:
    return set(pattern.findall(text))


def compare(label: str, shell: set[str], pwsh: set[str], exceptions: dict | None = None) -> int:
    exceptions = exceptions or {}
    only_shell = sorted(shell - pwsh - {n for n, (side, _) in exceptions.items() if side == "glog.sh"})
    only_pwsh = sorted(pwsh - shell - {n for n, (side, _) in exceptions.items() if side == "glog.ps1"})
    stale = sorted(n for n, (side, _) in exceptions.items() if not ((side == "glog.sh" and n in shell and n not in pwsh)
                                                                  or (side == "glog.ps1" and n in pwsh and n not in shell)))

    print(f"{label}: glog.sh {len(shell)}, glog.ps1 {len(pwsh)}")
    for name, (side, why) in sorted(exceptions.items()):
        print(f"  known difference: {name} only in {side} - {why}")
    failed = False
    if only_shell:
        print(f"  only in glog.sh ({len(only_shell)}): {' '.join(only_shell)}")
        failed = True
    if only_pwsh:
        print(f"  only in glog.ps1 ({len(only_pwsh)}): {' '.join(only_pwsh)}")
        failed = True
    if stale:
        print(f"  stale exception ({len(stale)}): {' '.join(stale)} - now present on both sides, "
              f"remove it from the exception table")
        failed = True
    if not failed:
        print("  parity OK")
    return 1 if failed else 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--action-dir", default=str(Path(__file__).resolve().parent.parent))
    args = ap.parse_args()
    root = Path(args.action_dir)

    sources = {}
    for name in REGIONS:
        path = root / name
        if not path.is_file():
            raise SystemExit(f"missing {path}")
        sources[name] = path.read_text(encoding="utf-8")

    option_sets = {
        name: declared_options(sources[name], *REGIONS[name]) for name in REGIONS
    }
    env_sets = {
        name: forwarded_env(sources[name], ENV_READERS[name]) for name in REGIONS
    }

    status = 0
    status |= compare("options", option_sets["glog.sh"], option_sets["glog.ps1"])
    status |= compare("container env", env_sets["glog.sh"], env_sets["glog.ps1"], ENV_EXCEPTIONS)
    return status


if __name__ == "__main__":
    sys.exit(main())
