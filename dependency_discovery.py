"""Discover project dependencies and fetch their published artifacts.

The client should not have to think about individual packages: point the scan
at a project and every dependency found in its lockfiles/manifests is rebuilt
and compared against the registry baseline.
"""
from __future__ import annotations

import json
import re
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path

ECOSYSTEMS = ("npm", "pypi", "go", "cargo", "maven", "rubygems")
DEFAULT_MAX_PACKAGES = 10_000
MAX_LOCKFILE_BYTES = 20_000_000
MAX_ARTIFACT_BYTES = 200_000_000
SKIP_DIRS = {
    ".git", "node_modules", "venv", ".venv", "dist", "build", "target",
    "__pycache__", ".tox", ".mypy_cache", ".gradle", ".idea",
}


@dataclass(frozen=True)
class Dependency:
    ecosystem: str
    name: str
    version: str

    def key(self) -> tuple[str, str, str]:
        return (self.ecosystem, self.name, self.version)


def _read(path: Path) -> str:
    if path.stat().st_size > MAX_LOCKFILE_BYTES:
        return ""
    return path.read_text(encoding="utf-8", errors="replace")


def _parse_requirements(text: str) -> list[Dependency]:
    found: list[Dependency] = []
    for raw in text.splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line or line.startswith("-"):
            continue
        line = line.split(";", 1)[0].strip()
        match = re.match(r"^([A-Za-z0-9._-]+)\s*(?:\[[^\]]*\])?\s*(.*)$", line)
        if not match:
            continue
        name, spec = match.group(1).lower(), match.group(2).strip()
        pin = re.match(r"^==\s*([A-Za-z0-9._!+-]+)$", spec)
        if pin:
            version = pin.group(1).rstrip(".-+!")
            if version and "*" not in version:
                found.append(Dependency("pypi", name, version))
                continue
        # Unpinned / range requirement: resolved to the latest release later.
        found.append(Dependency("pypi", name, ""))
    return found


def _parse_package_json(text: str) -> list[Dependency]:
    found: list[Dependency] = []
    try:
        data = json.loads(text)
    except ValueError:
        return found
    for section in ("dependencies", "devDependencies", "optionalDependencies"):
        for name, spec in (data.get(section) or {}).items():
            if not isinstance(spec, str) or spec.startswith(("file:", "link:", "workspace:", "git")):
                continue
            exact = re.match(r"^\d+\.\d+\.\d+[A-Za-z0-9.+-]*$", spec.strip())
            found.append(Dependency("npm", str(name), exact.group(0) if exact else ""))
    return found



def _parse_poetry_lock(text: str) -> list[Dependency]:
    found: list[Dependency] = []
    name = ""
    for raw in text.splitlines():
        line = raw.strip()
        if line == "[[package]]":
            name = ""
        elif line.startswith("name ="):
            name = line.split("=", 1)[1].strip().strip('"')
        elif line.startswith("version =") and name:
            version = line.split("=", 1)[1].strip().strip('"')
            found.append(Dependency("pypi", name.lower(), version))
            name = ""
    return found


def _parse_pipfile_lock(text: str) -> list[Dependency]:
    found: list[Dependency] = []
    try:
        data = json.loads(text)
    except ValueError:
        return found
    for section in ("default", "develop"):
        for name, meta in (data.get(section) or {}).items():
            version = str((meta or {}).get("version", "")).lstrip("=")
            if version:
                found.append(Dependency("pypi", str(name).lower(), version))
    return found


def _parse_package_lock(text: str) -> list[Dependency]:
    found: list[Dependency] = []
    try:
        data = json.loads(text)
    except ValueError:
        return found
    for path, meta in (data.get("packages") or {}).items():
        if not path or not isinstance(meta, dict) or meta.get("link"):
            continue
        name = meta.get("name") or path.split("node_modules/")[-1]
        version = meta.get("version")
        if name and version:
            found.append(Dependency("npm", str(name), str(version)))
    for name, meta in (data.get("dependencies") or {}).items():
        version = (meta or {}).get("version")
        if version and isinstance(version, str) and not version.startswith(("file:", "link:")):
            found.append(Dependency("npm", str(name), version))
    return found


def _parse_yarn_lock(text: str) -> list[Dependency]:
    found: list[Dependency] = []
    name = ""
    for raw in text.splitlines():
        if raw and not raw.startswith((" ", "\t", "#")):
            header = raw.strip().rstrip(":").split(",")[0].strip().strip('"')
            at = header.rfind("@")
            name = header[:at] if at > 0 else ""
        elif name:
            match = re.match(r'^\s+version[:=]?\s+"?([^"\s]+)"?', raw)
            if match:
                found.append(Dependency("npm", name, match.group(1)))
                name = ""
    return found


def _parse_cargo_lock(text: str) -> list[Dependency]:
    found: list[Dependency] = []
    name = ""
    for raw in text.splitlines():
        line = raw.strip()
        if line == "[[package]]":
            name = ""
        elif line.startswith("name ="):
            name = line.split("=", 1)[1].strip().strip('"')
        elif line.startswith("version =") and name:
            found.append(Dependency("cargo", name, line.split("=", 1)[1].strip().strip('"')))
            name = ""
    return found


def _parse_gemfile_lock(text: str) -> list[Dependency]:
    found: list[Dependency] = []
    for raw in text.splitlines():
        match = re.match(r"^\s{4}([A-Za-z0-9._-]+) \(([^)=<>~ ]+)\)\s*$", raw)
        if match:
            found.append(Dependency("rubygems", match.group(1), match.group(2)))
    return found


def _parse_go_sum(text: str) -> list[Dependency]:
    found: list[Dependency] = []
    for raw in text.splitlines():
        parts = raw.split()
        if len(parts) >= 2 and not parts[1].endswith("/go.mod"):
            found.append(Dependency("go", parts[0], parts[1]))
    return found


def _parse_pom(text: str) -> list[Dependency]:
    found: list[Dependency] = []
    for block in re.findall(r"<dependency>(.*?)</dependency>", text, re.DOTALL):
        group = re.search(r"<groupId>([^<]+)</groupId>", block)
        artifact = re.search(r"<artifactId>([^<]+)</artifactId>", block)
        version = re.search(r"<version>([^<]+)</version>", block)
        if group and artifact and version and "${" not in version.group(1):
            name = f"{group.group(1).strip()}:{artifact.group(1).strip()}"
            found.append(Dependency("maven", name, version.group(1).strip()))
    return found


_PARSERS: dict[str, tuple[str, object]] = {
    "requirements.txt": ("pypi", _parse_requirements),
    "requirements-dev.txt": ("pypi", _parse_requirements),
    "poetry.lock": ("pypi", _parse_poetry_lock),
    "Pipfile.lock": ("pypi", _parse_pipfile_lock),
    "package.json": ("npm", _parse_package_json),
    "package-lock.json": ("npm", _parse_package_lock),
    "npm-shrinkwrap.json": ("npm", _parse_package_lock),
    "yarn.lock": ("npm", _parse_yarn_lock),
    "Cargo.lock": ("cargo", _parse_cargo_lock),
    "Gemfile.lock": ("rubygems", _parse_gemfile_lock),
    "go.sum": ("go", _parse_go_sum),
    "pom.xml": ("maven", _parse_pom),
}


def latest_version(ecosystem: str, name: str) -> str:
    """Return the newest published version for an unpinned dependency."""
    try:
        if ecosystem == "pypi":
            data = _fetch_json(f"https://pypi.org/pypi/{urllib.parse.quote(name)}/json")
            return str((data.get("info") or {}).get("version") or "")
        if ecosystem == "npm":
            data = _fetch_json(f"https://registry.npmjs.org/{urllib.parse.quote(name, safe='@')}")
            return str((data.get("dist-tags") or {}).get("latest") or "")
        if ecosystem == "cargo":
            data = _fetch_json(f"https://crates.io/api/v1/crates/{urllib.parse.quote(name)}")
            return str((data.get("crate") or {}).get("max_stable_version") or "")
    except Exception:  # noqa: BLE001 - a registry miss must not stop discovery
        return ""
    return ""


def discover_dependencies(project_path: str | Path, *, ecosystems: tuple[str, ...] = ECOSYSTEMS,
                          max_packages: int = DEFAULT_MAX_PACKAGES,
                          resolve_unpinned: bool = True) -> list[Dependency]:
    """Return de-duplicated dependencies found in the project's manifests.

    Requirements without an exact pin are resolved to the registry's latest
    release so a project with only loose manifests is still fully covered.
    """
    root = Path(project_path)
    if not root.is_dir():
        return []
    wanted = {eco for eco in ecosystems if eco in ECOSYSTEMS}
    seen: set[tuple[str, str, str]] = set()
    unpinned: list[Dependency] = []
    result: list[Dependency] = []
    for path in sorted(root.rglob("*")):
        if not path.is_file() or path.name not in _PARSERS:
            continue
        if any(part in SKIP_DIRS for part in path.relative_to(root).parts[:-1]):
            continue
        ecosystem, parser = _PARSERS[path.name]
        if ecosystem not in wanted:
            continue
        try:
            text = _read(path)
        except OSError:
            continue
        for dep in parser(text):  # type: ignore[operator]
            if not dep.name:
                continue
            if not dep.version:
                unpinned.append(dep)
                continue
            if dep.key() in seen:
                continue
            seen.add(dep.key())
            result.append(dep)
            if len(result) >= max_packages:
                return result
    if resolve_unpinned:
        resolved_names: set[tuple[str, str]] = {(dep.ecosystem, dep.name) for dep in result}
        for dep in unpinned:
            if (dep.ecosystem, dep.name) in resolved_names or len(result) >= max_packages:
                continue
            resolved_names.add((dep.ecosystem, dep.name))
            version = latest_version(dep.ecosystem, dep.name)
            if not version:
                continue
            pinned = Dependency(dep.ecosystem, dep.name, version)
            if pinned.key() in seen:
                continue
            seen.add(pinned.key())
            result.append(pinned)
    return result



def _fetch_json(url: str) -> dict:
    request = urllib.request.Request(url, headers={"User-Agent": "glog-supply-chain"})
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.loads(response.read().decode("utf-8"))


def _go_escape(value: str) -> str:
    return re.sub(r"([A-Z])", lambda m: "!" + m.group(1).lower(), value)


def artifact_url(dep: Dependency) -> str:
    """Return the registry download URL for the published artifact."""
    if dep.ecosystem == "pypi":
        data = _fetch_json(f"https://pypi.org/pypi/{urllib.parse.quote(dep.name)}/{urllib.parse.quote(dep.version)}/json")
        urls = data.get("urls") or []
        for entry in urls:
            if entry.get("packagetype") == "sdist":
                return str(entry["url"])
        if urls:
            return str(urls[0]["url"])
        raise RuntimeError("no PyPI artifact for this version")
    if dep.ecosystem == "npm":
        data = _fetch_json(f"https://registry.npmjs.org/{urllib.parse.quote(dep.name, safe='@')}")
        dist = ((data.get("versions") or {}).get(dep.version) or {}).get("dist") or {}
        tarball = dist.get("tarball")
        if not tarball:
            raise RuntimeError("no npm tarball for this version")
        return str(tarball)
    if dep.ecosystem == "cargo":
        return f"https://crates.io/api/v1/crates/{urllib.parse.quote(dep.name)}/{urllib.parse.quote(dep.version)}/download"
    if dep.ecosystem == "rubygems":
        return f"https://rubygems.org/downloads/{urllib.parse.quote(dep.name)}-{urllib.parse.quote(dep.version)}.gem"
    if dep.ecosystem == "maven":
        group, _, artifact = dep.name.partition(":")
        if not artifact:
            raise RuntimeError("maven package must be groupId:artifactId")
        path = group.replace(".", "/")
        return f"https://repo1.maven.org/maven2/{path}/{artifact}/{dep.version}/{artifact}-{dep.version}.jar"
    if dep.ecosystem == "go":
        version = dep.version.split("/")[0]
        return f"https://proxy.golang.org/{_go_escape(dep.name)}/@v/{_go_escape(version)}.zip"
    raise RuntimeError(f"unsupported ecosystem: {dep.ecosystem}")


def _artifact_suffix(dep: Dependency, url: str) -> str:
    for suffix in (".tar.gz", ".tgz", ".whl", ".zip", ".jar", ".gem", ".crate"):
        if url.endswith(suffix):
            return suffix
    return {"npm": ".tgz", "pypi": ".tar.gz", "cargo": ".crate",
            "rubygems": ".gem", "maven": ".jar", "go": ".zip"}[dep.ecosystem]


def download_artifact(dep: Dependency, destination_dir: str | Path) -> Path:
    """Download the published artifact for ``dep`` and return its local path."""
    url = artifact_url(dep)
    safe_name = re.sub(r"[^A-Za-z0-9._-]", "_", f"{dep.name}-{dep.version}")
    target = Path(destination_dir) / f"{safe_name}{_artifact_suffix(dep, url)}"
    request = urllib.request.Request(url, headers={"User-Agent": "glog-supply-chain"})
    with urllib.request.urlopen(request, timeout=120) as response:
        written = 0
        with target.open("wb") as handle:
            while chunk := response.read(1 << 20):
                written += len(chunk)
                if written > MAX_ARTIFACT_BYTES:
                    raise RuntimeError(f"artifact exceeds {MAX_ARTIFACT_BYTES} bytes")
                handle.write(chunk)
    if target.stat().st_size == 0:
        raise RuntimeError("downloaded artifact is empty")
    return target
