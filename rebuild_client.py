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


def _import_discovery():
    try:
        from supply_chain import dependency_discovery as module  # type: ignore
    except ImportError:
        import dependency_discovery as module  # type: ignore
    return module


def run_auto(*, api_url: str, token: str, project_path: str, image: str,
             ecosystems: tuple[str, ...] = (), max_packages: int = 25,
             source_code_location: str = "") -> dict[str, Any]:
    """Rebuild every dependency discovered in the project, with no manual input.

    Artifacts are downloaded from the public registry, hashed locally inside the
    sandboxed worker, and only the resulting manifest is submitted.
    """
    discovery = _import_discovery()
    selected = tuple(ecosystems) or discovery.ECOSYSTEMS
    dependencies = discovery.discover_dependencies(
        project_path, ecosystems=selected, max_packages=max_packages
    )
    summary: dict[str, Any] = {
        "mode": "auto",
        "project_path": str(project_path),
        "discovered": len(dependencies),
        "submitted": 0,
        "failed": 0,
        "jobs": [],
        "errors": [],
    }
    if not dependencies:
        return summary
    with tempfile.TemporaryDirectory(prefix="glog-rebuild-auto-") as temp_dir:
        for dep in dependencies:
            label = f"{dep.ecosystem}:{dep.name}@{dep.version}"
            try:
                artifact = discovery.download_artifact(dep, temp_dir)
                result = submit_rebuild(
                    api_url=api_url, token=token, package_name=dep.name,
                    package_version=dep.version, ecosystem=dep.ecosystem,
                    artifact=artifact, published_manifest=None, image=image,
                    source_code_location=source_code_location,
                )
                summary["submitted"] += 1
                summary["jobs"].append({"package": label, "result": result})
                print(f"[rebuild] {label}: submitted")
            except Exception as exc:  # noqa: BLE001 - one bad package must not stop the scan
                summary["failed"] += 1
                summary["errors"].append({"package": label, "error": str(exc)[:300]})
                print(f"[rebuild] {label}: skipped ({str(exc)[:200]})")
    return summary


def main() -> int:
    parser = argparse.ArgumentParser(description="Run and submit client-side reproducible builds")
    parser.add_argument("--api-url", default=os.getenv("GLOG_API_URL", ""))
    parser.add_argument("--token", default=os.getenv("GLOG_TOKEN", ""))
    parser.add_argument("--image", default=os.getenv("GLOG_REBUILD_IMAGE", "ghcr.io/glogai/glog-scan-rebuild-4673"))
    parser.add_argument("--auto", action="store_true",
                        help="Discover and rebuild every dependency of --project-path")
    parser.add_argument("--project-path", default=".")
    parser.add_argument("--ecosystems", default="",
                        help="Comma separated subset (npm,pypi,go,cargo,maven,rubygems)")
    parser.add_argument("--max-packages", type=int, default=int(os.getenv("REBUILD_MAX_PACKAGES", "10000")))
    parser.add_argument("--artifact", default="")
    parser.add_argument("--published-manifest", default="")
    parser.add_argument("--package-name", default="")
    parser.add_argument("--package-version", default="")
    parser.add_argument("--ecosystem", default="",
                        choices=("", "npm", "pypi", "go", "cargo", "maven", "rubygems"))
    parser.add_argument("--source-code-location", default="")
    args = parser.parse_args()

    auto = args.auto or not args.artifact
    if auto:
        ecosystems = tuple(part.strip() for part in args.ecosystems.split(",") if part.strip())
        summary = run_auto(
            api_url=args.api_url, token=args.token, project_path=args.project_path,
            image=args.image, ecosystems=ecosystems, max_packages=args.max_packages,
            source_code_location=args.source_code_location,
        )
        print(json.dumps(summary, sort_keys=True))
        return 0

    if not args.package_name or not args.ecosystem:
        parser.error("--package-name and --ecosystem are required with --artifact")
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
