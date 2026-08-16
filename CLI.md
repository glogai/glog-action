# Command Line Interface

`glog-action` includes two local helper scripts:

- `glog.sh` — **Linux/macOS only** (Bash)
- `glog.ps1` — **Windows** (Bash, cmd, or PowerShell) and PowerShell Core on Linux/macOS
       
**Windows users: always use `glog.ps1`, even from Git Bash or WSL-adjacent shells.**
       
`glog.sh` uses a direct bind mount (`-v /host/path:/app`) which Docker Desktop on Windows cannot resolve from Git Bash paths (e.g. `/c/Projects/...`). 
The containers will run but see an empty `/app` and produce no output.

`glog.ps1` works around this by creating a named Docker volume, copying sources into it via an `alpine` container, running the scanner against the volume, and copying `.glog` results back out.

Both scripts run Glog.AI scanner Docker images against a project directory and support running multiple commands in order (for example: `clean scan`).

---

## Requirements

### Bash (`glog.sh`)

- Bash
- Docker
- Access to the configured image registry (for example `ghcr.io/glogai/`)
- A valid Glog token

### PowerShell (`glog.ps1`)

- PowerShell 5.1+ (`powershell`) or PowerShell 7+ (`pwsh`)
- Docker Desktop / Docker Engine
- Access to the configured image registry (for example `ghcr.io/glogai/`)
- A valid Glog token

---

## Usage

### Bash

```bash
./glog.sh [clean] [scan] [options]
```

### PowerShell

```powershell
./glog.ps1 [clean] [scan] [options]
```

You can also call the Windows wrapper from `cmd.exe`:

```bat
glog.cmd [clean] [scan] [options]
```

If script execution is blocked by Windows policy, run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\glog.ps1 [clean] [scan] [options]
```

You can provide `clean` and/or `scan` in the same command line. They execute in the order they appear.

Examples:

- Clean only (Bash):
  ```bash
  ./glog.sh clean --path /path/to/project
  ```

- Clean only (PowerShell):
  ```powershell
  ./glog.ps1 clean --path C:\path\to\project
  ```

- Scan only (Bash):
  ```bash
  ./glog.sh scan --path /path/to/project --glogtoken "$GLOG_TOKEN" --registry "ghcr.io/glogai/"
  ```

- Scan only (PowerShell):
  ```powershell
  ./glog.ps1 scan --path C:\path\to\project --glogtoken $env:GLOG_TOKEN --registry "ghcr.io/glogai/"
  ```

- Scan selected files (PowerShell):
  ```powershell
  ./glog.ps1 scan --path C:\repo --files "bad/db.py,api/routes.py" --glogtoken $env:GLOG_TOKEN --registry "ghcr.io/glogai/"
  ```

- Clean then scan (PowerShell):
  ```powershell
  ./glog.ps1 clean scan --path C:\repo --glogtoken $env:GLOG_TOKEN --registry "ghcr.io/glogai/"
  ```

---

## Commands

### `clean`

Cleans the `.glog` directory inside `--path` (removes all contents if the directory exists).

### `scan`

Runs language scanners via Docker images against the directory specified by `--path`.

- If `--lang` is not provided, the script auto-detects languages by file extensions.
- `resolver` is always appended to the language list and executed.

---

## Options

### `--path PATH`

Project/workspace directory to scan/clean.

- Default: current working directory

Example:

```bash
--path ~/Documents/Projects/my-repo
```

### `--lang l1,l2,l3`

Comma-separated list of languages to scan.

- If omitted, languages are auto-detected.

Example:

```bash
--lang java,python,terraform
```

### `--client CLIENT`

Client identifier passed to containers as `CLIENT`.

Example:

```bash
--client test
```

### `--env ENV`

Environment identifier passed to containers as `ENV`.

Example:

```bash
--env dev
```

### `--glogtoken TOKEN`

Glog service token passed to containers as `GLOGSERVICE`.

Examples:

```bash
--glogtoken "$GLOG_TOKEN"
```

```powershell
--glogtoken $env:GLOG_TOKEN
```

### `--registry REGISTRY_PREFIX`

Docker registry prefix used to build full image names.

Example:

```bash
--registry "ghcr.io/glogai/"
```

### `--ignore VALUE`

Ignore rule(s) passed to containers as `IGNORE`.

Example:

```bash
--ignore "vendor/**,node_modules/**"
```

### `--files FILE1,FILE2`

Comma-separated list of file paths to scan, relative to `--path`.

Example:

```bash
--files "bad/db.py,api/routes.py"
```

### `--sarif-format-type TYPE`

Sets `SARIF_FORMAT_TYPE` passed to containers.

Allowed values:

- `GITHUB` (default)
- `GITLAB`
- `STANDARD`

Examples:

```bash
--sarif-format-type GITHUB
--sarif-format-type GITLAB
--sarif-format-type STANDARD
```

### `-u`, `--upload`

Upload scan results to the **Glog on-prem dashboard**. Sets `RESOLVER_UPLOAD=true` for the scanner containers. When combined with `--sbom`, the generated SBOM is also persisted on the server (`SBOM_MODE=persist`); otherwise the SBOM stays local (`SBOM_MODE=stateless`).

This is independent from the GitHub code-scanning SARIF upload exposed by the GitHub Action (`upload` input).

### `--inventory`

Forces the `inventory` scanner to run in addition to the auto-detected languages. Use when you want components/dependencies inventoried even though no language triggers it.

Example:

```bash
--inventory
```

### `--sbom`

Generates a CycloneDX SBOM via the resolver scanner (passes `WITH_SBOM=true`, which the resolver image consumes as `--with-sbom`). The SBOM is written under `<path>/.glog/` as `*.cdx.json`.

Combine with `--upload` to also persist the SBOM on the Glog server alongside the SARIF.

Example:

```bash
--sbom
--sbom --upload
```

### `--sbom-only`

Skip SARIF and only produce the SBOM (sets `SBOM_ONLY=true`, consumed by the resolver image as `--sbom-only`). Implies `--sbom`.

Example:

```bash
--sbom-only
```

### `--scl-uuid UUID`

Source Code Location UUID to bind SARIF/SBOM uploads to on the Glog server. If omitted, the server tries to match an existing SCL from the scan metadata and creates a new one automatically if no match is found.

Example:

```bash
--scl-uuid 92c3d09d-bfad-4ca7-a4a7-d22e8b4462f7
```

---

## Bulk remediation env vars

These are read from the environment (no CLI flags) and forwarded into the scanner
containers by both `glog.sh` and `glog.ps1`. The GitHub Action forwards them too,
so setting them at workflow/job level is enough.

| Env | Default | Purpose |
|---|---|---|
| `GLOG_REMEDIATION_BULK` | `1` | Set `0` to disable batching (one POST per finding) |
| `GLOG_REMEDIATION_BATCH` | `20` | Findings per remediation POST |
| `GLOG_REMEDIATION_BATCH_LINGER_MS` | `250` | Max wait before flushing a partial batch |
| `GLOG_REMEDIATION_INFLIGHT_BATCHES` | `8` | Max concurrent batches |
| `GLOG_PROFILE` | unset | `1` enables resolver timing profiling |

If a batch fails or the server answers with an unexpected item count, the resolver
falls back to single-item calls automatically.

---




## Full examples

### Bash

```bash
./glog.sh clean scan \
  --path ~/Documents/Projects/javaspringvulny-glog-fork \
  --glogtoken "*************" \
  --registry "ghcr.io/glogai/" \
  --client test \
  --env dev \
  --sarif-format-type STANDARD
```

### PowerShell

```powershell
./glog.ps1 clean scan `
  --path C:\Projects\javaspringvulny-glog-fork `
  --glogtoken $env:GLOG_TOKEN `
  --registry "ghcr.io/glogai/" `
  --client test `
  --env dev `
  --sarif-format-type STANDARD
```
