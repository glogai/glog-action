# Command Line Interface

`glog.sh` is a Bash helper script to run Glog.AI scanning Docker images against a project directory.

It supports running multiple commands in a single invocation, in the order provided (e.g. `clean scan`).

---

## Requirements

- Bash
- Docker
- Access to the configured image registry (e.g. `ghcr.io/glogai/`)
- A valid Glog token

---

## Usage

```bash
./glog.sh [clean] [scan] [options]
```

You can provide `clean` and/or `scan` in the same command line. They will execute in the order they appear.

Examples:

- Clean only:
  ```bash
  ./glog.sh clean --path /path/to/project
  ```

- Scan only:
  ```bash
  ./glog.sh scan --path /path/to/project --glogtoken "$GLOG_TOKEN" --registry "ghcr.io/glogai/"
  ```

- Clean then scan:
  ```bash
  ./glog.sh clean scan --path /path/to/project --glogtoken "$GLOG_TOKEN" --registry "ghcr.io/glogai/"
  ```

---

## Commands

### `clean`
Cleans the `.glog` directory inside `--path` (removes all contents if the directory exists).

Equivalent behavior to:

- Check if `PATH/.glog` exists
- If it exists: delete everything inside it
- If it does not exist: print a message and continue

### `scan`
Runs language scanners via Docker images against the directory specified by `--path`.

- If `--lang` is not provided, the script auto-detects languages by file extensions.
- `resolver` is always appended to the language list and executed.

---

## Options

### `--path PATH`
Project/workspace directory to scan/clean.

- Default: current working directory (`pwd`)

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

Example:
```bash
--glogtoken "$GLOG_TOKEN"
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

## Full example

```bash
./glog.sh clean scan \
  --path ~/Documents/Projects/javaspringvulny-glog-fork \
  --glogtoken "*************" \
  --registry "ghcr.io/glogai/" \
  --client test \
  --env dev \
  --sarif-format-type STANDARD
```
