# Command Line Interface

`glog-action` includes two local helper scripts with equivalent behavior:

- `glog.sh` for Bash environments on Linux/macOS
- `glog.ps1` for Bash on Windows or for PowerShell environments (Windows, or PowerShell Core on Linux/macOS)

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
