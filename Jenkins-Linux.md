# Jenkins Linux Setup

This guide covers running `glog.sh` from a Jenkins job on a Linux agent.

The recommended and simplest way to start with Jenkins integration is to use a Freestyle job with direct shell integration first, then move toward more complex integrations only after the basic scan flow is working reliably.

## Contents

- [Assumptions](#assumptions)
- [Jenkins SCM Layout](#jenkins-scm-layout)
- [Required Host Setup](#required-host-setup)
- [Example Shell Step](#example-shell-step)
- [Scan-Only Shell Step](#scan-only-shell-step)
- [Archive Artifacts](#archive-artifacts)
- [Troubleshooting](#troubleshooting)

## Assumptions

- Jenkins runs the shell step with `/bin/sh`
- Jenkins provides `$WORKSPACE`
- Jenkins provides these environment variables:
  - `GLOG_TOKEN`
  - `GLOG_CLIENT`
  - `GLOG_ENV`
- `git`, `python3`, and Docker are available on `PATH`
- The Jenkins OS user can access the Docker daemon

Do not rely on `~/.profile` in Jenkins shell steps. Jenkins does not run a login shell by default.

The easiest way to provide `GLOG_TOKEN`, `GLOG_CLIENT`, and `GLOG_ENV` when starting with Jenkins integration is to define them as Jenkins system environment variables so they are available to the build step without extra shell bootstrap logic.

These examples assume the repositories can be cloned directly by the shell step. If authentication to GitHub or Azure Repos is required, use Jenkins SCM integration or another available and appropriate enterprise-approved solution for those repositories instead of extending the example script with repository-specific authentication logic. In that case, remove the script-side `git clone` / `git fetch` block for those repositories and use the workspace path prepared by Jenkins or your external bootstrap mechanism.

## Jenkins SCM Layout

For a Freestyle job, the simplest layout is:

- `Source Code Management`: `None`
- `Build Environment`: enable `Delete workspace before build starts`

With this approach, the shell step clones or refreshes both:

- `$WORKSPACE/<repo name derived from GLOG_ACTION_REPO_URL>`
- `$WORKSPACE/<repo name derived from TARGET_REPO_URL>`

That keeps the bootstrap model consistent and avoids Jenkins multi-repository checkout complexity while you are still establishing the basic integration.

Enabling `Delete workspace before build starts` is recommended. It removes stale `.glog` output, old target repository checkouts, and other leftover files from previous builds that can make scan results or archived artifacts harder to reason about.

## Required Host Setup

The Jenkins user must be able to talk to Docker:

```sh
sudo usermod -aG docker jenkins
sudo systemctl restart jenkins
```

Verify it on the agent:

```sh
sudo -u jenkins docker ps
```

## Example Shell Step

This shell step:

- validates required environment variables
- defines the repository URLs and branches at the top of the script
- derives local checkout directory names from those repository URLs
- clones or refreshes `glog-action`
- clones or refreshes the repository to be scanned
- runs the scan with `AZURE` SARIF formatting
- optionally adds `--lang` when `SCAN_LANG` is set
- keeps command tracing disabled so token values are not written to the Jenkins log
- prints only high-level progress messages after tracing is disabled
- parses `glog-scan.sarif`
- fails the build on `error` findings by default unless `FAIL_ON_ERROR=false`
- optionally fails on `warning` findings if `FAIL_ON_WARNING=true`

```sh
set -eu

# Jenkins Execute shell commonly starts with /bin/sh -xe; disable xtrace before touching secrets.
set +x

# Change these to the repositories and branches you want Jenkins to use.
GLOG_ACTION_REPO_URL="https://github.com/glogai/glog-action.git"
GLOG_ACTION_BRANCH="main"
TARGET_REPO_URL="https://github.com/<organization>/<repository>.git"
TARGET_REPO_BRANCH="<branch>"
# Optional: set SCAN_LANG to pass --lang. Do not reuse LANG because it is commonly a locale variable.
SCAN_LANG=""

# Trim a trailing slash so basename extraction is stable.
GLOG_ACTION_REPO_URL=${GLOG_ACTION_REPO_URL%/}
TARGET_REPO_URL=${TARGET_REPO_URL%/}

# Derive local checkout directory names from the repository URLs.
GLOG_ACTION_REPO_NAME=$(basename "$GLOG_ACTION_REPO_URL")
GLOG_ACTION_REPO_NAME=${GLOG_ACTION_REPO_NAME%.git}
TARGET_REPO_NAME=$(basename "$TARGET_REPO_URL")
TARGET_REPO_NAME=${TARGET_REPO_NAME%.git}

: "${GLOG_ACTION_REPO_NAME:?Could not derive repository name from GLOG_ACTION_REPO_URL}"
: "${TARGET_REPO_NAME:?Could not derive repository name from TARGET_REPO_URL}"

GLOG_ACTION_DIR="$WORKSPACE/$GLOG_ACTION_REPO_NAME"
TARGET_DIR="$WORKSPACE/$TARGET_REPO_NAME"

: "${GLOG_TOKEN:?Set GLOG_TOKEN in Jenkins}"
: "${GLOG_CLIENT:?Set GLOG_CLIENT in Jenkins}"
: "${GLOG_ENV:?Set GLOG_ENV in Jenkins}"

# Reuse existing clones when available so later builds only fetch the branch tip.
echo "Preparing glog-action checkout: $GLOG_ACTION_DIR"
if [ ! -d "$GLOG_ACTION_DIR/.git" ]; then
  echo "Cloning glog-action branch: $GLOG_ACTION_BRANCH"
  git clone --depth 1 --branch "$GLOG_ACTION_BRANCH" "$GLOG_ACTION_REPO_URL" "$GLOG_ACTION_DIR"
else
  echo "Refreshing glog-action branch: $GLOG_ACTION_BRANCH"
  git -C "$GLOG_ACTION_DIR" fetch --depth 1 origin "$GLOG_ACTION_BRANCH"
  git -C "$GLOG_ACTION_DIR" reset --hard FETCH_HEAD
fi

echo "Preparing target checkout: $TARGET_DIR"
if [ ! -d "$TARGET_DIR/.git" ]; then
  echo "Cloning target branch: $TARGET_REPO_BRANCH"
  git clone --depth 1 --branch "$TARGET_REPO_BRANCH" "$TARGET_REPO_URL" "$TARGET_DIR"
else
  echo "Refreshing target branch: $TARGET_REPO_BRANCH"
  git -C "$TARGET_DIR" fetch --depth 1 origin "$TARGET_REPO_BRANCH"
  git -C "$TARGET_DIR" reset --hard FETCH_HEAD
fi

# Add --lang only when SCAN_LANG is set.
if [ -n "${SCAN_LANG:-}" ]; then
  set -- --lang "$SCAN_LANG"
  echo "Language filter: $SCAN_LANG"
else
  set --
  echo "Language filter: auto-detect"
fi

# xtrace stays disabled because the scan command line carries secrets.
echo "Starting scan for: $TARGET_DIR"
echo "SARIF upload to Glog server: enabled (-u)"
"$GLOG_ACTION_DIR/glog.sh" scan \
  --path "$TARGET_DIR" \
  --client "$GLOG_CLIENT" \
  --env "$GLOG_ENV" \
  --glogtoken "$GLOG_TOKEN" \
  --registry "ghcr.io/glogai/" \
  "$@" \
  --sarif-format-type AZURE \
  -u

sarif="$TARGET_DIR/.glog/glog-scan.sarif"

echo "Checking SARIF output: $sarif"
[ -f "$sarif" ] || {
  echo "Missing SARIF file: $sarif"
  exit 1
}

# Parse the generated SARIF and return "errors warnings notes" as three integers.
echo "Parsing SARIF summary..."
counts=$(
python3 - "$sarif" <<'PY'
import json, sys

path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    sarif = json.load(f)

errors = 0
warnings = 0
notes = 0

for run in sarif.get("runs", []):
    for result in run.get("results", []):
        level = (result.get("level") or "warning").lower()
        if level == "error":
            errors += 1
        elif level == "warning":
            warnings += 1
        elif level == "note":
            notes += 1

print(errors, warnings, notes)
PY
) || {
  echo "Failed to parse SARIF: $sarif"
  exit 1
}

set -- $counts
errors=$1
warnings=$2
notes=$3

echo "SARIF summary: errors=$errors warnings=$warnings notes=$notes"

# Gate error-level and warning-level findings independently.
if [ "$errors" -gt 0 ]; then
  echo "Error: SARIF contains error-level findings"
  if [ "${FAIL_ON_ERROR:-true}" = "true" ]; then
    echo "Blocking build because FAIL_ON_ERROR=true"
    exit 1
  fi
fi

if [ "$warnings" -gt 0 ]; then
  echo "Warning: SARIF contains warning-level findings"
  if [ "${FAIL_ON_WARNING:-false}" = "true" ]; then
    echo "Blocking build because FAIL_ON_WARNING=true"
    exit 1
  fi
fi
```

## Scan-Only Shell Step

Use this smaller variant when the job should only run the scan and generate the SARIF output. It keeps the same bootstrap flow as the full example above, but it does not parse `glog-scan.sarif` and does not gate the build on SARIF findings.

```sh
set -eu

# Jenkins Execute shell commonly starts with /bin/sh -xe; disable xtrace before touching secrets.
set +x

# Change these to the repositories and branches you want Jenkins to use.
GLOG_ACTION_REPO_URL="https://github.com/glogai/glog-action.git"
GLOG_ACTION_BRANCH="main"
TARGET_REPO_URL="https://github.com/<organization>/<repository>.git"
TARGET_REPO_BRANCH="<branch>"
# Optional: set SCAN_LANG to pass --lang. Do not reuse LANG because it is commonly a locale variable.
SCAN_LANG=""

# Trim a trailing slash so basename extraction is stable.
GLOG_ACTION_REPO_URL=${GLOG_ACTION_REPO_URL%/}
TARGET_REPO_URL=${TARGET_REPO_URL%/}

# Derive local checkout directory names from the repository URLs.
GLOG_ACTION_REPO_NAME=$(basename "$GLOG_ACTION_REPO_URL")
GLOG_ACTION_REPO_NAME=${GLOG_ACTION_REPO_NAME%.git}
TARGET_REPO_NAME=$(basename "$TARGET_REPO_URL")
TARGET_REPO_NAME=${TARGET_REPO_NAME%.git}

: "${GLOG_ACTION_REPO_NAME:?Could not derive repository name from GLOG_ACTION_REPO_URL}"
: "${TARGET_REPO_NAME:?Could not derive repository name from TARGET_REPO_URL}"

GLOG_ACTION_DIR="$WORKSPACE/$GLOG_ACTION_REPO_NAME"
TARGET_DIR="$WORKSPACE/$TARGET_REPO_NAME"

: "${GLOG_TOKEN:?Set GLOG_TOKEN in Jenkins}"
: "${GLOG_CLIENT:?Set GLOG_CLIENT in Jenkins}"
: "${GLOG_ENV:?Set GLOG_ENV in Jenkins}"

# Reuse existing clones when available so later builds only fetch the branch tip.
echo "Preparing glog-action checkout: $GLOG_ACTION_DIR"
if [ ! -d "$GLOG_ACTION_DIR/.git" ]; then
  echo "Cloning glog-action branch: $GLOG_ACTION_BRANCH"
  git clone --depth 1 --branch "$GLOG_ACTION_BRANCH" "$GLOG_ACTION_REPO_URL" "$GLOG_ACTION_DIR"
else
  echo "Refreshing glog-action branch: $GLOG_ACTION_BRANCH"
  git -C "$GLOG_ACTION_DIR" fetch --depth 1 origin "$GLOG_ACTION_BRANCH"
  git -C "$GLOG_ACTION_DIR" reset --hard FETCH_HEAD
fi

echo "Preparing target checkout: $TARGET_DIR"
if [ ! -d "$TARGET_DIR/.git" ]; then
  echo "Cloning target branch: $TARGET_REPO_BRANCH"
  git clone --depth 1 --branch "$TARGET_REPO_BRANCH" "$TARGET_REPO_URL" "$TARGET_DIR"
else
  echo "Refreshing target branch: $TARGET_REPO_BRANCH"
  git -C "$TARGET_DIR" fetch --depth 1 origin "$TARGET_REPO_BRANCH"
  git -C "$TARGET_DIR" reset --hard FETCH_HEAD
fi

# Add --lang only when SCAN_LANG is set.
if [ -n "${SCAN_LANG:-}" ]; then
  set -- --lang "$SCAN_LANG"
  echo "Language filter: $SCAN_LANG"
else
  set --
  echo "Language filter: auto-detect"
fi

# xtrace stays disabled because the scan command line carries secrets.
echo "Starting scan for: $TARGET_DIR"
echo "SARIF upload to Glog server: enabled (-u)"
"$GLOG_ACTION_DIR/glog.sh" scan \
  --path "$TARGET_DIR" \
  --client "$GLOG_CLIENT" \
  --env "$GLOG_ENV" \
  --glogtoken "$GLOG_TOKEN" \
  --registry "ghcr.io/glogai/" \
  "$@" \
  --sarif-format-type AZURE \
  -u
```

## Archive Artifacts

To archive only the generated SARIF file in a Freestyle job:

1. Open `Post-build Actions`
2. Add `Archive the artifacts`
3. Set `Files to archive` to:

```text
**/.glog/glog-scan.sarif
```

This pattern is workspace-relative and does not depend on a specific project directory name.

If you want Jenkins to keep the SARIF file even when the build fails because of SARIF gating, leave `Only if build succeeds` unchecked.

Notes:

- Use forward slashes in the artifact pattern
- `**/.glog/glog-scan.sarif` is the recommended value when one scan result is produced per build
- If multiple repositories are scanned in the same workspace, this pattern archives every matching SARIF file

After a successful archive:

- Jenkins may show an `Artifacts` link in the build page sidebar
- some Jenkins themes show archived files in the main build page content instead
- if the UI link is missing, the file is still archived if it exists under the build archive directory

Typical archive location on disk:

```text
<JENKINS_HOME>/jobs/<job-name>/builds/<build-number>/archive/
```

For example on many Linux Jenkins installations:

```text
/var/lib/jenkins/jobs/glog-test/builds/21/archive/
```

The original generated file remains in the workspace, typically at:

```text
$TARGET_DIR/.glog/glog-scan.sarif
```

## Troubleshooting

### `Missing SARIF file`

The scan did not produce `$TARGET_DIR/.glog/glog-scan.sarif`. Check:

- Docker access
- `GLOG_TOKEN`
- image pull access to `ghcr.io/glogai/*`
- whether the scan itself failed earlier in the log

### `permission denied while trying to connect to the Docker daemon socket`

The Jenkins user does not have Docker access yet. Apply the Docker group setup above and restart Jenkins.

### Empty `--client`, `--env`, or `--glogtoken`

The Jenkins job is not exporting `GLOG_CLIENT`, `GLOG_ENV`, or `GLOG_TOKEN`. Configure them in Jenkins as job environment variables or credentials bindings.

### Token or full scan command appears in the Jenkins log

If the log contains lines such as `+ GLOG_TOKEN=...` or the full `glog.sh scan ... --glogtoken ...` command line, shell tracing is still enabled. The current example disables it with `set +x` immediately after `set -eu` so only the explicit `echo` progress messages and scanner output remain visible.

### `glog-action` or the scan target repository was not checked out

With this setup, Jenkins SCM is intentionally set to `None`. Both repositories are cloned by the shell step itself. Their checkout directory names are derived from `GLOG_ACTION_REPO_URL` and `TARGET_REPO_URL`. If one is missing, inspect those URLs and the related `git clone` or `git fetch` commands in the build log.

### Archived file exists on disk but no `Artifacts` link is visible

If the file exists under the build's `archive/` directory, Jenkins already archived it successfully. The missing UI link is a presentation issue, not an archiving failure. Check the main build page body or open the artifact directly from:

```text
/job/<job-name>/<build-number>/artifact/
```
