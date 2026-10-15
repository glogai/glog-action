#!/usr/bin/env python3
"""Exercise glog.ps1's scan flow against a stub docker, with no containers.

The Windows entry point runs scanners it cannot be unit-tested against from
here, so the parts that decide *what* to run -- the resolver's one- and two-pass
modes, the exit codes, the environment handed to each container and the rebuild
call -- are checked by recording the docker argv instead of executing it.

Run: python3 -m unittest discover -s tests -v
Needs pwsh on PATH; skips (not fails) when it is missing.
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ACTION_DIR = Path(__file__).resolve().parent.parent
GLOG_PS1 = ACTION_DIR / "glog.ps1"

DOCKER_STUB = r"""#!/bin/bash
# Record the invocation, then do the two things the scan flow reads back: the
# resolver's SARIF artifact, and (on request) an UPLOAD_FAILED line.
{
  echo '##CALL'
  # printf, not echo: `echo "-e"` prints an empty line, and "-e" is an argument
  # this stub exists to record.
  for a in "$@"; do printf '%s\n' "$a"; done
} >> "$STUB_LOG"

mount=''
image=''
for a in "$@"; do
  case "$a" in
    *:/app) mount="${a%:/app}" ;;
  esac
  image="$a"
done
if [[ -n "${STUB_DOCKER_FAIL:-}" && "$image" == *"$STUB_DOCKER_FAIL"* ]]; then
  exit 7
fi
mkdir -p "$mount/.glog"
if [[ "$image" == *resolver* ]]; then
  if [[ "${STUB_NO_SARIF:-}" != "1" ]]; then
    printf '{"runs":[{"results":[]}]}\n' > "$mount/.glog/glog-scan.sarif"
  fi
  if [[ -n "${STUB_UPLOAD_FAILED:-}" ]]; then
    printf 'UPLOAD_FAILED | details=[stub upload refused]\n' >> "$mount/.glog/glog-scan.log"
  fi
fi
if [[ "$image" == *sbom* ]]; then
  printf '{"bomFormat":"CycloneDX"}\n' > "$mount/.glog/sbom.cdx.json"
fi
exit 0
"""

CURL_STUB = r"""#!/bin/bash
# Serve the SBOM quality / VEX / CBOM responses: body to the -o target, HTTP
# code on stdout (that is what the callers read).
out=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -w) shift 2 ;;
    *) shift ;;
  esac
done
body="${STUB_CURL_BODY:-}"
# Not ${STUB_CURL_BODY:-{}}: that default swallows one brace and appends the
# other, which yields unparseable JSON.
[[ -z "$body" ]] && body='{}'
[[ -n "$out" ]] && printf '%s' "$body" > "$out"
printf '%s' "${STUB_CURL_CODE:-200}"
"""

PYTHON_STUB = r"""#!/bin/bash
{
  echo '##PYCALL'
  for a in "$@"; do printf '%s\n' "$a"; done
} >> "$STUB_LOG"
exit 0
"""


def _which_pwsh() -> str | None:
    return shutil.which("pwsh")


@unittest.skipIf(_which_pwsh() is None, "pwsh is not installed")
class ScanFlowTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory(prefix="glog-ps1-flow-")
        self.root = Path(self.tmp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.log = self.root / "calls.log"
        self.log.write_text("")
        for name, body in (("docker", DOCKER_STUB), ("curl.exe", CURL_STUB), ("python3", PYTHON_STUB)):
            path = self.bin / name
            path.write_text(body)
            path.chmod(0o755)
        self.project = self.root / "project"
        self.project.mkdir()
        (self.project / "app.kt").write_text("fun main() {}\n")

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def run_ps1(self, *args: str, env: dict[str, str] | None = None) -> subprocess.CompletedProcess:
        full_env = dict(os.environ)
        full_env["PATH"] = f"{self.bin}{os.pathsep}{full_env['PATH']}"
        full_env["STUB_LOG"] = str(self.log)
        # Keep the caller's environment -- including any real token -- from
        # leaking into the scan under test: every one of these changes what the
        # flow does, and two of the cases below assert on their absence.
        for leaked in ("GLOG_TOKEN", "GLOGSERVICE", "GLOG_API_URL", "SERVER_SARIF_FORMAT_TYPE",
                       "GLOG_SBOM_MIN_GRADE", "FAIL_ON_UPLOAD_ERROR", "SUPPLY_CHAIN_ENABLED",
                       "SUPPLY_CHAIN_POLICY", "SUPPLY_CHAIN_OFFLINE", "SUPPLY_CHAIN_CACHE_ONLY",
                       "SUPPLY_CHAIN_FAIL_ON", "SUPPLY_CHAIN_FORMAT", "MOCK_RESOLVER", "REBUILD",
                       "REBUILD_IMAGE", "REBUILD_MAX_PACKAGES", "GLOG_DEPSCAN_VDB_VOLUME",
                       "VDB_APP_ONLY", "VDB_HOME", "VDB_DATABASE_URL", "VDB_AGE_HOURS"):
            full_env.pop(leaked, None)
        if env:
            full_env.update(env)
        return subprocess.run(
            ["pwsh", "-NoProfile", "-File", str(GLOG_PS1), *args],
            cwd=str(self.root), env=full_env, capture_output=True, text=True, timeout=300,
        )

    def calls(self) -> list[dict]:
        """The recorded docker invocations, in order."""
        out: list[dict] = []
        current: list[str] | None = None
        for line in self.log.read_text().splitlines():
            if line == "##CALL":
                current = []
                out.append({"args": current})
                continue
            if line == "##PYCALL":
                current = None
                continue
            if current is not None:
                current.append(line)
        for call in out:
            args = call["args"]
            # The image carries the registry prefix; compare bare names.
            call["image"] = (args[-1] if args else "").removeprefix("ghcr.io/glogai/")
            call["env"] = {}
            for i, arg in enumerate(args[:-1]):
                if arg == "-e" and i + 1 < len(args):
                    name, _, value = args[i + 1].partition("=")
                    call["env"][name] = value
        return out

    def images(self) -> list[str]:
        return [c["image"] for c in self.calls()]

    def resolver_calls(self) -> list[dict]:
        return [c for c in self.calls() if "resolver" in c["image"]]

    def scan_args(self, *extra: str) -> tuple[str, ...]:
        return ("scan", "--path", str(self.project), "--lang", "kotlin", *extra)

    # --- argument surface -------------------------------------------------

    def test_help_lists_the_options_ported_from_glog_sh(self) -> None:
        result = self.run_ps1("--help")
        self.assertEqual(result.returncode, 0, result.stderr)
        for option in ("--server-sarif-format-type", "--sbom-min-grade", "--fail-on-upload-error",
                       "--supply-chain-fail-on", "--supply-chain-format", "--rebuild-package",
                       "--max-packages", "--privacy-tier", "--mock-resolver", "--api-url"):
            self.assertIn(option, result.stdout)

    def test_unknown_option_fails_with_usage(self) -> None:
        result = self.run_ps1("scan", "--not-an-option")
        self.assertEqual(result.returncode, 1)

    def test_invalid_supply_chain_threshold_fails_before_any_container(self) -> None:
        result = self.run_ps1(*self.scan_args("--supply-chain-fail-on", "SEVERE"))
        self.assertEqual(result.returncode, 1)
        self.assertIn("Invalid --supply-chain-fail-on", result.stderr)
        self.assertEqual(self.calls(), [])

    def test_api_url_conflict_with_client_env_is_refused(self) -> None:
        result = self.run_ps1(*self.scan_args("--upload", "--client", "acme", "--env", "dev",
                                              "--api-url", "https://elsewhere.example"))
        self.assertEqual(result.returncode, 1)
        self.assertIn("the resolver will upload to https://acme.dev.glog.ai", result.stderr)
        self.assertEqual(self.calls(), [])

    def test_api_url_for_localhost_env_is_accepted_and_forwarded(self) -> None:
        result = self.run_ps1(*self.scan_args("--upload", "--client", "acme", "--env", "localhost",
                                              "--api-url", "http://acme.localhost:8000/api"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls()[0]["env"]["GLOG_API_URL"], "http://acme.localhost:8000/api")

    # --- resolver passes --------------------------------------------------

    def test_plain_scan_runs_every_scanner_offline_and_the_resolver_once(self) -> None:
        result = self.run_ps1(*self.scan_args())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.images(), ["glog-scan-kotlin-d734", "glog-scan-resolver-fbbb"])
        for call in self.calls():
            self.assertEqual(call["env"]["RESOLVER_UPLOAD"], "false")
        self.assertEqual(self.resolver_calls()[0]["env"]["SARIF_FORMAT_TYPE"], "GITHUB")

    def test_containers_receive_the_supply_chain_and_timeout_environment(self) -> None:
        result = self.run_ps1(*self.scan_args("--supply-chain", "--supply-chain-policy", "policy.json",
                                              "--supply-chain-offline", "--supply-chain-cache-only",
                                              "--supply-chain-fail-on", "HIGH",
                                              "--supply-chain-format", "sarif"))
        self.assertEqual(result.returncode, 0, result.stderr)
        env = self.calls()[0]["env"]
        self.assertEqual(env["SUPPLY_CHAIN_ENABLED"], "true")
        self.assertEqual(env["SUPPLY_CHAIN_POLICY"], "policy.json")
        self.assertEqual(env["SUPPLY_CHAIN_OFFLINE"], "true")
        self.assertEqual(env["SUPPLY_CHAIN_CACHE_ONLY"], "true")
        self.assertEqual(env["SUPPLY_CHAIN_FAIL_ON"], "HIGH")
        self.assertEqual(env["SUPPLY_CHAIN_FORMAT"], "sarif")
        self.assertEqual(env["GLOG_TRIAGE_TIMEOUT_MINUTES"], "1440")
        self.assertEqual(env["GLOG_SOCKET_TIMEOUT_MS"], "1800000")
        self.assertEqual(env["GLOG_CONNECT_TIMEOUT_MS"], "60000")
        self.assertEqual(env["GLOG_CONNECTION_REQUEST_TIMEOUT_MS"], "60000")
        self.assertEqual(env["GLOG_DEDUP_STATEMENT_SCOPE_ELEMENT_SPLIT"], "false")

    def test_server_format_runs_the_resolver_twice_once_uploading_once_offline(self) -> None:
        result = self.run_ps1(*self.scan_args("--upload", "--client", "acme", "--env", "dev",
                                              "--server-sarif-format-type", "SARIF",
                                              "--privacy-tier", "metrics"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.images(), ["glog-scan-kotlin-d734",
                                         "glog-scan-resolver-fbbb",
                                         "glog-scan-resolver-fbbb"])
        server, local = self.resolver_calls()
        self.assertEqual((server["env"]["SARIF_FORMAT_TYPE"], server["env"]["RESOLVER_UPLOAD"],
                          server["env"]["PRIVACY_TIER"]), ("SARIF", "true", "metrics"))
        self.assertEqual((local["env"]["SARIF_FORMAT_TYPE"], local["env"]["RESOLVER_UPLOAD"],
                          local["env"]["PRIVACY_TIER"]), ("GITHUB", "false", "none"))
        # The re-formatting pass must not carry anything that could upload twice.
        self.assertEqual(self.calls()[0]["env"]["RESOLVER_UPLOAD"], "false")

    def test_server_format_without_upload_stays_a_single_pass(self) -> None:
        result = self.run_ps1(*self.scan_args("--server-sarif-format-type", "SARIF"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.resolver_calls()), 1)
        self.assertEqual(self.resolver_calls()[0]["env"]["SARIF_FORMAT_TYPE"], "GITHUB")

    # --- exit codes -------------------------------------------------------

    def test_missing_artifacts_fail_the_step(self) -> None:
        result = self.run_ps1(*self.scan_args(), env={"STUB_NO_SARIF": "1"})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("SARIF results are missing", result.stderr)

    def test_sbom_gate_failure_exits_three(self) -> None:
        body = '{"gate":"fail","grade":"D","score":0.4,"categories":[{"label":"licenses","applicable":true,"score":0,"detail":"none"}],"caps":[{"max_grade":"C","reason":"no license"}]}'
        # The gate needs a server URL and a token, the same two things glog.sh's
        # sbom_quality_gate() needs before it will score anything.
        result = self.run_ps1(*self.scan_args("--sbom-min-grade", "A", "--client", "acme", "--env", "dev"),
                              env={"STUB_CURL_BODY": body, "STUB_CURL_CODE": "200", "GLOG_TOKEN": "stub-token"})
        self.assertEqual(result.returncode, 3, result.stdout + result.stderr)
        self.assertIn("SBOM quality: grade D", result.stdout)
        self.assertIn("cap C: no license", result.stderr)

    def test_sbom_gate_pass_does_not_fail_the_run(self) -> None:
        body = '{"gate":"pass","grade":"A","score":0.95,"categories":[],"caps":[]}'
        result = self.run_ps1(*self.scan_args("--sbom-min-grade", "A", "--client", "acme", "--env", "dev"),
                              env={"STUB_CURL_BODY": body, "STUB_CURL_CODE": "200", "GLOG_TOKEN": "stub-token"})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_sbom_gate_that_cannot_run_only_warns(self) -> None:
        result = self.run_ps1(*self.scan_args("--sbom-min-grade", "A", "--client", "acme", "--env", "dev"),
                              env={"STUB_CURL_CODE": "503", "STUB_CURL_BODY": "nope", "GLOG_TOKEN": "stub-token"})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("SBOM quality gate could not run (HTTP 503)", result.stdout)

    def test_upload_failure_is_reported_and_exits_two_only_when_asked(self) -> None:
        warned = self.run_ps1(*self.scan_args("--upload", "--client", "acme", "--env", "dev"),
                              env={"STUB_UPLOAD_FAILED": "1"})
        self.assertEqual(warned.returncode, 0, warned.stdout + warned.stderr)
        self.assertIn("ERROR: resolver upload failed", warned.stderr)

        strict = self.run_ps1(*self.scan_args("--upload", "--client", "acme", "--env", "dev",
                                              "--fail-on-upload-error"),
                              env={"STUB_UPLOAD_FAILED": "1"})
        self.assertEqual(strict.returncode, 2, strict.stdout + strict.stderr)

    def test_a_stale_resolver_log_does_not_trip_the_upload_check(self) -> None:
        glog_dir = self.project / ".glog"
        glog_dir.mkdir()
        stale = glog_dir / "glog-scan.log"
        stale.write_text("UPLOAD_FAILED | details=[from a previous run]\n")
        os.utime(stale, (1_600_000_000, 1_600_000_000))
        result = self.run_ps1(*self.scan_args("--upload", "--client", "acme", "--env", "dev",
                                              "--fail-on-upload-error"))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("ERROR: resolver upload failed", result.stderr)

    # --- rebuild ----------------------------------------------------------

    def test_rebuild_runs_the_worker_in_all_dependency_mode(self) -> None:
        result = self.run_ps1(*self.scan_args("--rebuild", "--max-packages", "5", "--api-url", "",
                                              "--upload", "--client", "acme", "--env", "dev"),
                              env={"GLOG_TOKEN": "stub-token"})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        py = [line for line in self.log.read_text().splitlines()]
        self.assertIn("##PYCALL", py)
        argv = py[py.index("##PYCALL") + 1:]
        self.assertIn("rebuild_client.py", " ".join(argv))
        self.assertEqual(argv[argv.index("--max-packages") + 1], "5")
        self.assertIn("--auto", argv)
        self.assertIn("ghcr.io/glogai/glog-scan-rebuild-4673", argv)

    def test_rebuild_without_token_skips_the_worker(self) -> None:
        result = self.run_ps1(*self.scan_args("--rebuild", "--upload", "--client", "acme", "--env", "dev"))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("##PYCALL", self.log.read_text())
        self.assertIn("rebuild skipped", result.stderr)

    def test_single_artifact_rebuild_requires_its_companions(self) -> None:
        result = self.run_ps1(*self.scan_args("--rebuild", "--rebuild-artifact", "pkg.tgz",
                                              "--upload", "--client", "acme", "--env", "dev",
                                              "--fail-on-upload-error"),
                              env={"GLOG_TOKEN": "stub-token"})
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("Single-artifact mode requires", result.stderr)


if __name__ == "__main__":
    unittest.main()
