#!/usr/bin/env python3
"""The --remediate step of glog.sh and glog.ps1, against a stub docker.

Remediation is the one stage that may write to the scanned tree, so what is
checked here is what decides that: it runs only when asked, only after the
resolver has produced .glog/glog-scan.sarif, on the project path, with the mode
and the transport the caller chose, and a failed run never fails the scan.

Run: python3 -m unittest discover -s tests -v
The glog.ps1 half needs pwsh on PATH and skips without it.
"""
from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

from test_scan_flow import DOCKER_STUB

ACTION_DIR = Path(__file__).resolve().parent.parent
REMEDIATION_IMAGE = "glog-scan-remediation-b101"

LEAKED = ("GLOG_TOKEN", "GLOGSERVICE", "GLOG_API_URL", "GLOG_LLM_TRANSPORT", "GLOG_LLM_API_KEY",
          "GLOG_LLM_BASE_URL", "GLOG_LLM_MODEL", "GLOG_LLM_SERVER_URL", "GLOG_IMAGE_REMEDIATION",
          "GLOG_REMEDIATION_MODE", "GLOG_REMEDIATION_APPLY", "GLOG_REMEDIATION_MIN_SEVERITY",
          "GLOG_REMEDIATION_MAX_FINDINGS", "GLOG_REMEDIATION_REQUIRE_VERIFIED",
          "GLOG_REMEDIATION_ALLOW_DIRTY", "REMEDIATE")


class _RemediationFlow:
    """Shared cases; a subclass names the driver."""

    script: str

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory(prefix="glog-remediation-flow-")
        self.root = Path(self.tmp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.log = self.root / "calls.log"
        self.log.write_text("")
        docker = self.bin / "docker"
        docker.write_text(DOCKER_STUB)
        docker.chmod(0o755)
        self.project = self.root / "project"
        self.project.mkdir()
        (self.project / "app.kt").write_text("fun main() {}\n")

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def command(self, *args: str) -> list[str]:
        raise NotImplementedError

    def run_driver(self, *args: str, env: dict[str, str] | None = None) -> subprocess.CompletedProcess:
        return self.run_command("scan", "--path", str(self.project), "--lang", "kotlin", *args, env=env)

    def run_command(self, *args: str, env: dict[str, str] | None = None) -> subprocess.CompletedProcess:
        full_env = dict(os.environ)
        for name in LEAKED:
            full_env.pop(name, None)
        full_env["PATH"] = f"{self.bin}{os.pathsep}{full_env['PATH']}"
        full_env["STUB_LOG"] = str(self.log)
        full_env["GLOG_SKIP_IMAGE_VERIFY"] = "true"
        if env:
            full_env.update(env)
        return subprocess.run(self.command(*args),
                              cwd=str(self.root), env=full_env, capture_output=True, text=True, timeout=300)

    def calls(self) -> list[dict]:
        out: list[dict] = []
        for line in self.log.read_text().splitlines():
            if line == "##CALL":
                out.append({"args": []})
            elif out:
                out[-1]["args"].append(line)
        for call in out:
            args = call["args"]
            call["image"] = (args[-1] if args else "").removeprefix("ghcr.io/glogai/")
            call["env"] = {}
            for i, arg in enumerate(args[:-1]):
                if arg == "-e" and i + 1 < len(args):
                    name, sep, value = args[i + 1].partition("=")
                    call["env"][name] = value if sep else None
        return out

    def remediation_calls(self) -> list[dict]:
        return [c for c in self.calls() if c["image"] == REMEDIATION_IMAGE]

    def test_no_remediation_unless_asked(self) -> None:
        result = self.run_driver(env={"GLOG_TOKEN": "stub-token"})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.remediation_calls(), [])

    def test_remediation_runs_last_on_the_server_relay_in_patch_mode(self) -> None:
        result = self.run_driver("--remediate", "--client", "acme", "--env", "dev",
                                 env={"GLOG_TOKEN": "stub-token"})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        images = [c["image"] for c in self.calls()]
        self.assertEqual(images[-1], REMEDIATION_IMAGE)
        self.assertIn("resolver", images[-2])
        env = self.remediation_calls()[0]["env"]
        self.assertEqual(env["GLOG_LLM_TRANSPORT"], "server")
        self.assertEqual(env["GLOG_API_URL"], "https://acme.dev.glog.ai/api")
        self.assertEqual(env["GLOG_REMEDIATION_MODE"], "patch")
        self.assertEqual(env["GLOG_IMAGE"], REMEDIATION_IMAGE)
        self.assertNotIn("GLOG_LLM_API_KEY", env)
        args = self.remediation_calls()[0]["args"]
        self.assertIn(f"{self.project}:/app", args)

    def test_local_server_relay_joins_the_host_network(self) -> None:
        result = self.run_driver("--remediate", "--client", "test", "--env", "localhost",
                                 env={"GLOG_TOKEN": "stub-token"})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        call = self.remediation_calls()[0]
        self.assertEqual(call["env"]["GLOG_API_URL"], "http://test.localhost:8000/api")
        self.assertEqual(call["env"]["GLOG_REMEDIATION_HOST_NETWORK"], "true")
        self.assertIn("test.localhost:127.0.0.1", call["args"])

    def test_options_reach_the_container(self) -> None:
        result = self.run_driver("--remediate-branch", "--remediate-dry-run", "--remediate-min-severity", "HIGH",
                                 "--remediate-max-findings", "3", "--require-verified", "--allow-dirty",
                                 "--client", "acme", env={"GLOG_TOKEN": "stub-token"})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        env = self.remediation_calls()[0]["env"]
        self.assertEqual((env["GLOG_REMEDIATION_MODE"], env["GLOG_REMEDIATION_APPLY"],
                          env["GLOG_REMEDIATION_MIN_SEVERITY"], env["GLOG_REMEDIATION_MAX_FINDINGS"],
                          env["GLOG_REMEDIATION_REQUIRE_VERIFIED"], env["GLOG_REMEDIATION_ALLOW_DIRTY"]),
                         ("branch", "false", "HIGH", "3", "true", "true"))

    def test_direct_transport_keeps_the_key_out_of_the_argv(self) -> None:
        result = self.run_driver("--remediate", env={"GLOG_LLM_API_KEY": "sk-secret",
                                                     "GLOG_LLM_BASE_URL": "https://llm.example/v1"})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        call = self.remediation_calls()[0]
        self.assertEqual(call["env"]["GLOG_LLM_TRANSPORT"], "direct")
        self.assertIsNone(call["env"]["GLOG_LLM_API_KEY"])
        self.assertNotIn("sk-secret", "\n".join(call["args"]))

    def test_without_token_or_key_remediation_is_skipped_not_failed(self) -> None:
        result = self.run_driver("--remediate")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.remediation_calls(), [])
        self.assertIn("remediation skipped", result.stderr)

    def test_a_failed_remediation_does_not_fail_the_scan(self) -> None:
        result = self.run_driver("--remediate", "--client", "acme",
                                 env={"GLOG_TOKEN": "stub-token", "STUB_DOCKER_FAIL": REMEDIATION_IMAGE})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("AI remediation failed", result.stderr)

    def test_invalid_mode_is_refused_before_any_container(self) -> None:
        result = self.run_driver("--remediation-mode", "push", env={"GLOG_TOKEN": "stub-token"})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Invalid --remediation-mode", result.stdout + result.stderr)
        self.assertEqual(self.calls(), [])

    def test_remediate_command_runs_only_the_remediation_image(self) -> None:
        (self.project / ".glog").mkdir()
        (self.project / ".glog" / "glog-scan.sarif").write_text('{"runs":[]}')
        result = self.run_command("remediate", "--path", str(self.project), "--client", "acme",
                                  "--remediate-max-findings", "5", env={"GLOG_TOKEN": "stub-token"})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual([c["image"] for c in self.calls()], [REMEDIATION_IMAGE])
        self.assertEqual(self.remediation_calls()[0]["env"]["GLOG_REMEDIATION_MAX_FINDINGS"], "5")

    def test_remediate_command_without_a_scan_result_is_skipped(self) -> None:
        result = self.run_command("remediate", "--path", str(self.project), "--client", "acme",
                                  env={"GLOG_TOKEN": "stub-token"})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.calls(), [])
        self.assertIn("remediation skipped", result.stderr)

    def test_scan_remediate_with_the_flag_runs_remediation_once(self) -> None:
        result = self.run_command("scan", "remediate", "--path", str(self.project), "--lang", "kotlin",
                                  "--remediate", "--client", "acme", env={"GLOG_TOKEN": "stub-token"})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(len(self.remediation_calls()), 1)


class GlogShRemediationTests(_RemediationFlow, unittest.TestCase):
    def command(self, *args: str) -> list[str]:
        return ["bash", str(ACTION_DIR / "glog.sh"), *args]


@unittest.skipIf(shutil.which("pwsh") is None, "pwsh is not installed")
class GlogPs1RemediationTests(_RemediationFlow, unittest.TestCase):
    def command(self, *args: str) -> list[str]:
        return ["pwsh", "-NoProfile", "-File", str(ACTION_DIR / "glog.ps1"), *args]


if __name__ == "__main__":
    unittest.main()
