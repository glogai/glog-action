# Glog Scan Action

`glog-action` is a composite GitHub Action that runs Glog.AI scanners in Docker, writes SARIF output, and can optionally publish findings to GitHub code scanning, create GitHub issues, and hand newly created issues to Copilot for remediation.

## What This Action Does

- runs `glog.sh scan` against the repository root or a subdirectory
- auto-detects scan targets when `lang` is not provided
- always adds the `resolver` scanner to each run
- writes scan artifacts under `<path>/.glog/`
- stages and pushes the generated SARIF report when it changes
- optionally uploads SARIF to GitHub code scanning
- optionally creates or updates GitHub issues from SARIF findings
- optionally assigns newly created issues to `copilot-swe-agent[bot]`

## Requirements

- Linux runner with Docker available; `ubuntu-latest` is the expected target
- access to the `ghcr.io/glogai/*` scanner images
- a valid `glog-token`
- a GitHub token that can read packages from GHCR and write to the target repository
- if `upload: true` is enabled, SARIF upload support for the repository and `security-events: write`
- if `issue: true` or `autofix: true` is enabled, `issues: write`
- branch protection rules must allow the workflow token to push commits if you want the generated SARIF committed back to the branch

Recommended workflow permissions:

```yaml
permissions:
  contents: write
  packages: read
  security-events: write
  issues: write
```

If your repository cannot use GitHub code scanning or GitHub Advanced Security, or if GitHub rejects the generated file as invalid SARIF, set `upload: false`.

## Supported Scan Keys

When you set `lang`, use the following programming language to scan key mapping:

| Programming language | Scan key |
| --- | --- |
| C / C++ | `cpp` |
| Java | `java` |
| JavaScript / TypeScript | `javascript` |
| Python | `python` |
| Kotlin | `kotlin` |
| PHP | `php` |
| Ruby | `ruby` |
| C# | `csharp` |
| Terraform | `terraform` |
| ObjectScript | `objectscript` |

Additional non-language scan keys are also available:

| Scanner type | Scan key |
| --- | --- |
| Open source dependency scan | `oss` |
| Dependency / reference resolver | `resolver` |

When `lang` is omitted, the action auto-detects programming languages from file extensions in the selected scan path. JavaScript detection also covers `js`, `ts`, `jsx`, and `tsx` files.

The non-language scan keys `oss` and `secrets` are available through `lang`, but are not auto-detected. `resolver` is always added automatically.

## Usage

### Recommended Workflow

Use this pattern when the action repository is private or otherwise not directly resolvable by GitHub Actions.

```yaml
name: Glog.AI Scan

on:
  workflow_dispatch:

permissions:
  contents: write
  packages: read
  security-events: write
  issues: write

jobs:
  glog-scan:
    runs-on: ubuntu-latest

    steps:
      - uses: actions/checkout@v6

      - name: Checkout glog-action repository
        uses: actions/checkout@v6
        with:
          repository: glogai/glog-action
          token: ${{ secrets.PAT_TOKEN }}
          path: .github/glog-action
          ref: main

      - name: Run Glog.AI
        uses: ./.github/glog-action
        with:
          lang: 'python'
          upload: 'true'
          client: 'test'
          env: 'dev'
          github-token: ${{ secrets.PAT_TOKEN }}
          glog-token: ${{ secrets.GLOG_TOKEN }}
```

`PAT_TOKEN` should have the repository and package permissions needed for GHCR login, pushing the SARIF commit, and optional issue operations.

### Direct Repository Reference

Use `uses: glogai/glog-action@main` only if GitHub Actions can resolve that repository directly in your environment, for example when the action repository is public or explicitly shared for private action reuse.

```yaml
steps:
  - uses: actions/checkout@v6

  - name: Run Glog.AI
    uses: glogai/glog-action@main
    with:
      lang: 'python'
      upload: 'true'
      client: 'test'
      env: 'dev'
      github-token: ${{ secrets.PAT_TOKEN }}
      glog-token: ${{ secrets.GLOG_TOKEN }}
```

### Scanning Only Selected Files

`files` is relative to `path`. The action copies only those files into a temporary scan directory and then persists the resulting `.glog` artifacts back into the real project path.

```yaml
steps:
    - uses: actions/checkout@v6
    
    - name: Checkout glog-action repository
      uses: actions/checkout@v6
      with:
        repository: glogai/glog-action
        token: ${{ secrets.PAT_TOKEN }}
        path: .github/glog-action
        ref: main
    
    - name: Run Glog.AI
      uses: ./.github/glog-action
      with:
        lang: 'python'
        upload: 'true'
        client: 'test'
        env: 'dev'
        path: 'backend'
        files: 'src/api/routes.py,src/db/models.py'
        github-token: ${{ secrets.PAT_TOKEN }}
        glog-token: ${{ secrets.GLOG_TOKEN }}
```

If you see `Unable to resolve action 'glogai/glog-action', not found`, GitHub could not fetch the action repository during workflow planning. In that case, use the checked-out local-path form shown above.

If you see `Unable to upload "./.glog/glog-scan.sarif" as it is not valid SARIF`, disable SARIF upload with `upload: false` as shown in the examples above.

## Inputs

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `glog-token` | Yes | - | Token passed to the scanner containers. |
| `github-token` | Usually | - | Token used for GHCR login and for git / issue operations. In practice most workflows need this. |
| `path` | No | `.` | Relative path inside the repository to scan. Scan artifacts are written to `<path>/.glog/`. |
| `lang` | No | auto-detect | Comma-separated scan keys such as `python,javascript,terraform`. |
| `files` | No | - | Comma-separated file list relative to `path`; limits the scan to specific files. |
| `ignore` | No | - | Comma-separated ignore patterns passed through to the scanner containers. |
| `client` | No | - | Client name forwarded to the scanner containers. |
| `env` | No | - | Environment suffix, for example `dev` for `https://<client>.dev.glog.ai`. |
| `debug` | No | `false` | Stages `.glog/glog-scan.log` in addition to the SARIF report. |
| `upload` | No | `true` | Uploads `<path>/.glog/glog-scan.sarif` to GitHub code scanning. If GitHub rejects the file as invalid SARIF, set this to `false`. |
| `issue` | No | `false` | Creates or updates GitHub issues from SARIF findings, deduplicated by fingerprint. |
| `autofix` | No | `false` | Assigns newly created issues to `copilot-swe-agent[bot]`. This is only meaningful when `issue: true`. |
| `max-issues` | No | `30` | Maximum number of SARIF findings converted into issues in one run. |
| `max-assign` | No | `30` | Maximum number of newly created issues assigned to Copilot in one run. |

## Generated Files and Side Effects

The action does more than just scan source code:

- generates `<path>/.glog/glog-scan.sarif`
- stages `<path>/.glog/glog-scan.sarif` with `git add`
- stages `<path>/.glog/glog-scan.log` when `debug: true`
- commits and pushes the generated report when the staged content changed
- uploads the SARIF file to GitHub code scanning when `upload: true`
- creates new issues with the labels `sarif`, `security`, `glog`, and `copilot`, and updates matching open issues when `issue: true`
- assigns newly created issues to Copilot when `autofix: true`

Important notes:

- closed issues matched by fingerprint are intentionally left closed
- `autofix` only assigns issues created in the current run, not previously existing issues
- if there are no staged changes after the scan, the commit and push steps are skipped

## Local CLI

For manual usage of the underlying Bash helper script, see [CLI.md](CLI.md).

## Support

Open an issue in this repository or contact `info@glog.ai`.
