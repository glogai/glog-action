"""Check that every variable a step's script reads is defined for that step.

Written after a step lost it: the report commit used to get its git identity
from `git config --global` set by an earlier step, and when that config moved
onto the commit command itself the two variables it reads -- GLOG_ACTOR and
GLOG_ACTOR_ID -- were dropped from the only `env:` block that defined them. The
step then ran `git -c user.name="" ... commit`, which git refuses with "empty
ident name", so every scan that produced a report failed at the end of a run
that had otherwise succeeded. Nothing in this repository executes action.yml,
so no test noticed.

Each `run:` script is a separate process. It sees the names on its own step's
`env:`, the names the workflow writes to $GITHUB_ENV, and the names it assigns
itself -- nothing else. This test resolves every `$NAME` / `${NAME}` reference
in the file against exactly those three sources, plus the names the runner
provides, and fails on anything left over.

PyYAML is not otherwise needed by these tests, so a checkout without it skips
rather than errors.
"""
from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path

try:
    import yaml
except ImportError:  # pragma: no cover - depends on the checkout
    yaml = None

ACTION = Path(__file__).resolve().parent.parent / "action.yml"

# Names the runner supplies. A reference to one of these is not a step's
# dependency, so it is not this test's business.
RUNNER_PROVIDED = {
    "CI", "HOME", "HOSTNAME", "LANG", "LC_ALL", "PATH", "PWD", "SHELL",
    "TERM", "TMPDIR", "USER",
}
RUNNER_PREFIXES = ("GITHUB_", "RUNNER_", "INPUT_", "ACTIONS_")

REFERENCE = re.compile(r"\$\{([A-Z_][A-Z0-9_]*)\}|\$([A-Z_][A-Z0-9_]*)")
ASSIGNMENT = re.compile(r"^\s*(?:export\s+|declare\s+|local\s+)?([A-Z_][A-Z0-9_]*)=", re.M)
# A name becomes visible to later steps only by being written to one of these
# files; an `echo "NAME=..."` that goes to stdout publishes nothing.
PUBLISH = re.compile(r"""^\s*(?:echo|printf)\b.*>>\s*["']?\$GITHUB_(?:ENV|OUTPUT)\b""", re.M)
PUBLISHED_NAME = re.compile(r"""^\s*(?:echo|printf)\s+["']?([A-Z_][A-Z0-9_]*)=""")


def published_names(script: str) -> set[str]:
    names = set()
    for line in script.splitlines():
        if PUBLISH.match(line):
            m = PUBLISHED_NAME.match(line)
            if m:
                names.add(m.group(1))
    return names


def undefined_in(step: dict, seen: set[str]) -> set[str]:
    """Names a step's script reads that nothing has defined for it."""
    script = step.get("run")
    if not isinstance(script, str):
        return set()
    defined = set((step.get("env") or {}).keys())
    defined |= set(ASSIGNMENT.findall(script))
    defined |= seen
    out = set()
    for braced, bare in REFERENCE.findall(script):
        name = braced or bare
        if name in defined or name in RUNNER_PROVIDED:
            continue
        if name.startswith(RUNNER_PREFIXES):
            continue
        out.add(name)
    return out


class ActionEnvTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if yaml is None:
            raise unittest.SkipTest("PyYAML is not installed")
        cls.doc = yaml.safe_load(ACTION.read_text(encoding="utf-8"))
        cls.steps = cls.doc["runs"]["steps"]

    def test_every_reference_is_defined_for_its_step(self):
        seen = set((self.doc.get("env") or {}).keys())
        problems = []
        for step in self.steps:
            for name in sorted(undefined_in(step, seen)):
                problems.append(f"{step.get('name', '<unnamed step>')} reads "
                                f"${name}, which no env: entry, assignment or "
                                f"$GITHUB_ENV write defines for it")
            # What this step publishes is available to the steps after it.
            script = step.get("run")
            if isinstance(script, str):
                seen |= published_names(script)
        self.assertEqual(problems, [], "\n  ".join([""] + problems))

    def test_the_check_notices_a_dropped_variable(self):
        """The guard's own negative control.

        Every reference above is resolved against data read out of the file, so
        a bug that stopped it reading `env:` at all would report a clean sweep.
        Strip the definitions from one step and require the names it reads to
        come back.
        """
        # Selected by what it reads rather than by its label, so renaming the
        # step does not quietly turn this control into a no-op.
        target = next(
            s for s in (dict(step) for step in self.steps)
            if s.get("env") and "GLOG_ACTOR" in (s.get("run") or "")
        )
        target.pop("env", None)
        names = undefined_in(target, set())
        self.assertEqual(names, {"GLOG_ACTOR", "GLOG_ACTOR_ID"})


if __name__ == "__main__":
    sys.exit(unittest.main())
