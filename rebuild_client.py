"""Run the client-side rebuild worker and submit only its manifest."""
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import tempfile
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

MAX_MANIFEST_FILES = 100_000


def _load_manifest(path: Path) -> dict[str, str]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict) or not value:
        raise ValueError("manifest must be a non-empty JSON object")
    if len(value) > MAX_MANIFEST_FILES:
        raise ValueError(f"manifest exceeds {MAX_MANIFEST_FILES} files")
    return {str(key): str(digest) for key, digest in value.items()}


def _run_worker(*, image: str, artifact: Path, ecosystem: str) -> dict[str, Any]:
    if shutil.which("docker") is None:
        raise RuntimeError("Docker is required for a client-side reproducible build")
    if not artifact.is_file():
        raise ValueError(f"artifact does not exist: {artifact}")

    with tempfile.TemporaryDirectory(prefix="glog-rebuild-action-") as temp_dir:
        temp = Path(temp_dir)
        request = temp / "request.json"
        output = temp / "output"
        output.mkdir()
        request.write_text(json.dumps({"ecosystem": ecosystem}), encoding="utf-8")
        command = [
            "docker", "run", "--pull", "always", "--rm",
            "--network=none", "--read-only", "--cap-drop=ALL",
            "--security-opt=no-new-privileges", "--pids-limit=256",
            "--memory=1g", "--cpus=2", "--user=65532:65532",
            "--tmpfs", "/tmp:rw,noexec,nosuid,size=512m",
            "-v", f"{artifact.resolve()}:/input/artifact:ro",
            "-v", f"{request}:/input/request.json:ro",
            "-v", f"{output}:/output:rw",
            image, "--input", "/input/request.json", "--output", "/output",
        ]
        completed = subprocess.run(command, capture_output=True, text=True, timeout=1800, check=False)
        if completed.returncode != 0:
            detail = (completed.stderr or completed.stdout or "worker failed").strip()
            raise RuntimeError(f"rebuild worker exited with code {completed.returncode}: {detail[:500]}")
        payload = json.loads((output / "manifest.json").read_text(encoding="utf-8"))
        if not isinstance(payload, dict) or not isinstance(payload.get("manifest"), dict):
            raise ValueError("rebuild worker returned an invalid manifest")
        return payload


def submit_rebuild(*, api_url: str, token: str, package_name: str, package_version: str,
                   ecosystem: str, artifact: Path, published_manifest: Path | None, image: str,
                   source_code_location: str = "") -> dict[str, Any]:
    if not api_url or not token:
        raise ValueError("GLOG_API_URL and GLOG_TOKEN are required to submit a rebuild")
    payload = _run_worker(image=image, artifact=artifact, ecosystem=ecosystem)
    body: dict[str, Any] = {
        "package_name": package_name,
        "package_version": package_version,
        "ecosystem": ecosystem,
        "artifact_path": str(artifact),
        "rebuilt_manifest": payload["manifest"],
        "network_events": payload.get("network_events", []),
    }
    if published_manifest:
        body["published_manifest"] = _load_manifest(published_manifest)
    if source_code_location:
        body["source_code_location"] = int(source_code_location)
    endpoint = api_url.rstrip("/") + "/api/supply-chain/rebuild-jobs/"
    request = urllib.request.Request(
        endpoint,
        data=json.dumps(body).encode("utf-8"),
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            result = json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")[:500]
        raise RuntimeError(f"server rejected rebuild manifest ({exc.code}): {detail}") from exc
    if not isinstance(result, dict):
        raise ValueError("server returned an invalid rebuild response")
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description="Run and submit a client-side reproducible build")
    parser.add_argument("--api-url", default=os.getenv("GLOG_API_URL", ""))
    parser.add_argument("--token", default=os.getenv("GLOG_TOKEN", ""))
    parser.add_argument("--image", default=os.getenv("GLOG_REBUILD_IMAGE", "ghcr.io/glogai/glog-scan-rebuild-4673"))
    parser.add_argument("--artifact", required=True)
    parser.add_argument("--published-manifest", default="")
    parser.add_argument("--package-name", required=True)
    parser.add_argument("--package-version", default="")
    parser.add_argument("--ecosystem", required=True, choices=("npm", "pypi", "go", "cargo", "maven", "rubygems"))
    parser.add_argument("--source-code-location", default="")
    args = parser.parse_args()
    result = submit_rebuild(
        api_url=args.api_url, token=args.token, package_name=args.package_name,
        package_version=args.package_version, ecosystem=args.ecosystem,
        artifact=Path(args.artifact),
        published_manifest=Path(args.published_manifest) if args.published_manifest else None,
        image=args.image, source_code_location=args.source_code_location,
    )
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
