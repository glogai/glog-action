# Jenkins Windows Setup

This guide covers running `glog-action` from a Jenkins job on a Windows agent.

The recommended and simplest way to start with Jenkins integration is to use a Freestyle job with direct batch or shell integration first, then move toward more complex integrations only after the basic scan flow is working reliably.

It is the Windows counterpart to [Jenkins-Linux.md](Jenkins-Linux.md), but it uses:

- `cmd.exe` / `Execute Windows batch command`
- [`glog.cmd`](glog.cmd) as the entry point
- PowerShell only for parsing the generated SARIF file through a checked-in helper script

## Contents

- [Assumptions](#assumptions)
- [Jenkins SCM Layout](#jenkins-scm-layout)
- [Required Host Setup](#required-host-setup)
- [What The Batch Script Does](#what-the-batch-script-does)
- [Example Batch Step](#example-batch-step)
- [Scan-Only Batch Step](#scan-only-batch-step)
- [Archive Artifacts](#archive-artifacts)
- [Clarifications](#clarifications)
- [Troubleshooting](#troubleshooting)

## Assumptions

- Jenkins runs the build step as a Windows batch command
- Jenkins provides these environment variables:
  - `WORKSPACE`
  - `GLOG_TOKEN`
  - `GLOG_CLIENT`
  - `GLOG_ENV`
- `git`, `powershell`, and Docker are available on `PATH`

Unlike an interactive PowerShell session, a Jenkins Windows batch step should not rely on profile scripts to populate these variables. Set them in Jenkins job configuration or credentials bindings instead.

The easiest way to provide `GLOG_TOKEN`, `GLOG_CLIENT`, and `GLOG_ENV` when starting with Jenkins integration is to define them as Jenkins system environment variables so they are available to the build step without extra bootstrap logic.

These examples assume the repositories can be cloned directly by the batch step. If authentication to GitHub or Azure Repos is required, use Jenkins SCM integration or another available and appropriate enterprise-approved solution for those repositories instead of extending the example script with repository-specific authentication logic. In that case, remove the script-side `git clone` / `git fetch` block for those repositories and use the workspace path prepared by Jenkins or your external bootstrap mechanism.

## Jenkins SCM Layout

For a Freestyle job, the simplest layout is:

- `Source Code Management`: `None`
- `Build Environment`: enable `Delete workspace before build starts`

With this approach, the batch step clones or refreshes both:

- `%WORKSPACE%\\<repo name derived from GLOG_ACTION_REPO_URL>`
- `%WORKSPACE%\\<repo name derived from TARGET_REPO_URL>`

That keeps the bootstrap model consistent and avoids Jenkins multi-repository checkout complexity while you are still establishing the basic integration.

Enabling `Delete workspace before build starts` is recommended. It removes stale `.glog` output, old target repository checkouts, and other leftover files from previous builds that can make scan results or archived artifacts harder to reason about.

## Required Host Setup

The Windows agent needs:

- a working Docker installation
- Jenkins running under an account that can access Docker
- outbound access to `ghcr.io/glogai/*`

Quick checks on the agent:

```bat
where git
where powershell
docker version
```

If Jenkins runs as a Windows service account and Docker works only in your interactive login session, fix that first. The scan step will not work until the Jenkins service account can run `docker` successfully.

## What The Batch Script Does

The script below:

- defines the repository URLs and branches at the top of the script
- derives local checkout directory names from those repository URLs
- validates required Jenkins environment variables
- clones or refreshes `glog-action`
- clones or refreshes the repository to be scanned
- runs the Windows scanner wrapper with `AZURE` SARIF formatting
- optionally adds `--lang` when `SCAN_LANG` is set
- keeps command echo disabled so token values are not written to the Jenkins log
- prints only high-level progress messages while command echo stays disabled
- checks that `glog-scan.sarif` exists
- parses SARIF levels with PowerShell
- fails the build on `error` findings by default unless `FAIL_ON_ERROR=false`
- optionally fails on `warning` findings if `FAIL_ON_WARNING=true`

## Example Batch Step

Use this in a Jenkins `Execute Windows batch command` build step:

```bat
@echo off
setlocal EnableExtensions DisableDelayedExpansion

rem Keep command echo disabled so tokenized command lines are not written to the Jenkins log.
if not defined WORKSPACE (
  echo WORKSPACE is not set.
  exit /b 1
)

rem Change these to the repositories and branches you want Jenkins to use.
set "GLOG_ACTION_REPO_URL=https://github.com/glogai/glog-action.git"
set "GLOG_ACTION_BRANCH=main"
set "TARGET_REPO_URL=https://github.com/<organization>/<repository>.git"
set "TARGET_REPO_BRANCH=<branch>"
rem Optional: set SCAN_LANG to pass --lang. Do not reuse LANG because it may already be defined by the environment.
set "SCAN_LANG="

rem Trim a trailing slash so repo-name extraction is stable.
if "%GLOG_ACTION_REPO_URL:~-1%"=="/" set "GLOG_ACTION_REPO_URL=%GLOG_ACTION_REPO_URL:~0,-1%"
if "%TARGET_REPO_URL:~-1%"=="/" set "TARGET_REPO_URL=%TARGET_REPO_URL:~0,-1%"

rem %%~nxI preserves dotted repo names like service.api; strip only a trailing .git suffix.
for %%I in ("%GLOG_ACTION_REPO_URL:/=\%") do set "GLOG_ACTION_REPO_NAME=%%~nxI"
for %%I in ("%TARGET_REPO_URL:/=\%") do set "TARGET_REPO_NAME=%%~nxI"

if /I "%GLOG_ACTION_REPO_NAME:~-4%"==".git" set "GLOG_ACTION_REPO_NAME=%GLOG_ACTION_REPO_NAME:~0,-4%"
if /I "%TARGET_REPO_NAME:~-4%"==".git" set "TARGET_REPO_NAME=%TARGET_REPO_NAME:~0,-4%"

if not defined GLOG_ACTION_REPO_NAME (
  echo Could not derive repository name from GLOG_ACTION_REPO_URL.
  exit /b 1
)

if not defined TARGET_REPO_NAME (
  echo Could not derive repository name from TARGET_REPO_URL.
  exit /b 1
)

set "GLOG_ACTION_DIR=%WORKSPACE%\%GLOG_ACTION_REPO_NAME%"
set "TARGET_DIR=%WORKSPACE%\%TARGET_REPO_NAME%"
set "SARIF_FILE=%TARGET_DIR%\.glog\glog-scan.sarif"

if not defined GLOG_TOKEN (
  echo GLOG_TOKEN is not set.
  exit /b 1
)

if not defined GLOG_CLIENT (
  echo GLOG_CLIENT is not set.
  exit /b 1
)

if not defined GLOG_ENV (
  echo GLOG_ENV is not set.
  exit /b 1
)

where git >nul 2>&1
if errorlevel 1 (
  echo git is not available on PATH.
  exit /b 1
)

where powershell >nul 2>&1
if errorlevel 1 (
  echo powershell is not available on PATH.
  exit /b 1
)

rem Avoid parenthesized path-sensitive if/else blocks; cmd.exe can misparse values like C:\Jobs\My Job (1)\...
echo Preparing glog-action checkout: %GLOG_ACTION_DIR%
if exist "%GLOG_ACTION_DIR%\.git" goto refresh_glog_action
echo Cloning glog-action branch: %GLOG_ACTION_BRANCH%
git clone --depth 1 --branch "%GLOG_ACTION_BRANCH%" "%GLOG_ACTION_REPO_URL%" "%GLOG_ACTION_DIR%"
if errorlevel 1 exit /b %ERRORLEVEL%
goto after_glog_action
:refresh_glog_action
echo Refreshing glog-action branch: %GLOG_ACTION_BRANCH%
git -C "%GLOG_ACTION_DIR%" fetch --depth 1 origin "%GLOG_ACTION_BRANCH%"
if errorlevel 1 exit /b %ERRORLEVEL%
git -C "%GLOG_ACTION_DIR%" reset --hard FETCH_HEAD
if errorlevel 1 exit /b %ERRORLEVEL%
:after_glog_action

if exist "%GLOG_ACTION_DIR%\glog.cmd" goto have_scanner_entrypoint
echo Missing scanner entry point: %GLOG_ACTION_DIR%\glog.cmd
exit /b 1
:have_scanner_entrypoint

echo Preparing target checkout: %TARGET_DIR%
if exist "%TARGET_DIR%\.git" goto refresh_target
echo Cloning target branch: %TARGET_REPO_BRANCH%
git clone --depth 1 --branch "%TARGET_REPO_BRANCH%" "%TARGET_REPO_URL%" "%TARGET_DIR%"
if errorlevel 1 exit /b %ERRORLEVEL%
goto after_target
:refresh_target
echo Refreshing target branch: %TARGET_REPO_BRANCH%
git -C "%TARGET_DIR%" fetch --depth 1 origin "%TARGET_REPO_BRANCH%"
if errorlevel 1 exit /b %ERRORLEVEL%
git -C "%TARGET_DIR%" reset --hard FETCH_HEAD
if errorlevel 1 exit /b %ERRORLEVEL%
:after_target

rem Use glog.cmd so the wrapper picks pwsh or Windows PowerShell automatically.
rem Avoid a parenthesized if/else here; cmd.exe can misparse blocks when expanded values contain special characters.
if defined SCAN_LANG echo Language filter: %SCAN_LANG%
if not defined SCAN_LANG echo Language filter: auto-detect
echo Starting scan for: %TARGET_DIR%
echo SARIF upload to Glog server: enabled (-u)
if defined SCAN_LANG call "%GLOG_ACTION_DIR%\glog.cmd" scan --path "%TARGET_DIR%" --client "%GLOG_CLIENT%" --env "%GLOG_ENV%" --glogtoken "%GLOG_TOKEN%" --registry "ghcr.io/glogai/" --lang "%SCAN_LANG%" --sarif-format-type AZURE -u
if not defined SCAN_LANG call "%GLOG_ACTION_DIR%\glog.cmd" scan --path "%TARGET_DIR%" --client "%GLOG_CLIENT%" --env "%GLOG_ENV%" --glogtoken "%GLOG_TOKEN%" --registry "ghcr.io/glogai/" --sarif-format-type AZURE -u
if errorlevel 1 exit /b %ERRORLEVEL%

echo Checking SARIF output: %SARIF_FILE%
if exist "%SARIF_FILE%" goto have_sarif
echo Missing SARIF file: %SARIF_FILE%
exit /b 1
:have_sarif

rem Parse the generated SARIF with the checked-in helper script.
echo Parsing SARIF summary...
powershell -NoProfile -ExecutionPolicy Bypass -File "%GLOG_ACTION_DIR%\Summarize-Sarif.ps1" -SarifFile "%SARIF_FILE%"
if errorlevel 1 exit /b %ERRORLEVEL%

exit /b 0
```

## Scan-Only Batch Step

Use this smaller variant when the job should only run the scan and generate the SARIF output. It keeps the same bootstrap flow as the full example above, but it does not parse `glog-scan.sarif` and does not gate the build on SARIF findings.

```bat
@echo off
setlocal EnableExtensions DisableDelayedExpansion

rem Keep command echo disabled so tokenized command lines are not written to the Jenkins log.
if not defined WORKSPACE (
  echo WORKSPACE is not set.
  exit /b 1
)

rem Change these to the repositories and branches you want Jenkins to use.
set "GLOG_ACTION_REPO_URL=https://github.com/glogai/glog-action.git"
set "GLOG_ACTION_BRANCH=main"
set "TARGET_REPO_URL=https://github.com/<organization>/<repository>.git"
set "TARGET_REPO_BRANCH=<branch>"
rem Optional: set SCAN_LANG to pass --lang. Do not reuse LANG because it may already be defined by the environment.
set "SCAN_LANG="

rem Trim a trailing slash so repo-name extraction is stable.
if "%GLOG_ACTION_REPO_URL:~-1%"=="/" set "GLOG_ACTION_REPO_URL=%GLOG_ACTION_REPO_URL:~0,-1%"
if "%TARGET_REPO_URL:~-1%"=="/" set "TARGET_REPO_URL=%TARGET_REPO_URL:~0,-1%"

rem %%~nxI preserves dotted repo names like service.api; strip only a trailing .git suffix.
for %%I in ("%GLOG_ACTION_REPO_URL:/=\%") do set "GLOG_ACTION_REPO_NAME=%%~nxI"
for %%I in ("%TARGET_REPO_URL:/=\%") do set "TARGET_REPO_NAME=%%~nxI"

if /I "%GLOG_ACTION_REPO_NAME:~-4%"==".git" set "GLOG_ACTION_REPO_NAME=%GLOG_ACTION_REPO_NAME:~0,-4%"
if /I "%TARGET_REPO_NAME:~-4%"==".git" set "TARGET_REPO_NAME=%TARGET_REPO_NAME:~0,-4%"

if not defined GLOG_ACTION_REPO_NAME (
  echo Could not derive repository name from GLOG_ACTION_REPO_URL.
  exit /b 1
)

if not defined TARGET_REPO_NAME (
  echo Could not derive repository name from TARGET_REPO_URL.
  exit /b 1
)

set "GLOG_ACTION_DIR=%WORKSPACE%\%GLOG_ACTION_REPO_NAME%"
set "TARGET_DIR=%WORKSPACE%\%TARGET_REPO_NAME%"

if not defined GLOG_TOKEN (
  echo GLOG_TOKEN is not set.
  exit /b 1
)

if not defined GLOG_CLIENT (
  echo GLOG_CLIENT is not set.
  exit /b 1
)

if not defined GLOG_ENV (
  echo GLOG_ENV is not set.
  exit /b 1
)

where git >nul 2>&1
if errorlevel 1 (
  echo git is not available on PATH.
  exit /b 1
)

where powershell >nul 2>&1
if errorlevel 1 (
  echo powershell is not available on PATH.
  exit /b 1
)

rem Avoid parenthesized path-sensitive if/else blocks; cmd.exe can misparse values like C:\Jobs\My Job (1)\...
echo Preparing glog-action checkout: %GLOG_ACTION_DIR%
if exist "%GLOG_ACTION_DIR%\.git" goto refresh_glog_action
echo Cloning glog-action branch: %GLOG_ACTION_BRANCH%
git clone --depth 1 --branch "%GLOG_ACTION_BRANCH%" "%GLOG_ACTION_REPO_URL%" "%GLOG_ACTION_DIR%"
if errorlevel 1 exit /b %ERRORLEVEL%
goto after_glog_action
:refresh_glog_action
echo Refreshing glog-action branch: %GLOG_ACTION_BRANCH%
git -C "%GLOG_ACTION_DIR%" fetch --depth 1 origin "%GLOG_ACTION_BRANCH%"
if errorlevel 1 exit /b %ERRORLEVEL%
git -C "%GLOG_ACTION_DIR%" reset --hard FETCH_HEAD
if errorlevel 1 exit /b %ERRORLEVEL%
:after_glog_action

if exist "%GLOG_ACTION_DIR%\glog.cmd" goto have_scanner_entrypoint
echo Missing scanner entry point: %GLOG_ACTION_DIR%\glog.cmd
exit /b 1
:have_scanner_entrypoint

echo Preparing target checkout: %TARGET_DIR%
if exist "%TARGET_DIR%\.git" goto refresh_target
echo Cloning target branch: %TARGET_REPO_BRANCH%
git clone --depth 1 --branch "%TARGET_REPO_BRANCH%" "%TARGET_REPO_URL%" "%TARGET_DIR%"
if errorlevel 1 exit /b %ERRORLEVEL%
goto after_target
:refresh_target
echo Refreshing target branch: %TARGET_REPO_BRANCH%
git -C "%TARGET_DIR%" fetch --depth 1 origin "%TARGET_REPO_BRANCH%"
if errorlevel 1 exit /b %ERRORLEVEL%
git -C "%TARGET_DIR%" reset --hard FETCH_HEAD
if errorlevel 1 exit /b %ERRORLEVEL%
:after_target

rem Use glog.cmd so the wrapper picks pwsh or Windows PowerShell automatically.
rem Avoid a parenthesized if/else here; cmd.exe can misparse blocks when expanded values contain special characters.
if defined SCAN_LANG echo Language filter: %SCAN_LANG%
if not defined SCAN_LANG echo Language filter: auto-detect
echo Starting scan for: %TARGET_DIR%
echo SARIF upload to Glog server: enabled (-u)
if defined SCAN_LANG call "%GLOG_ACTION_DIR%\glog.cmd" scan --path "%TARGET_DIR%" --client "%GLOG_CLIENT%" --env "%GLOG_ENV%" --glogtoken "%GLOG_TOKEN%" --registry "ghcr.io/glogai/" --lang "%SCAN_LANG%" --sarif-format-type AZURE -u
if not defined SCAN_LANG call "%GLOG_ACTION_DIR%\glog.cmd" scan --path "%TARGET_DIR%" --client "%GLOG_CLIENT%" --env "%GLOG_ENV%" --glogtoken "%GLOG_TOKEN%" --registry "ghcr.io/glogai/" --sarif-format-type AZURE -u
if errorlevel 1 exit /b %ERRORLEVEL%
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

- Use forward slashes in the artifact pattern, even on Windows
- `**/.glog/glog-scan.sarif` is the recommended value when one scan result is produced per build
- If multiple repositories are scanned in the same workspace, this pattern archives every matching SARIF file

After a successful archive:

- Jenkins may show an `Artifacts` link in the build page sidebar
- some Jenkins themes show archived files in the main build page content instead
- if the UI link is missing, the file is still archived if it exists under the build archive directory

Typical archive location on disk:

```text
<JENKINS_HOME>\jobs\<job-name>\builds\<build-number>\archive\
```

The original generated file remains in the workspace, typically at:

```text
%TARGET_DIR%\.glog\glog-scan.sarif
```

## Clarifications

### Why use `glog.cmd` instead of `glog.ps1` directly?

`glog.cmd` picks `pwsh` when available and falls back to Windows PowerShell automatically. That makes the Jenkins batch step shorter and avoids hardcoding one PowerShell executable path.

### Why is PowerShell still used in a batch job?

Batch is adequate for orchestration, Git commands, and exit-code handling. It is poor at parsing JSON. The script calls the checked-in [`Summarize-Sarif.ps1`](Summarize-Sarif.ps1) helper to read `glog-scan.sarif`, print the SARIF summary, and apply the `FAIL_ON_ERROR` / `FAIL_ON_WARNING` policy.

### Why clone both repositories in the batch step?

Using one bootstrap mechanism for both repositories is easier to reason about than mixing Jenkins SCM checkout for one repository and ad hoc cloning for the other. If you want both:

- `%WORKSPACE%\<repo name derived from GLOG_ACTION_REPO_URL>`
- `%WORKSPACE%\<repo name derived from TARGET_REPO_URL>`

the simplest Freestyle-job approach is to keep `Source Code Management` set to `None` and clone both repositories in the batch step.

### What do `FAIL_ON_ERROR` and `FAIL_ON_WARNING` do?

By default:

- `error` findings fail the build
- `warning` findings only print a warning
- `note` findings are informational

If Jenkins sets:

```bat
set FAIL_ON_ERROR=false
```

then error findings are reported in the console output but do not fail the build.

If Jenkins sets:

```bat
set FAIL_ON_WARNING=true
```

then warning findings also fail the build.

## Troubleshooting

### `WORKSPACE is not set`

The job is not running in a normal Jenkins workspace context, or the variable is not being passed into the batch step.

### `Missing scanner entry point`

`glog-action` was not cloned successfully into `%WORKSPACE%\glog-action`, or the clone/update step failed earlier in the log.

### `Missing SARIF file`

The scan did not produce `%TARGET_DIR%\.glog\glog-scan.sarif`. Check:

- whether the scan failed earlier in the log
- Docker access for the Jenkins account
- `GLOG_TOKEN`
- registry/image pull access

### `docker ... permission denied` or Docker not available

The Jenkins Windows account cannot talk to Docker yet. Fix Docker access for the Jenkins service account before troubleshooting the scan script itself.

### `GLOG_CLIENT`, `GLOG_ENV`, or `GLOG_TOKEN` are empty

Set them in Jenkins as environment variables or credentials bindings. Do not expect them to be inherited from a user login session automatically.

### Token or full scan command appears in the Jenkins log

If the log contains the full `glog.cmd scan ... --glogtoken ...` command line, command echo was re-enabled somewhere around the batch step. The current example keeps `@echo off` in place and emits only explicit `echo` progress messages so token-bearing commands are not written to the Jenkins log.

### Both scan variants run, or clone/check blocks behave unexpectedly

This is usually a `cmd.exe` parsing problem, not a Jenkins condition problem. Parenthesized blocks that expand path variables such as `%WORKSPACE%`, `%TARGET_DIR%`, or `%SARIF_FILE%` can be misparsed when those values contain characters like `(` or `)`, which is common when job names appear in workspace paths. The current example avoids that by using labels for clone/refresh flow, single-line `if defined` checks for the scan command, and `$env:SARIF_FILE` inside the PowerShell parser.

### `) was unexpected at this time.` during SARIF parsing

That error comes from `cmd.exe`, not from the SARIF file itself. The usual cause is a `for /f` or `if (...)` batch block that embeds complex PowerShell code or path values containing `(` or `)`. The current example avoids `for /f` for SARIF parsing and calls the checked-in PowerShell helper instead.

### `^` is not recognized or `'try' is not recognized as an internal or external command`

That failure means `cmd.exe` split an embedded multiline PowerShell command instead of passing it through as one script. Older inline examples that use `powershell -Command ^` are brittle in Jenkins batch steps. Use the current example, which calls [`Summarize-Sarif.ps1`](Summarize-Sarif.ps1) with `-File` and `-SarifFile`, so `cmd.exe` does not have to parse multiline PowerShell at all.

### `glog-action` or the scan target repository was not checked out

With this setup, Jenkins SCM is intentionally set to `None`. Both repositories are cloned by the batch step itself. Their checkout directory names are derived from `GLOG_ACTION_REPO_URL` and `TARGET_REPO_URL`. If one is missing, inspect those URLs and the related `git clone` or `git fetch` commands in the build log.

### Archived file exists on disk but no `Artifacts` link is visible

If the file exists under the build's `archive\` directory, Jenkins already archived it successfully. The missing UI link is a presentation issue, not an archiving failure. Check the main build page body or open the artifact directly from:

```text
/job/<job-name>/<build-number>/artifact/
```
