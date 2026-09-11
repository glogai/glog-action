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
# Ecosystems the inventory scanner reports but the rebuild worker cannot fetch.
SCAN_ECOSYSTEMS = ECOSYSTEMS + ("composer",)
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


_PY_KEYWORDS = {
    "and", "as", "assert", "async", "await", "break", "class", "continue", "def",
    "del", "elif", "else", "except", "finally", "for", "from", "global", "if",
    "import", "in", "is", "lambda", "nonlocal", "not", "or", "pass", "raise",
    "return", "try", "while", "with", "yield", "print", "setup", "true", "false",
    "none", "self",
}
# setup() keyword arguments and common setup.py locals that must never be
# mistaken for requirement lines.
_SETUP_KWARGS = {
    "name", "version", "description", "long_description", "long_description_content_type",
    "author", "author_email", "maintainer", "maintainer_email", "url", "download_url",
    "license", "license_files", "classifiers", "keywords", "packages", "package_dir",
    "package_data", "include_package_data", "py_modules", "entry_points", "scripts",
    "install_requires", "extras_require", "setup_requires", "tests_require",
    "python_requires", "zip_safe", "platforms", "project_urls", "cmdclass",
    "ext_modules", "data_files", "namespace_packages", "test_suite", "options",
    "here", "readme", "root", "path", "requirements", "extras", "about",
}


def _looks_like_requirement(line: str) -> bool:
    """Reject source-code lines that a naive line parser would accept."""
    if any(ch in line for ch in "()[]{}\"'`:,\\"):
        # Extras (`pkg[extra]==1.0`) are the only bracket form we allow.
        if not re.fullmatch(r"[A-Za-z0-9._-]+\[[A-Za-z0-9._,\s-]+\]\s*[<>=!~]*[^()\"']*", line):
            return False
    if re.match(r"^[A-Za-z0-9._-]+\s*=\s*[^=]", line):  # assignment, not a pin
        return False
    return True


def _parse_requirements(text: str) -> list[Dependency]:
    found: list[Dependency] = []
    for raw in text.splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line or line.startswith("-"):
            continue
        line = line.split(";", 1)[0].strip()
        if not _looks_like_requirement(line):
            continue
        match = re.match(r"^([A-Za-z0-9._-]+)\s*(?:\[[^\]]*\])?\s*(.*)$", line)
        if not match:
            continue
        name, spec = match.group(1).lower(), match.group(2).strip()
        if name in _PY_KEYWORDS or name in _SETUP_KWARGS:
            continue
        if spec and not re.match(r"^[<>=!~]", spec):
            # `import foo`, `here os.path` and similar noise.
            continue
        pin = re.match(r"^==\s*([A-Za-z0-9._!+-]+)$", spec)
        if pin:
            version = pin.group(1).rstrip(".-+!")
            if version and "*" not in version:
                found.append(Dependency("pypi", name, version))
                continue
        # Unpinned / range requirement: resolved to the latest release later.
        found.append(Dependency("pypi", name, ""))
    return found


def _parse_setup_py(text: str) -> list[Dependency]:
    """Extract only real requirement literals from a setup.py.

    setup.py is Python source, not a requirements file: parse the setup() call
    and read install_requires / extras_require / *_requires string literals.
    """
    requirement_keys = ("install_requires", "extras_require", "setup_requires",
                        "tests_require")
    literals: list[str] = []
    try:
        import ast

        tree = ast.parse(text)
    except (SyntaxError, ValueError):
        tree = None

    if tree is not None:
        def collect(node) -> None:
            # extras_require is a mapping: its keys are extra names, not
            # requirements, so only descend into the values.
            if isinstance(node, ast.Dict):
                for value in node.values:
                    collect(value)
                return
            if isinstance(node, (ast.List, ast.Tuple, ast.Set)):
                for element in node.elts:
                    collect(element)
                return
            if isinstance(node, ast.Constant) and isinstance(node.value, str):
                literals.append(node.value)

        for node in ast.walk(tree):
            if isinstance(node, ast.Call):
                for keyword in node.keywords:
                    if keyword.arg in requirement_keys:
                        collect(keyword.value)
            elif isinstance(node, ast.Assign):
                for target in node.targets:
                    if isinstance(target, ast.Name) and target.id in requirement_keys:
                        collect(node.value)
    else:
        for key in requirement_keys:
            for block in re.findall(rf"{key}\s*=\s*(\[.*?\]|\{{.*?\}})", text, re.S):
                literals.extend(re.findall(r"['\"]([^'\"]+)['\"]", block))

    found: list[Dependency] = []
    for literal in literals:
        for entry in literal.split(","):
            found.extend(_parse_requirements(entry.strip()))
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


def _parse_pyproject(text: str) -> list[Dependency]:
    """Read poetry and PEP 621 dependency tables without a TOML dependency."""
    found: list[Dependency] = []
    section = ""
    for raw in text.splitlines():
        line = raw.split("#", 1)[0].strip()
        if line.startswith("[") and line.endswith("]"):
            section = line.strip("[]").strip()
            continue
        if not line:
            continue
        if section in ("tool.poetry.dependencies", "tool.poetry.group.dev.dependencies",
                       "tool.poetry.dev-dependencies", "project.optional-dependencies"):
            match = re.match(r'^([A-Za-z0-9._-]+)\s*=\s*(.*)$', line)
            if not match:
                continue
            name = match.group(1).lower()
            if name == "python":
                continue
            pin = re.search(r'"[=^~><]*\s*([0-9][A-Za-z0-9._]*)"', match.group(2))
            found.append(Dependency("pypi", name, pin.group(1) if pin and match.group(2).strip().startswith('"=') else ""))
            continue
        if section == "project":
            # dependencies = ["requests>=2", "werkzeug==2.2.2"]
            for entry in re.findall(r'"([^"]+)"', line):
                found.extend(_parse_requirements(entry))
    return found


def _parse_go_mod(text: str) -> list[Dependency]:
    found: list[Dependency] = []
    for raw in text.splitlines():
        line = raw.split("//", 1)[0].strip()
        match = re.match(r"^(?:require\s+)?([A-Za-z0-9._~/-]+\.[A-Za-z0-9._~/-]+)\s+v([0-9][^\s]*)$", line)
        if match:
            found.append(Dependency("go", match.group(1), "v" + match.group(2)))
    return found


def _parse_pnpm_lock(text: str) -> list[Dependency]:
    found: list[Dependency] = []
    for raw in text.splitlines():
        match = re.match(r"^\s{2,}(/?@?[A-Za-z0-9._/-]+)@([0-9][A-Za-z0-9._+-]*)\s*:?\s*$", raw)
        if match:
            name = match.group(1).lstrip("/")
            found.append(Dependency("npm", name, match.group(2)))
    return found


def _parse_composer_lock(text: str) -> list[Dependency]:
    # Recorded under the npm-style ecosystem is wrong; composer packages are
    # reported as generic entries so they still show up in the inventory.
    found: list[Dependency] = []
    try:
        data = json.loads(text)
    except ValueError:
        return found
    for section in ("packages", "packages-dev"):
        for item in (data.get(section) or []):
            if isinstance(item, dict) and item.get("name") and item.get("version"):
                found.append(Dependency("composer", str(item["name"]), str(item["version"]).lstrip("v")))
    return found


def _parse_cargo_toml(text: str) -> list[Dependency]:
    found: list[Dependency] = []
    section = ""
    for raw in text.splitlines():
        line = raw.split("#", 1)[0].strip()
        if line.startswith("[") and line.endswith("]"):
            section = line.strip("[]").strip()
            continue
        if section not in ("dependencies", "dev-dependencies", "build-dependencies") or not line:
            continue
        match = re.match(r'^([A-Za-z0-9._-]+)\s*=\s*(.*)$', line)
        if match:
            pin = re.search(r'"[=^~]?\s*([0-9][A-Za-z0-9._]*)"', match.group(2))
            found.append(Dependency("cargo", match.group(1), pin.group(1) if pin else ""))
    return found


def _parse_gemfile(text: str) -> list[Dependency]:
    found: list[Dependency] = []
    for raw in text.splitlines():
        line = raw.split("#", 1)[0].strip()
        match = re.match(r"^gem\s+['\"]([A-Za-z0-9._-]+)['\"](.*)$", line)
        if match:
            pin = re.search(r"['\"][=~><\s]*([0-9][A-Za-z0-9._]*)['\"]", match.group(2))
            found.append(Dependency("rubygems", match.group(1), pin.group(1) if pin else ""))
    return found


_PARSERS: dict[str, tuple[str, object]] = {
    "requirements.txt": ("pypi", _parse_requirements),
    "requirements-dev.txt": ("pypi", _parse_requirements),
    "poetry.lock": ("pypi", _parse_poetry_lock),
    "uv.lock": ("pypi", _parse_poetry_lock),
    "Pipfile.lock": ("pypi", _parse_pipfile_lock),
    "pyproject.toml": ("pypi", _parse_pyproject),
    "setup.py": ("pypi", _parse_setup_py),
    "package.json": ("npm", _parse_package_json),
    "package-lock.json": ("npm", _parse_package_lock),
    "npm-shrinkwrap.json": ("npm", _parse_package_lock),
    "yarn.lock": ("npm", _parse_yarn_lock),
    "pnpm-lock.yaml": ("npm", _parse_pnpm_lock),
    "Cargo.lock": ("cargo", _parse_cargo_lock),
    "Cargo.toml": ("cargo", _parse_cargo_toml),
    "Gemfile.lock": ("rubygems", _parse_gemfile_lock),
    "Gemfile": ("rubygems", _parse_gemfile),
    "go.sum": ("go", _parse_go_sum),
    "go.mod": ("go", _parse_go_mod),
    "pom.xml": ("maven", _parse_pom),
    "composer.lock": ("composer", _parse_composer_lock),
}

# Manifest names that only differ by suffix (requirements-test.txt,
# requirements/base.txt, constraints.txt) must be discovered as well.
_PARSER_PATTERNS: tuple[tuple[str, str, object], ...] = (
    (r"^requirements.*\.txt$", "pypi", _parse_requirements),
    (r"^constraints.*\.txt$", "pypi", _parse_requirements),
)


def parser_for(filename: str, parent: str = "") -> tuple[str, object] | None:
    """Return the (ecosystem, parser) pair handling this manifest file name."""
    entry = _PARSERS.get(filename)
    if entry:
        return entry
    for pattern, ecosystem, parser in _PARSER_PATTERNS:
        if re.match(pattern, filename):
            return (ecosystem, parser)
    # Split requirement sets live in a requirements/ directory (base.txt,
    # dev.txt, prod.txt) and carry no recognisable file name of their own.
    if parent in ("requirements", "requires") and filename.endswith((".txt", ".in")):
        return ("pypi", _parse_requirements)
    return None



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


def discovered_manifests(project_path: str | Path) -> list[str]:
    """Return the manifest files the discovery walk recognises, for diagnostics."""
    root = Path(project_path)
    if not root.is_dir():
        return []
    names: list[str] = []
    for path in sorted(root.rglob("*")):
        if not path.is_file() or parser_for(path.name, path.parent.name) is None:
            continue
        if any(part in SKIP_DIRS for part in path.relative_to(root).parts[:-1]):
            continue
        names.append(path.relative_to(root).as_posix())
    return names


def discover_dependencies(project_path: str | Path, *, ecosystems: tuple[str, ...] = ECOSYSTEMS,
                          max_packages: int = DEFAULT_MAX_PACKAGES,
                          resolve_unpinned: bool = True,
                          include_unpinned: bool = False) -> list[Dependency]:
    """Return de-duplicated dependencies found in the project's manifests.

    Requirements without an exact pin are resolved to the registry's latest
    release so a project with only loose manifests is still fully covered.
    With ``include_unpinned`` the dependencies that stay unresolved (offline
    run, registry miss) are still returned with an empty version so the
    inventory reports the real package count instead of zero.
    """
    root = Path(project_path)
    if not root.is_dir():
        return []
    wanted = {eco for eco in ecosystems}
    seen: set[tuple[str, str, str]] = set()
    unpinned: list[Dependency] = []
    result: list[Dependency] = []
    for path in sorted(root.rglob("*")):
        if not path.is_file():
            continue
        entry = parser_for(path.name, path.parent.name)
        if entry is None:
            continue
        if any(part in SKIP_DIRS for part in path.relative_to(root).parts[:-1]):
            continue
        ecosystem, parser = entry
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
    handled_names: set[tuple[str, str]] = {(dep.ecosystem, dep.name) for dep in result}
    for dep in unpinned:
        if (dep.ecosystem, dep.name) in handled_names or len(result) >= max_packages:
            continue
        handled_names.add((dep.ecosystem, dep.name))
        version = latest_version(dep.ecosystem, dep.name) if resolve_unpinned else ""
        if not version:
            if include_unpinned:
                result.append(dep)
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
        urls = [entry for entry in (data.get("urls") or []) if isinstance(entry, dict)]
        source_distributions = sorted(
            (entry for entry in urls if entry.get("packagetype") == "sdist"),
            key=lambda entry: (str(entry.get("filename") or ""), str(entry.get("url") or "")),
        )
        fallback_files = sorted(
            urls,
            key=lambda entry: (str(entry.get("filename") or ""), str(entry.get("url") or "")),
        )
        candidates = source_distributions or fallback_files
        if candidates:
            return str(candidates[0]["url"])
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
