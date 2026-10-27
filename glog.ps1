#!/usr/bin/env pwsh
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$defaultLangs = @('cpp', 'java', 'javascript', 'python', 'kotlin', 'php', 'ruby', 'csharp', 'oss', 'terraform', 'secrets', 'resolver', 'objectscript', 'go')

# Image tags are derived, not authored. glog-tools/gbuild.sh names an image
# glog-scan-<lang>-<first 4 hex of md5("<lang>-<tool>" + SALT)> and writes the
# whole table to images.env, checked in beside this script and regenerated with
# `./gbuild.sh --env` in glog-tools. glog-tools' test_images_env suite fails if
# this copy drifts from the generator.
#
# The tags used to be written out here, in glog.sh and in glog-tools' gscan.sh.
# Three hand-kept copies of a derived value drift, and they did: after the C/C++
# opengrep stage shipped, this script and glog.sh still named devskim's tag
# alone, so a scan of a C/C++ repo quietly skipped the stage the other drivers
# ran.
$imagesEnvPath = Join-Path $PSScriptRoot 'images.env'
if (-not (Test-Path -LiteralPath $imagesEnvPath)) {
    Write-Error ("images.env is missing from {0}, so no image tag can be resolved. " +
                 "It ships with this action; regenerate it from glog-tools with " +
                 "'./gbuild.sh --env' if the checkout is incomplete." -f $PSScriptRoot)
    exit 2
}

# Flat KEY=VALUE, no quoting or expansion, so the parse is a split on the first
# '=' - the same file glog.sh sources.
$scanImage = @{}
foreach ($line in Get-Content -LiteralPath $imagesEnvPath) {
    $trimmed = $line.Trim()
    if ($trimmed -eq '' -or $trimmed.StartsWith('#')) { continue }
    $eq = $trimmed.IndexOf('=')
    if ($eq -lt 1) { continue }
    $scanImage[$trimmed.Substring(0, $eq)] = $trimmed.Substring($eq + 1)
}

# A missing key means this script and images.env disagree about which stages
# exist, which is the drift the generated file is here to prevent - so fail
# loudly rather than expanding to an empty tag and pulling "ghcr.io/glogai/".
function Get-ScanImage([string]$key) {
    if (-not $scanImage.ContainsKey($key)) {
        throw "images.env has no entry '$key'; regenerate it from glog-tools with './gbuild.sh --env'."
    }
    return $scanImage[$key]
}

# Which stage runs for which language stays this driver's own decision - several
# languages have more than one engine built for them, and a few of those are not
# run here (gosec, phpstan, clair, and devskim for csharp and javascript). The
# tags, though, all come from images.env. Order matters and is preserved.
$imageMap = @{
    oss          = @((Get-ScanImage 'GLOG_SCAN_IMAGE_OSS_DEPSCAN'))
    java         = @((Get-ScanImage 'GLOG_SCAN_IMAGE_JAVA_SPOTBUGS'), (Get-ScanImage 'GLOG_SCAN_IMAGE_JAVA_OPENGREP'))
    ruby         = @((Get-ScanImage 'GLOG_SCAN_IMAGE_RUBY_BRAKEMAN'))
    terraform    = @((Get-ScanImage 'GLOG_SCAN_IMAGE_TERRAFORM_TERRAFORM'), (Get-ScanImage 'GLOG_SCAN_IMAGE_TERRAFORM_OPENGREP'))
    cpp          = @((Get-ScanImage 'GLOG_SCAN_IMAGE_CPP_DEVSKIM'))
    python       = @((Get-ScanImage 'GLOG_SCAN_IMAGE_PYTHON_BANDIT'), (Get-ScanImage 'GLOG_SCAN_IMAGE_PYTHON_OPENGREP'))
    secrets      = @((Get-ScanImage 'GLOG_SCAN_IMAGE_SECRETS_GITLEAKS'))
    reachability = @((Get-ScanImage 'GLOG_SCAN_IMAGE_REACHABILITY_REACHABILITY'))
    csharp       = @((Get-ScanImage 'GLOG_SCAN_IMAGE_CSHARP_OPENGREP'))
    php          = @((Get-ScanImage 'GLOG_SCAN_IMAGE_PHP_DEVSKIM'), (Get-ScanImage 'GLOG_SCAN_IMAGE_PHP_OPENGREP'))
    kotlin       = @((Get-ScanImage 'GLOG_SCAN_IMAGE_KOTLIN_SPOTBUGS'))
    resolver     = @((Get-ScanImage 'GLOG_SCAN_IMAGE_RESOLVER_GLOG'))
    javascript   = @((Get-ScanImage 'GLOG_SCAN_IMAGE_JAVASCRIPT_OPENGREP'))
    objectscript = @((Get-ScanImage 'GLOG_SCAN_IMAGE_OBJECTSCRIPT_OPENGREP'))
    go           = @((Get-ScanImage 'GLOG_SCAN_IMAGE_GO_OPENGREP'))
    # CycloneDX SBOM generator (cdxgen). Writes /app/.glog/sbom.cdx.json which
    # the resolver (running after) uploads to /api/sca/resolver/sbom/.
    sbom         = @((Get-ScanImage 'GLOG_SCAN_IMAGE_SBOM_CDXGEN'))
    # VEX: depscan + reachability over the source, SBOM of this run as input.
    vex          = @((Get-ScanImage 'GLOG_SCAN_IMAGE_OSS_DEPSCAN'))
}

function Show-Usage {
    @'
Glog.AI Scanner CLI
Usage: glog.ps1 [clean] [scan] [remediate] [options]

  remediate                 Run only the AI remediation step over the .glog/glog-scan.sarif
                            an earlier scan left (same options as --remediate)

Options:
  --path PATH               Project path to scan (default: current dir)
  --lang l1,l2              Languages list (default: auto-detect)
  --client CLIENT           Client identifier for Glog.AI
  --env ENV                 Environment (dev, stage, prod)
  --glogtoken TOKEN         Glog API Token
  --registry REGISTRY       Docker registry prefix (default: ghcr.io/glogai/)
  --ignore PATTERN          Patterns to ignore
  --sarif-format-type TYPE  Default: GITHUB
  --files FILE1,FILE2       Comma-separated list of files to scan relative to --path
  -u|--upload               Upload scan results to On-Prem Dashboard (SARIF, and SBOM if --sbom)
  --inventory               Force the inventory scanner to run (in addition to detected languages)
  --sbom                    Generate a CycloneDX SBOM via resolver (--with-sbom)
  --sbom-only               Skip SARIF, only produce the SBOM (implies --sbom)
  --cbom                    Generate a CycloneDX CBOM (cryptographic inventory) and upload it.
  --vex                     Generate a VEX with depscan + reachability (implies --sbom).
                            Install dependencies first or most results stay in_triage.
  --scl-uuid UUID           Source Code Location UUID to bind SARIF/SBOM uploads to
  --server-sarif-format-type TYPE
                            Format for the uploaded SARIF when it differs from
                            --sarif-format-type: the resolver then runs twice, once per format.
  --sbom-min-grade GRADE    Fail the run (exit 3) when the SBOM scores below GRADE (A-F)
  --fail-on-upload-error    Exit non-zero when the resolver reports UPLOAD_FAILED
  --supply-chain            Run the supply-chain (dependency) analysis
  --supply-chain-policy P   Supply-chain policy name (implies --supply-chain)
  --supply-chain-offline    Supply-chain analysis without network access
  --supply-chain-cache-only Use only cached package metadata
  --supply-chain-fail-on S  Fail on findings at or above S (INFO, LOW, MEDIUM, HIGH, CRITICAL)
  --supply-chain-format F   Supply-chain report format (default: both)
  --privacy-tier TIER       full (default) | metrics | none. Controls what leaves the tenant.
  --mock-resolver           Serve AI answers from the server-side OpenAI mock (no OpenAI cost;
                            simulated latency and Tier 5 rate limits). Testing only.
  --api-url URL             Server URL for the host-side uploads (VEX, rebuild). The resolver
                            derives its own URL from --client/--env (dev -> <client>.dev.glog.ai,
                            localhost -> http://<client>.localhost:8000), so with --upload the
                            two must agree or the scan is refused.
  --rebuild                 Discover all lockfile dependencies and run the worker for each
  --rebuild-artifact PATH   Optional single package artifact
  --rebuild-manifest PATH   Optional published manifest for single-artifact mode
  --rebuild-package NAME    Package name for single-artifact mode
  --rebuild-version VERSION Package version for single-artifact mode
  --rebuild-ecosystem NAME  npm, pypi, go, cargo, maven or rubygems (single-artifact mode)
  --rebuild-image IMAGE     Rebuild worker image
  --max-packages N          Cap dependencies verified in all-dependency rebuild mode
  --remediate               After the scan, triage the findings again and fix them with the
                            AI remediation image. Default patch mode leaves the tree untouched
                            and writes .glog/glog-ai-remediation.patch
  --remediation-mode MODE   patch (default), branch (commit on glog/remediation/..., never
                            pushed) or local (uncommitted edits). Implies --remediate
  --remediate-branch        Shorthand for --remediation-mode branch
  --remediate-local         Shorthand for --remediation-mode local
  --remediate-dry-run       Triage only: no edits, no patch
  --remediate-min-severity S  Severity floor: LOW (default), MEDIUM, HIGH or CRITICAL
  --remediate-max-findings N  Cap the findings handed to the fix agent, highest severity first
  --require-verified        Accept a fix only when the project's own build/test/lint passed
  --allow-dirty             Let branch/local mode run on a tree with uncommitted changes
'@ | Write-Output
}

function Get-AbsolutePath {
    param([Parameter(Mandatory = $true)][string]$PathValue)

    return (Resolve-Path -LiteralPath $PathValue).Path
}

function Get-RelativePath {
    param(
        [Parameter(Mandatory = $true)][string]$BasePath,
        [Parameter(Mandatory = $true)][string]$TargetPath
    )

    $resolvedBase = Get-AbsolutePath -PathValue $BasePath
    $resolvedTarget = Get-AbsolutePath -PathValue $TargetPath

    $baseWithSlash = $resolvedBase.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    $baseUri = New-Object System.Uri($baseWithSlash)
    $targetUri = New-Object System.Uri($resolvedTarget)
    $relative = $baseUri.MakeRelativeUri($targetUri)

    return [System.Uri]::UnescapeDataString($relative.ToString()).Replace([System.IO.Path]::AltDirectorySeparatorChar, [System.IO.Path]::DirectorySeparatorChar)
}

function Get-HostIdValue {
    param([Parameter(Mandatory = $true)][ValidateSet('uid', 'gid')][string]$Kind)

    $isWindowsHost = $env:OS -eq 'Windows_NT'
    if ($isWindowsHost) {
        return '1000'
    }

    try {
        if ($Kind -eq 'uid') {
            $value = & id -u
        } else {
            $value = & id -g
        }

        if ($LASTEXITCODE -eq 0 -and $value) {
            return ($value | Out-String).Trim()
        }
    } catch {
        # Fall through to default value.
    }

    return '1000'
}

function Persist-ScopedScanArtifacts {
    param(
        [Parameter(Mandatory = $true)][string]$ScanPath,
        [Parameter(Mandatory = $true)][string]$ProjectPath
    )

    if ((Get-AbsolutePath -PathValue $ScanPath) -eq (Get-AbsolutePath -PathValue $ProjectPath)) {
        return
    }

    $scanGlogDir = Join-Path -Path $ScanPath -ChildPath '.glog'
    if (-not (Test-Path -LiteralPath $scanGlogDir -PathType Container)) {
        Write-Output 'No .glog artifacts found in scoped scan directory.'
        return
    }

    $projectGlogDir = Join-Path -Path $ProjectPath -ChildPath '.glog'
    New-Item -ItemType Directory -Path $projectGlogDir -Force | Out-Null

    Get-ChildItem -LiteralPath $scanGlogDir -Force | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $projectGlogDir -Recurse -Force
    }

    Write-Output "Persisted scoped scan artifacts to $projectGlogDir"
}

function Test-ScanArtifacts {
    # Report what a finished scan left in .glog/ and fail the step when an
    # artifact the run promised is missing. Mirrors verify_scan_artifacts()
    # in glog.sh.
    #
    # This one RETURNS a verdict, so its narrative goes to the host stream
    # (Write-Host) and never joins the pipeline: a caller that captured
    # Write-Output would get @('report...', $false), which is truthy whatever
    # the verdict was.
    param(
        [Parameter(Mandatory = $true)][string]$ProjectPath,
        [AllowEmptyString()][string]$SbomOnly = 'false',
        [AllowEmptyString()][string]$WithSbom = 'false',
        [AllowEmptyString()][string]$ResolverUpload = 'false'
    )

    $glogDir = Join-Path -Path $ProjectPath -ChildPath '.glog'
    $missing = $false

    Write-Host "--- Glog artifact summary ($glogDir) ---"
    if (Test-Path -LiteralPath $glogDir -PathType Container) {
        Get-ChildItem -LiteralPath $glogDir -Force | ForEach-Object {
            Write-Host ("  {0,10}  {1}" -f $_.Length, $_.Name)
        }
    } else {
        Write-Host '  (no .glog directory was produced)'
    }

    if ($SbomOnly -ne 'true') {
        $sarif = Join-Path -Path $glogDir -ChildPath 'glog-scan.sarif'
        if ((Test-Path -LiteralPath $sarif) -and ((Get-Item -LiteralPath $sarif).Length -gt 0)) {
            Write-Host "  SARIF: OK ($sarif)"
        } else {
            [Console]::Error.WriteLine('Glog: SARIF results are missing.')
            $missing = $true
        }
    }

    if ($WithSbom -eq 'true') {
        $cdxFiles = @()
        if (Test-Path -LiteralPath $glogDir -PathType Container) {
            $cdxFiles = @(Get-ChildItem -LiteralPath $glogDir -Filter '*.cdx.json' -Force)
        }
        if ($cdxFiles.Count -gt 0) {
            Write-Host "  SBOM: OK ($(($cdxFiles | ForEach-Object { $_.Name }) -join ' '))"
        } else {
            [Console]::Error.WriteLine('Glog: SBOM results are missing.')
            $missing = $true
        }
    }

    if ($ResolverUpload -eq 'true') {
        Write-Host '  Upload: requested (server ingestion is reported by the resolver above)'
    } else {
        Write-Host '  Upload: disabled (pass on-prem-upload=true / --upload to send results to the server)'
    }
    Write-Host '----------------------------------------'

    if ($missing) {
        [Console]::Error.WriteLine('Glog: expected scan artifacts are missing - failing the step.')
        return $false
    }
    return $true
}

function Get-ResolverServerUrl {
    # The resolver (GlogService.buildBaseUrl) ignores GLOG_API_URL and derives
    # the server from CLIENT/ENV. Mirrors resolver_server_url() in glog.sh.
    param([AllowEmptyString()][string]$Client, [AllowEmptyString()][string]$EnvironmentName)

    $c = if ($Client) { $Client } else { 'test' }
    $e = if ($EnvironmentName) { $EnvironmentName.ToLowerInvariant() } else { '' }
    if (-not $e) { return "https://$c.glog.ai" }
    if ($e -eq 'localhost') { return "http://$c.localhost:8000" }
    return "https://$c.$e.glog.ai"
}

function Get-DetectedLanguages {
    param([Parameter(Mandatory = $true)][string]$ProjectDir)

    $found = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $files = Get-ChildItem -LiteralPath $ProjectDir -Recurse -File -Force

    foreach ($file in $files) {
        $relativePath = Get-RelativePath -BasePath $ProjectDir -TargetPath $file.FullName

        # Match bash behavior: max depth 4 and skip any hidden path segment (*/.*).
        $segments = $relativePath -split '[\\/]'
        if ($segments.Count -gt 7) {
            continue
        }

        $isHiddenPath = $false
        # foreach ($segment in $segments) {
        #     if ($segment.StartsWith('.')) {
        #         $isHiddenPath = $true
        #         break
        #     }
        # }
        if ($isHiddenPath) {
            continue
        }

        $extension = $file.Extension.TrimStart('.').ToLowerInvariant()
        switch ($extension) {
            'c'            { [void]$found.Add('cpp') }
            'cpp'          { [void]$found.Add('cpp') }
            'h'            { [void]$found.Add('cpp') }
            'hpp'          { [void]$found.Add('cpp') }
            'java'         { [void]$found.Add('java') }
            'class'        { [void]$found.Add('java') }
            'js'           { [void]$found.Add('javascript') }
            'ts'           { [void]$found.Add('javascript') }
            'jsx'          { [void]$found.Add('javascript') }
            'tsx'          { [void]$found.Add('javascript') }
            'py'           { [void]$found.Add('python') }
            'kt'           { [void]$found.Add('kotlin') }
            'kotlin'       { [void]$found.Add('kotlin') }
            'php'          { [void]$found.Add('php') }
            'rb'           { [void]$found.Add('ruby') }
            'cs'           { [void]$found.Add('csharp') }
            'tf'           { [void]$found.Add('terraform') }
            'cls'          { [void]$found.Add('objectscript') }
            'objectscript' { [void]$found.Add('objectscript') }
            'go'           { [void]$found.Add('go') }
        }
    }

    return @($found)
}

function New-ScopedFilesDir {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string[]]$InputFiles
    )

    $tempDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("glog-scan-{0}" -f [System.Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

    foreach ($file in $InputFiles) {
        $trimmedFile = $file.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmedFile)) {
            continue
        }

        if ([System.IO.Path]::IsPathRooted($trimmedFile)) {
            throw "Invalid file path: $trimmedFile"
        }

        $segments = $trimmedFile -split '[\\/]'
        if ($segments -contains '..') {
            throw "Invalid file path: $trimmedFile"
        }

        $sourcePath = Join-Path -Path $ProjectDir -ChildPath $trimmedFile
        if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
            throw "File not found: $trimmedFile"
        }

        $destinationPath = Join-Path -Path $tempDir -ChildPath $trimmedFile
        $destinationParent = Split-Path -Parent $destinationPath
        if ($destinationParent) {
            New-Item -ItemType Directory -Path $destinationParent -Force | Out-Null
        }

        Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Force
    }

    return $tempDir
}

function Invoke-ScanLang {
    param(
        [Parameter(Mandatory = $true)][string]$Lang,
        [Parameter(Mandatory = $true)][string]$PathToScan,
        [AllowEmptyString()][string]$Ignore = '',
        # Client and token may legitimately be empty (no --client / no
        # GLOG_TOKEN): a Mandatory parameter rejects an empty string, which
        # would fail such a scan before it starts. glog.sh sets no such bar.
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Client,
        # --env is optional too: with no environment the resolver targets the
        # tenant URL, which is what glog.sh falls back to as well.
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$EnvironmentName,
        [Parameter(Mandatory = $true)][string]$Registry,
        [Parameter(Mandatory = $true)][string]$SarifFormatType,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$GlogToken,
        [Parameter(Mandatory = $true)][string]$ResolverUpload,
        [AllowEmptyString()][string]$WithSbom = 'false',
        [AllowEmptyString()][string]$SbomOnly = 'false',
        [AllowEmptyString()][string]$SbomMode = 'stateless',
        [AllowEmptyString()][string]$SclUuid = '',
        [AllowEmptyString()][string]$ForceInventory = 'false',
        [AllowEmptyString()][string]$PrivacyTier = 'full',
        [AllowEmptyString()][string]$ApiUrl = '',
        [AllowEmptyString()][string]$SupplyChainEnabled = 'false',
        [AllowEmptyString()][string]$SupplyChainPolicy = '',
        [AllowEmptyString()][string]$SupplyChainOffline = 'false',
        [AllowEmptyString()][string]$SupplyChainCacheOnly = 'false',
        [AllowEmptyString()][string]$SupplyChainFailOn = '',
        [AllowEmptyString()][string]$SupplyChainFormat = 'both'
    )

    if (-not $imageMap.ContainsKey($Lang)) {
        Write-Output "  (skipping '$Lang': no scanner image mapped - use --sbom / --inventory flags, not --lang)"
        return
    }

    $hostUid = Get-HostIdValue -Kind uid
    $hostGid = Get-HostIdValue -Kind gid
    $resolvedScanPath = Get-AbsolutePath -PathValue $PathToScan
    $isWindowsHost = $env:OS -eq 'Windows_NT'
    $volName = $null
    $scanMount = "${resolvedScanPath}:/app"

    try {
        if ($isWindowsHost) {
            $volName = "glog-src-$([System.Guid]::NewGuid().ToString('N'))"

            & docker volume create $volName
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to create Docker volume '$volName' for language '$Lang'."
            }

            & docker run --rm -v "${volName}:/app" -v "${resolvedScanPath}:/src:ro" alpine sh -c "cp -r /src/. /app/"
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to copy scan sources into Docker volume '$volName' for language '$Lang'."
            }

            $scanMount = "${volName}:/app"
        }

        foreach ($imageName in $imageMap[$Lang]) {
            Write-Output "--> Running scanner: $Registry$imageName"

            $extraArgs = @()
            if ($Lang -eq 'vex') {
                $reach = if ($env:GLOG_VEX_REACHABILITY) { $env:GLOG_VEX_REACHABILITY } else { 'true' }
                $extraArgs += @('-e', 'GLOG_VEX=true', '-e', "GLOG_VEX_REACHABILITY=$reach")
            }
            if ($imageName -like "$(Get-ScanImage 'GLOG_SCAN_IMAGE_SBOM_CDXGEN')*") {
                # SBOM (cdxgen + mvnw) needs network egress to Maven Central / npm registry
                # and a persistent Maven cache to avoid re-downloading plugins each run.
                $homeDir = if ($env:HOME) { $env:HOME } else { $env:USERPROFILE }
                $m2Dir = Join-Path -Path $homeDir -ChildPath '.glog-m2'
                New-Item -ItemType Directory -Path $m2Dir -Force | Out-Null
                $extraArgs += @('--network', 'host')
                $extraArgs += @('-v', "${m2Dir}:/root/.m2")
                $extraArgs += @('-e', 'CDXGEN_TIMEOUT_MS=600000')
                # No FETCH_LICENSE override: the image enables license resolution
                # (Dockerfile.cdxgen) and turning it off leaves every component of
                # the report without a license.
            }

            $dockerArgs = @(
                'run', '--pull', 'always', '--rm'
            ) + $extraArgs + @(
                '-e', "GLOGSERVICE=$GlogToken",
                '-e', "GLOG_TOKEN=$GlogToken",
                '-e', "HOST_UID=$hostUid",
                '-e', "HOST_GID=$hostGid",
                '-e', "SARIF_FORMAT_TYPE=$SarifFormatType",
                '-e', "RESOLVER_UPLOAD=$ResolverUpload",
                '-e', "WITH_SBOM=$WithSbom",
                '-e', "SBOM_ONLY=$SbomOnly",
                '-e', "SBOM_MODE=$SbomMode",
                '-e', "FORCE_INVENTORY=$ForceInventory",
                '-e', "WITH_INVENTORY=$ForceInventory",
                '-e', "SCL_UUID=$SclUuid",
                '-e', "PRIVACY_TIER=$PrivacyTier",
                '-e', "MOCK_RESOLVER=$(if ($env:MOCK_RESOLVER) { $env:MOCK_RESOLVER } else { 'false' })",
                '-e', "SUPPLY_CHAIN_ENABLED=$SupplyChainEnabled",
                '-e', "SUPPLY_CHAIN_POLICY=$SupplyChainPolicy",
                '-e', "SUPPLY_CHAIN_OFFLINE=$SupplyChainOffline",
                '-e', "SUPPLY_CHAIN_CACHE_ONLY=$SupplyChainCacheOnly",
                '-e', "SUPPLY_CHAIN_FAIL_ON=$SupplyChainFailOn",
                '-e', "SUPPLY_CHAIN_FORMAT=$SupplyChainFormat",

                '-e', "IGNORE=$Ignore",
                '-e', "CLIENT=$Client",
                '-e', "ENV=$EnvironmentName",
                '-e', "GLOG_IMAGE=$imageName",
                '-e', "HOST_PROJECT_PATH=$resolvedScanPath",
                '-e', ("GLOG_COMPONENT=" + $(if ($env:GLOG_COMPONENT) { $env:GLOG_COMPONENT } else { Split-Path -Leaf $resolvedScanPath })),
                '-e', ("GLOG_BRANCH=" + $(foreach ($v in @($env:GLOG_BRANCH, $env:GITHUB_HEAD_REF, $env:GITHUB_REF_NAME, $env:BUILD_SOURCEBRANCHNAME, $env:CI_COMMIT_REF_NAME, $env:BRANCH_NAME)) { if ($v) { $v; break } })),
                '-e', ("GLOG_TRIAGE_TIMEOUT_MINUTES=" + $(if ($env:GLOG_TRIAGE_TIMEOUT_MINUTES) { $env:GLOG_TRIAGE_TIMEOUT_MINUTES } else { '1440' })),
                '-e', ("GLOG_SOCKET_TIMEOUT_MS=" + $(if ($env:GLOG_SOCKET_TIMEOUT_MS) { $env:GLOG_SOCKET_TIMEOUT_MS } else { '1800000' })),
                '-e', ("GLOG_CONNECT_TIMEOUT_MS=" + $(if ($env:GLOG_CONNECT_TIMEOUT_MS) { $env:GLOG_CONNECT_TIMEOUT_MS } else { '60000' })),
                '-e', ("GLOG_CONNECTION_REQUEST_TIMEOUT_MS=" + $(if ($env:GLOG_CONNECTION_REQUEST_TIMEOUT_MS) { $env:GLOG_CONNECTION_REQUEST_TIMEOUT_MS } else { '60000' })),
                '-e', ("GLOG_PROFILE=" + $(if ($env:GLOG_PROFILE) { $env:GLOG_PROFILE } else { '' })),
                '-e', ("GLOG_REMEDIATION_BULK=" + $(if ($env:GLOG_REMEDIATION_BULK) { $env:GLOG_REMEDIATION_BULK } else { '1' })),
                '-e', ("GLOG_REMEDIATION_BATCH=" + $(if ($env:GLOG_REMEDIATION_BATCH) { $env:GLOG_REMEDIATION_BATCH } else { '20' })),
                '-e', ("GLOG_REMEDIATION_BATCH_LINGER_MS=" + $(if ($env:GLOG_REMEDIATION_BATCH_LINGER_MS) { $env:GLOG_REMEDIATION_BATCH_LINGER_MS } else { '750' })),
                '-e', ("GLOG_REMEDIATION_INFLIGHT_BATCHES=" + $(if ($env:GLOG_REMEDIATION_INFLIGHT_BATCHES) { $env:GLOG_REMEDIATION_INFLIGHT_BATCHES } else { '8' })),
                '-e', ("GLOG_FP_FROM_VALIDATE=" + $(if ($env:GLOG_FP_FROM_VALIDATE) { $env:GLOG_FP_FROM_VALIDATE } else { 'true' })),
                '-e', ("GLOG_DEDUP_STATEMENT_SCOPE_ELEMENT_SPLIT=" + $(if ($env:GLOG_DEDUP_STATEMENT_SCOPE_ELEMENT_SPLIT) { $env:GLOG_DEDUP_STATEMENT_SCOPE_ELEMENT_SPLIT } else { 'false' }))

            )

            if ($ApiUrl) {
                $dockerArgs += @('-e', "GLOG_API_URL=$ApiUrl")
            }




            if ($env:GLOG_DEPSCAN_VDB_VOLUME) {
                $dockerArgs += @('-e', "GLOG_DEPSCAN_VDB_VOLUME=$($env:GLOG_DEPSCAN_VDB_VOLUME)")
                $vdbMountTarget = if ($env:VDB_HOME) { $env:VDB_HOME } else { '/vdb' }
                $dockerArgs += @('-v', "$($env:GLOG_DEPSCAN_VDB_VOLUME):$vdbMountTarget")
            }
            if ($env:VDB_APP_ONLY) {
                $dockerArgs += @('-e', "VDB_APP_ONLY=$($env:VDB_APP_ONLY)")
            }
            if ($env:VDB_HOME) {
                $dockerArgs += @('-e', "VDB_HOME=$($env:VDB_HOME)")
            }
            if ($env:VDB_DATABASE_URL) {
                $dockerArgs += @('-e', "VDB_DATABASE_URL=$($env:VDB_DATABASE_URL)")
            }
            if ($env:VDB_AGE_HOURS) {
                $dockerArgs += @('-e', "VDB_AGE_HOURS=$($env:VDB_AGE_HOURS)")
            }

            $dockerArgs += @(
                '-v', $scanMount,
                "$Registry$imageName"
            )

            & docker @dockerArgs
            if ($LASTEXITCODE -ne 0) {
                throw "Scanner failed for language '$Lang' with image '$imageName'."
            }
        }

        if ($isWindowsHost) {
            & docker run --rm -v "${volName}:/app" -v "${resolvedScanPath}/.glog:/out" alpine sh -c "if [ -d /app/.glog ]; then cp -r /app/.glog/. /out/; fi"
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to copy scan results from Docker volume '$volName' for language '$Lang'."
            }
        }
    }
    finally {
        if ($volName) {
            & docker volume rm $volName | Out-Null
        }
    }
}

$commands = [System.Collections.Generic.List[string]]::new()
$languages = [System.Collections.Generic.List[string]]::new()
$ignore = ''
$client = ''
$environmentName = ''
$registry = 'ghcr.io/glogai/'
$projectPath = (Get-Location).Path
# AI remediation (post-resolver triage + fix). Mirrors run_remediation() in
# glog.sh: the glog-tools remediation image reads .glog/glog-scan.sarif and, in
# the default patch mode, writes .glog/glog-ai-remediation.patch without
# touching the tree. With a scan token and no provider key the model calls go
# through the Glog server relay; otherwise GLOG_LLM_BASE_URL / GLOG_LLM_API_KEY
# name an OpenAI-compatible endpoint. Never fails the scan.
function Invoke-GlogRemediation {
    param([string]$ProjectPath, [string]$Registry, [AllowEmptyString()][string]$GlogToken,
          [AllowEmptyString()][string]$ApiUrl, [AllowEmptyString()][string]$Client,
          [AllowEmptyString()][string]$EnvironmentName, [string]$Mode, [AllowEmptyString()][string]$Apply,
          [AllowEmptyString()][string]$RequireVerified, [AllowEmptyString()][string]$AllowDirty,
          [AllowEmptyString()][string]$MinSeverity, [AllowEmptyString()][string]$MaxFindings)

    $resolvedPath = Get-AbsolutePath -PathValue $ProjectPath
    $imageName = Get-ScanImage 'GLOG_SCAN_IMAGE_REMEDIATION_REMEDIATION'
    if (-not (Test-Path -LiteralPath (Join-Path $resolvedPath '.glog/glog-scan.sarif'))) {
        [Console]::Error.WriteLine("WARNING: remediation skipped, $resolvedPath/.glog/glog-scan.sarif was not produced.")
        return
    }
    # On Windows the tree reaches the container through a copied volume, so
    # only the .glog outputs come back: branch and local edits would be lost.
    if ($env:OS -eq 'Windows_NT' -and $Mode -ne 'patch') {
        [Console]::Error.WriteLine("WARNING: remediation mode '$Mode' needs a bind mount; on Windows use patch mode.")
        return
    }

    $transport = $env:GLOG_LLM_TRANSPORT
    if (-not $transport) {
        $transport = if ($GlogToken -and -not $env:GLOG_LLM_API_KEY) { 'server' } else { 'direct' }
    }
    $dockerArgs = @('run', '--rm')
    if ($env:GLOG_IMAGE_REMEDIATION) { $runImage = $env:GLOG_IMAGE_REMEDIATION }
    else { $runImage = "$Registry$imageName"; $dockerArgs += @('--pull', 'always') }

    switch ($transport) {
        'server' {
            if (-not $GlogToken) {
                [Console]::Error.WriteLine('WARNING: remediation skipped, the server transport needs a scan token (--glogtoken).')
                return
            }
            $api = if ($ApiUrl) { $ApiUrl } else { "$(Get-ResolverServerUrl -Client $Client -EnvironmentName $EnvironmentName)/api" }
            $relay = if ($env:GLOG_LLM_SERVER_URL) { $env:GLOG_LLM_SERVER_URL } else { $api }
            $relayHost = ($relay -replace '^[a-zA-Z]+://', '') -replace '[:/].*$', ''
            if ($relayHost -like '*.localhost' -or $relayHost -eq 'localhost' -or $relayHost -eq '127.0.0.1') {
                $dockerArgs += @('--network', 'host', '-e', "GLOG_REMEDIATION_HOST_NETWORK=true")
                if ($relayHost -ne '127.0.0.1') { $dockerArgs += @('--add-host', "${relayHost}:127.0.0.1") }
            }
            $dockerArgs += @('-e', "GLOG_LLM_TRANSPORT=server", '-e', "GLOG_API_URL=$api")
            if ($env:GLOG_LLM_SERVER_URL) { $dockerArgs += @('-e', "GLOG_LLM_SERVER_URL=$($env:GLOG_LLM_SERVER_URL)") }
        }
        'direct' {
            if (-not $env:GLOG_LLM_API_KEY -or -not $env:GLOG_LLM_BASE_URL) {
                [Console]::Error.WriteLine('WARNING: remediation skipped, it needs a scan token (server relay) or GLOG_LLM_BASE_URL and GLOG_LLM_API_KEY.')
                return
            }
            # Bare -e: docker copies the key from this process's environment.
            $dockerArgs += @('-e', "GLOG_LLM_TRANSPORT=direct", '-e', 'GLOG_LLM_API_KEY', '-e', "GLOG_LLM_BASE_URL=$($env:GLOG_LLM_BASE_URL)")
        }
        default {
            [Console]::Error.WriteLine("WARNING: remediation skipped, transport '$transport' is not supported here (server or direct).")
            return
        }
    }
    if ($env:GLOG_LLM_MODEL) { $dockerArgs += @('-e', "GLOG_LLM_MODEL=$($env:GLOG_LLM_MODEL)") }

    $applyLabel = if ($Apply) { $Apply } else { 'true' }
    Write-Output "AI remediation: mode=$Mode transport=$transport apply=$applyLabel"
    $dockerArgs += @(
        '-e', "GLOGSERVICE=$GlogToken",
        '-e', "GLOG_TOKEN=$GlogToken",
        '-e', "HOST_UID=$(Get-HostIdValue -Kind uid)",
        '-e', "HOST_GID=$(Get-HostIdValue -Kind gid)",
        '-e', "GLOG_IMAGE=$imageName",
        '-e', "HOST_PROJECT_PATH=$resolvedPath",
        '-e', "GLOG_REMEDIATION_MODE=$Mode",
        '-e', "GLOG_REMEDIATION_APPLY=$Apply",
        '-e', "GLOG_REMEDIATION_REQUIRE_VERIFIED=$RequireVerified",
        '-e', "GLOG_REMEDIATION_ALLOW_DIRTY=$AllowDirty",
        '-e', "GLOG_REMEDIATION_MIN_SEVERITY=$MinSeverity",
        '-e', "GLOG_REMEDIATION_MAX_FINDINGS=$MaxFindings",
        '-e', ("GLOG_REMEDIATION_CHUNK_SIZE=" + $(if ($env:GLOG_REMEDIATION_CHUNK_SIZE) { $env:GLOG_REMEDIATION_CHUNK_SIZE } else { '' })),
        '-e', ("GLOG_REMEDIATION_SALVAGE_PARTIAL=" + $(if ($env:GLOG_REMEDIATION_SALVAGE_PARTIAL) { $env:GLOG_REMEDIATION_SALVAGE_PARTIAL } else { '' })),
        '-e', ("GLOG_REMEDIATION_RETRY_ON_REVERT=" + $(if ($env:GLOG_REMEDIATION_RETRY_ON_REVERT) { $env:GLOG_REMEDIATION_RETRY_ON_REVERT } else { '' }))
    )

    $volName = $null
    try {
        $mount = "${resolvedPath}:/app"
        if ($env:OS -eq 'Windows_NT') {
            $volName = "glog-src-$([System.Guid]::NewGuid().ToString('N'))"
            & docker volume create $volName | Out-Null
            & docker run --rm -v "${volName}:/app" -v "${resolvedPath}:/src:ro" alpine sh -c "cp -r /src/. /app/"
            $mount = "${volName}:/app"
        }
        $dockerArgs += @('-v', $mount, $runImage)
        & docker @dockerArgs
        $remediationExit = $LASTEXITCODE
        if ($volName) {
            & docker run --rm -v "${volName}:/app" -v "${resolvedPath}/.glog:/out" alpine sh -c "cp -r /app/.glog/. /out/"
        }
        if ($remediationExit -ne 0) {
            [Console]::Error.WriteLine("WARNING: AI remediation failed; see $resolvedPath/.glog/glog-ai-remediation-report.md. Scan results are unaffected.")
            return
        }
    }
    finally {
        if ($volName) { & docker volume rm $volName | Out-Null }
    }
    $patch = Join-Path $resolvedPath '.glog/glog-ai-remediation.patch'
    if ((Test-Path -LiteralPath $patch) -and (Get-Item -LiteralPath $patch).Length -gt 0) {
        Write-Output "AI remediation patch: $patch (review, then git apply)"
    }
    Write-Output "AI remediation report: $resolvedPath/.glog/glog-ai-remediation-report.md"
}

function Invoke-GlogCbom {
    param([string]$ScanPath, [string]$Registry)
    $image = "${Registry}$(Get-ScanImage 'GLOG_SCAN_IMAGE_SBOM_CDXGEN')"
    New-Item -ItemType Directory -Force -Path (Join-Path $ScanPath '.glog') | Out-Null
    Write-Output 'Generating CBOM (cryptographic inventory)'
    $script = 'rm -f /app/.glog/cbom.gen.json; cdxgen --include-crypto --spec-version 1.6 -o /app/.glog/cbom.gen.json /app || echo "WARNING: generator crypto pass failed; detector only."; python3 /usr/local/glog/cbom_detector.py --src /app --merge /app/.glog/cbom.gen.json --out /app/.glog/cbom.cdx.json; rm -f /app/.glog/cbom.gen.json'
    # No FETCH_LICENSE override: the image enables license resolution
    # (Dockerfile.cdxgen) and turning it off leaves every CBOM component without
    # a license, the same fault the SBOM pass was fixed for.
    & docker run --rm --pull always -v "${ScanPath}:/app" --entrypoint sh -e CDXGEN_TIMEOUT_MS=600000 $image -c $script
    if ($LASTEXITCODE -ne 0) { Write-Output 'WARNING: CBOM generation failed; continuing.' }
}

function Send-GlogCbom {
    param([string]$ScanPath, [string]$ResolverUpload, [string]$PrivacyTier, [string]$ApiUrl,
          [string]$Client, [string]$EnvironmentName, [string]$GlogToken, [string]$SclUuid)
    $cbomFile = Join-Path -Path $ScanPath -ChildPath '.glog/cbom.cdx.json'
    if (-not (Test-Path -LiteralPath $cbomFile)) { Write-Output "WARNING: CBOM requested but $cbomFile was not produced."; return }
    if ($ResolverUpload -ne 'true' -or $PrivacyTier -eq 'none') { Write-Output "CBOM kept locally: $cbomFile"; return }
    $api = $ApiUrl
    if (-not $api -and $Client) {
        $api = if ($EnvironmentName -match '^(dev|development)$') { "https://$Client.dev.glog.ai" } else { "https://$Client.glog.ai" }
    }
    if (-not $api -or -not $GlogToken) { Write-Output 'WARNING: CBOM not uploaded (API URL / token missing).'; return }
    $serial = ''
    $sbomFile = Join-Path -Path $ScanPath -ChildPath '.glog/sbom.cdx.json'
    if (Test-Path -LiteralPath $sbomFile) {
        try { $serial = (Get-Content -LiteralPath $sbomFile -Raw | ConvertFrom-Json).serialNumber } catch { $serial = '' }
    }
    $profile = if ($env:GLOG_CBOM_PROFILE) { $env:GLOG_CBOM_PROFILE } else { 'baseline' }
    try {
        $out = & curl.exe -sS -X POST -H "Authorization: Token $GlogToken" `
            -F "cbom_file=@$cbomFile;type=application/json" -F "sbom_serial=$serial" -F "scl_uuid=$SclUuid" -F "profile=$profile" `
            "$($api.TrimEnd('/'))/api/sca/resolver/cbom/"
        Write-Output "CBOM upload response: $out"
    } catch {
        Write-Output "WARNING: CBOM upload failed: $_"
    }
}

function Send-GlogVex {
    param([string]$ScanPath, [string]$ResolverUpload, [string]$PrivacyTier, [string]$ApiUrl,
          [string]$Client, [string]$EnvironmentName, [string]$GlogToken, [string]$SclUuid)
    $vexFile = Join-Path -Path $ScanPath -ChildPath '.glog/vex.cdx.json'
    if (-not (Test-Path -LiteralPath $vexFile)) { Write-Output "WARNING: VEX requested but $vexFile was not produced."; return }
    if ($ResolverUpload -ne 'true' -or $PrivacyTier -eq 'none') { Write-Output "VEX kept locally: $vexFile"; return }
    $api = $ApiUrl
    if (-not $api -and $Client) {
        $api = if ($EnvironmentName -match '^(dev|development)$') { "https://$Client.dev.glog.ai" } else { "https://$Client.glog.ai" }
    }
    if (-not $api -or -not $GlogToken) { Write-Output 'WARNING: VEX not uploaded (API URL / token missing).'; return }
    $serial = ''
    $sbomFile = Join-Path -Path $ScanPath -ChildPath '.glog/sbom.cdx.json'
    if (Test-Path -LiteralPath $sbomFile) {
        try { $serial = (Get-Content -LiteralPath $sbomFile -Raw | ConvertFrom-Json).serialNumber } catch { $serial = '' }
    }
    try {
        $out = & curl.exe -sS -X POST -H "Authorization: Token $GlogToken" `
            -F "vex_file=@$vexFile;type=application/json" -F "sbom_serial=$serial" -F "scl_uuid=$SclUuid" `
            "$($api.TrimEnd('/'))/api/sca/resolver/vex/"
        Write-Output "VEX upload response: $out"
    } catch {
        Write-Output "WARNING: VEX upload failed: $_"
    }
}

function Get-LogHead {
    param([string]$File, [int]$Max = 300)
    if (-not (Test-Path -LiteralPath $File)) { return '' }
    try {
        $raw = Get-Content -LiteralPath $File -Raw
        if (-not $raw) { return '' }
        if ($raw.Length -le $Max) { return $raw }
        return $raw.Substring(0, $Max)
    } catch { return '' }
}

function Test-GlogSbomQuality {
    # Optional CI gate: score the SBOM on the Glog server (nothing is stored)
    # and fail the run when the grade is below $MinGrade (A-F). Mirrors
    # sbom_quality_gate() in glog.sh - same endpoint, same response shape.
    #
    # This one RETURNS a verdict, so its narrative goes to the host stream
    # (Write-Host) and never joins the pipeline: a caller that captured
    # Write-Output would get @('SBOM quality: ...', $false), which is truthy
    # whether or not the gate failed.
    param([string]$ScanPath, [string]$MinGrade, [string]$ApiUrl, [string]$Client,
          [string]$EnvironmentName, [string]$GlogToken)
    if (-not $MinGrade) { return $false }
    $sbomFile = Join-Path -Path $ScanPath -ChildPath '.glog/sbom.cdx.json'
    if (-not (Test-Path -LiteralPath $sbomFile)) {
        Write-Host "WARNING: sbom-min-grade=$MinGrade set but $sbomFile was not produced; gate skipped."
        return $false
    }
    $api = $ApiUrl
    if (-not $api -and $Client) {
        $api = if ($EnvironmentName -match '^(dev|development)$') { "https://$Client.dev.glog.ai" } else { "https://$Client.glog.ai" }
    }
    if (-not $api -or -not $GlogToken) {
        Write-Host 'WARNING: SBOM quality gate skipped (API URL / token missing).'
        return $false
    }
    $outFile = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath 'glog-sbom-quality.json'
    if (Test-Path -LiteralPath $outFile) { Remove-Item -LiteralPath $outFile -Force }
    $code = '000'
    try {
        $code = ((& curl.exe -sS -o $outFile -w '%{http_code}' -X POST `
            -H "Authorization: Token $GlogToken" `
            -F "sbom_file=@$sbomFile;type=application/json" `
            -F "min_grade=$MinGrade" `
            "$($api.TrimEnd('/'))/api/sca/resolver/sbom-quality/") -join '')
    } catch {
        $code = '000'
    }
    if ($code -ne '200') {
        Write-Host "WARNING: SBOM quality gate could not run (HTTP $code): $(Get-LogHead -File $outFile)"
        return $false
    }
    $resp = $null
    try { $resp = Get-Content -LiteralPath $outFile -Raw | ConvertFrom-Json } catch { $resp = $null }
    if (-not $resp) {
        Write-Host 'WARNING: SBOM quality gate could not read the server response; gate skipped.'
        return $false
    }
    $grade = if ($resp.PSObject.Properties['grade']) { $resp.grade } else { '?' }
    $score = if ($resp.PSObject.Properties['score']) { $resp.score } else { '?' }
    # StrictMode: never touch a property that may be absent on the parsed JSON.
    # The existence guard wraps the *value* ($resp.categories) -- indexing
    # $resp.PSObject.Properties would hand back the member descriptor instead of
    # the array, and every $c would then read as an empty object.
    $categories = if ($resp.PSObject.Properties['categories']) { @($resp.categories) } else { @() }
    foreach ($c in $categories) {
        if ($c -and $c.PSObject.Properties['applicable'] -and $c.applicable) {
            $cLabel = if ($c.PSObject.Properties['label']) { $c.label } else { '?' }
            $cScore = if ($c.PSObject.Properties['score']) { $c.score } else { '?' }
            $cDetail = if ($c.PSObject.Properties['detail']) { $c.detail } else { '' }
            [Console]::Error.WriteLine("  ${cLabel}: $cScore - $cDetail")
        }
    }
    $caps = if ($resp.PSObject.Properties['caps']) { @($resp.caps) } else { @() }
    foreach ($c in $caps) {
        if ($c) {
            $capGrade = if ($c.PSObject.Properties['max_grade']) { $c.max_grade } else { '?' }
            $capReason = if ($c.PSObject.Properties['reason']) { $c.reason } else { '' }
            [Console]::Error.WriteLine("  cap ${capGrade}: $capReason")
        }
    }
    Write-Host "SBOM quality: grade $grade (score $score), required $MinGrade or better."
    if ($resp.PSObject.Properties['gate'] -and $resp.gate -eq 'fail') {
        [Console]::Error.WriteLine("ERROR: SBOM quality grade $grade is below sbom-min-grade=$MinGrade.")
        return $true
    }
    return $false
}

$glogToken = if ($env:GLOG_TOKEN) { $env:GLOG_TOKEN } else { '' }
$sarifFormatType = if ($env:SARIF_FORMAT_TYPE) { $env:SARIF_FORMAT_TYPE } else { 'GITHUB' }
$resolverUpload = 'false'
$files = [System.Collections.Generic.List[string]]::new()
$tempScanDir = $null
$withSbom = 'false'
$sbomOnly = 'false'
$withVex = 'false'
$withCbom = 'false'
$sclUuid = ''
$forceInventory = $false
$privacyTier = if ($env:PRIVACY_TIER) { $env:PRIVACY_TIER } else { 'full' }
$apiUrl = if ($env:GLOG_API_URL) { $env:GLOG_API_URL } else { '' }
$serverSarifFormatType = if ($env:SERVER_SARIF_FORMAT_TYPE) { $env:SERVER_SARIF_FORMAT_TYPE } else { '' }
$sbomMinGrade = if ($env:GLOG_SBOM_MIN_GRADE) { $env:GLOG_SBOM_MIN_GRADE } else { '' }
$failOnUploadError = if ($env:FAIL_ON_UPLOAD_ERROR) { $env:FAIL_ON_UPLOAD_ERROR } else { 'false' }
# Sticky per-run verdicts, read after the scan to pick the exit code.
$sbomGateFailed = $false
$uploadFailed = $false
# Touched when a scan starts; .glog/glog-scan.log is trusted only if newer.
$scanStartStamp = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "glog-scan-start-$([System.Guid]::NewGuid().ToString('N'))"
$supplyChainEnabled = if ($env:SUPPLY_CHAIN_ENABLED) { $env:SUPPLY_CHAIN_ENABLED } else { 'false' }
$supplyChainPolicy = if ($env:SUPPLY_CHAIN_POLICY) { $env:SUPPLY_CHAIN_POLICY } else { '' }
$supplyChainOffline = if ($env:SUPPLY_CHAIN_OFFLINE) { $env:SUPPLY_CHAIN_OFFLINE } else { 'false' }
$supplyChainCacheOnly = if ($env:SUPPLY_CHAIN_CACHE_ONLY) { $env:SUPPLY_CHAIN_CACHE_ONLY } else { 'false' }
$supplyChainFailOn = if ($env:SUPPLY_CHAIN_FAIL_ON) { $env:SUPPLY_CHAIN_FAIL_ON } else { '' }
$supplyChainFormat = if ($env:SUPPLY_CHAIN_FORMAT) { $env:SUPPLY_CHAIN_FORMAT } else { 'both' }
$rebuild = if ($env:REBUILD) { $env:REBUILD } else { 'false' }
$rebuildArtifact = if ($env:REBUILD_ARTIFACT) { $env:REBUILD_ARTIFACT } else { '' }
$rebuildManifest = if ($env:REBUILD_MANIFEST) { $env:REBUILD_MANIFEST } else { '' }
$rebuildPackage = if ($env:REBUILD_PACKAGE) { $env:REBUILD_PACKAGE } else { '' }
$rebuildVersion = if ($env:REBUILD_VERSION) { $env:REBUILD_VERSION } else { '' }
$rebuildEcosystem = if ($env:REBUILD_ECOSYSTEM) { $env:REBUILD_ECOSYSTEM } else { '' }
$remediate = 'false'
$remediationMode = if ($env:GLOG_REMEDIATION_MODE) { $env:GLOG_REMEDIATION_MODE } else { 'patch' }
$remediationApply = if ($env:GLOG_REMEDIATION_APPLY) { $env:GLOG_REMEDIATION_APPLY } else { '' }
$remediationRequireVerified = if ($env:GLOG_REMEDIATION_REQUIRE_VERIFIED) { $env:GLOG_REMEDIATION_REQUIRE_VERIFIED } else { '' }
$remediationAllowDirty = if ($env:GLOG_REMEDIATION_ALLOW_DIRTY) { $env:GLOG_REMEDIATION_ALLOW_DIRTY } else { '' }
$remediationMinSeverity = if ($env:GLOG_REMEDIATION_MIN_SEVERITY) { $env:GLOG_REMEDIATION_MIN_SEVERITY } else { '' }
$remediationMaxFindings = if ($env:GLOG_REMEDIATION_MAX_FINDINGS) { $env:GLOG_REMEDIATION_MAX_FINDINGS } else { '' }
$rebuildImage = if ($env:REBUILD_IMAGE) { $env:REBUILD_IMAGE } else { "ghcr.io/glogai/$(Get-ScanImage 'GLOG_SCAN_IMAGE_REBUILD_REBUILD')" }
# Bounded all-dependency mode: every package is downloaded and hashed, so an
# unbounded run would make the scan far too slow on large lockfiles.
$rebuildMaxPackages = if ($env:REBUILD_MAX_PACKAGES) { $env:REBUILD_MAX_PACKAGES } else { '' }

$scriptArgs = $args
$index = 0

while ($index -lt $scriptArgs.Count) {
    $arg = $scriptArgs[$index]

    switch ($arg) {
        'clean' {
            [void]$commands.Add('clean')
            $index++
            continue
        }
        'scan' {
            [void]$commands.Add('scan')
            $index++
            continue
        }
        'remediate' {
            [void]$commands.Add('remediate')
            $index++
            continue
        }
        '--path' {
            if ($index + 1 -ge $scriptArgs.Count) { throw 'Missing value for --path' }
            $projectPath = $scriptArgs[$index + 1]
            $index += 2
            continue
        }
        '--files' {
            if ($index + 1 -ge $scriptArgs.Count) { throw 'Missing value for --files' }
            foreach ($item in ($scriptArgs[$index + 1] -split ',')) {
                [void]$files.Add($item)
            }
            $index += 2
            continue
        }
        '--lang' {
            if ($index + 1 -ge $scriptArgs.Count) { throw 'Missing value for --lang' }
            foreach ($item in ($scriptArgs[$index + 1] -split ',')) {
                $trim = $item.Trim()
                switch ($trim) {
                    'sbom'      { $withSbom = 'true' }
                    'inventory' { $forceInventory = $true }
                    default     { if ($trim) { [void]$languages.Add($trim) } }
                }
            }
            $index += 2
            continue
        }
        '--client' {
            if ($index + 1 -ge $scriptArgs.Count) { throw 'Missing value for --client' }
            $client = $scriptArgs[$index + 1]
            $index += 2
            continue
        }
        '--env' {
            if ($index + 1 -ge $scriptArgs.Count) { throw 'Missing value for --env' }
            $environmentName = $scriptArgs[$index + 1]
            $index += 2
            continue
        }
        '--glogtoken' {
            if ($index + 1 -ge $scriptArgs.Count) { throw 'Missing value for --glogtoken' }
            $glogToken = $scriptArgs[$index + 1]
            $index += 2
            continue
        }
        '--ignore' {
            if ($index + 1 -ge $scriptArgs.Count) { throw 'Missing value for --ignore' }
            $ignore = $scriptArgs[$index + 1]
            $index += 2
            continue
        }
        '--registry' {
            if ($index + 1 -ge $scriptArgs.Count) { throw 'Missing value for --registry' }
            $registry = $scriptArgs[$index + 1]
            $index += 2
            continue
        }
        '--sarif-format-type' {
            if ($index + 1 -ge $scriptArgs.Count) { throw 'Missing value for --sarif-format-type' }
            $sarifFormatType = $scriptArgs[$index + 1]
            $index += 2
            continue
        }
        '--server-sarif-format-type' {
            if ($index + 1 -ge $scriptArgs.Count) { throw 'Missing value for --server-sarif-format-type' }
            $serverSarifFormatType = $scriptArgs[$index + 1]
            $index += 2
            continue
        }
        '-u' {
            $resolverUpload = 'true'
            $index++
            continue
        }
        '--upload' {
            $resolverUpload = 'true'
            $index++
            continue
        }
        '--inventory' {
            $forceInventory = $true
            $index++
            continue
        }
        '--sbom' {
            $withSbom = 'true'
            $index++
            continue
        }
        '--cbom' {
            $withCbom = 'true'
            $index++
            continue
        }
        '--vex' {
            $withSbom = 'true'
            $withVex = 'true'
            $index++
            continue
        }
        '--sbom-only' {
            $withSbom = 'true'
            $sbomOnly = 'true'
            $index++
            continue
        }
        '--sbom-min-grade' {
            if ($index + 1 -ge $scriptArgs.Count) { throw 'Missing value for --sbom-min-grade' }
            $sbomMinGrade = $scriptArgs[$index + 1]
            $withSbom = 'true'
            $index += 2
            continue
        }
        '--scl-uuid' {
            if ($index + 1 -ge $scriptArgs.Count) { throw 'Missing value for --scl-uuid' }
            $sclUuid = $scriptArgs[$index + 1]
            $index += 2
            continue
        }
        '--privacy-tier' {
            if ($index + 1 -ge $scriptArgs.Count) { throw 'Missing value for --privacy-tier' }
            $privacyTier = $scriptArgs[$index + 1]
            $index += 2
            continue
        }
        '--mock-resolver' {
            $env:MOCK_RESOLVER = 'true'
            Write-Output 'WARNING: --mock-resolver is ON - AI answers come from the offline mock (no OpenAI cost). Results are NOT real remediations.'
            $index += 1
            continue
        }
        '--api-url' {
            if ($index + 1 -ge $scriptArgs.Count) { throw 'Missing value for --api-url' }
            $apiUrl = $scriptArgs[$index + 1]
            $index += 2
            continue
        }
        '--fail-on-upload-error' {
            $failOnUploadError = 'true'
            $index++
            continue
        }
        '--supply-chain' {
            $supplyChainEnabled = 'true'
            $index++
            continue
        }
        '--supply-chain-policy' {
            if ($index + 1 -ge $scriptArgs.Count) { throw 'Missing value for --supply-chain-policy' }
            $supplyChainPolicy = $scriptArgs[$index + 1]
            $supplyChainEnabled = 'true'
            $index += 2
            continue
        }
        '--supply-chain-offline' {
            $supplyChainOffline = 'true'
            $supplyChainEnabled = 'true'
            $index++
            continue
        }
        '--supply-chain-cache-only' {
            $supplyChainCacheOnly = 'true'
            $supplyChainEnabled = 'true'
            $index++
            continue
        }
        '--supply-chain-fail-on' {
            if ($index + 1 -ge $scriptArgs.Count) { throw 'Missing value for --supply-chain-fail-on' }
            $supplyChainFailOn = $scriptArgs[$index + 1]
            $supplyChainEnabled = 'true'
            $index += 2
            continue
        }
        '--supply-chain-format' {
            if ($index + 1 -ge $scriptArgs.Count) { throw 'Missing value for --supply-chain-format' }
            $supplyChainFormat = $scriptArgs[$index + 1]
            $supplyChainEnabled = 'true'
            $index += 2
            continue
        }
        '--rebuild' {
            $rebuild = 'true'
            $index++
            continue
        }
        '--rebuild-artifact' {
            if ($index + 1 -ge $scriptArgs.Count) { throw 'Missing value for --rebuild-artifact' }
            $rebuildArtifact = $scriptArgs[$index + 1]
            $index += 2
            continue
        }
        '--rebuild-manifest' {
            if ($index + 1 -ge $scriptArgs.Count) { throw 'Missing value for --rebuild-manifest' }
            $rebuildManifest = $scriptArgs[$index + 1]
            $index += 2
            continue
        }
        '--rebuild-package' {
            if ($index + 1 -ge $scriptArgs.Count) { throw 'Missing value for --rebuild-package' }
            $rebuildPackage = $scriptArgs[$index + 1]
            $index += 2
            continue
        }
        '--rebuild-version' {
            if ($index + 1 -ge $scriptArgs.Count) { throw 'Missing value for --rebuild-version' }
            $rebuildVersion = $scriptArgs[$index + 1]
            $index += 2
            continue
        }
        '--rebuild-ecosystem' {
            if ($index + 1 -ge $scriptArgs.Count) { throw 'Missing value for --rebuild-ecosystem' }
            $rebuildEcosystem = $scriptArgs[$index + 1]
            $index += 2
            continue
        }
        '--rebuild-image' {
            if ($index + 1 -ge $scriptArgs.Count) { throw 'Missing value for --rebuild-image' }
            $rebuildImage = $scriptArgs[$index + 1]
            $index += 2
            continue
        }
        '--remediate' {
            $remediate = 'true'
            $index++
            continue
        }
        '--remediation-mode' {
            if ($index + 1 -ge $scriptArgs.Count) { throw 'Missing value for --remediation-mode' }
            $remediationMode = $scriptArgs[$index + 1]
            $remediate = 'true'
            $index += 2
            continue
        }
        '--remediate-branch' {
            $remediationMode = 'branch'
            $remediate = 'true'
            $index++
            continue
        }
        '--remediate-local' {
            $remediationMode = 'local'
            $remediate = 'true'
            $index++
            continue
        }
        '--remediate-dry-run' {
            $remediationApply = 'false'
            $remediate = 'true'
            $index++
            continue
        }
        '--remediate-min-severity' {
            if ($index + 1 -ge $scriptArgs.Count) { throw 'Missing value for --remediate-min-severity' }
            $remediationMinSeverity = $scriptArgs[$index + 1]
            $remediate = 'true'
            $index += 2
            continue
        }
        '--remediate-max-findings' {
            if ($index + 1 -ge $scriptArgs.Count) { throw 'Missing value for --remediate-max-findings' }
            $remediationMaxFindings = $scriptArgs[$index + 1]
            $remediate = 'true'
            $index += 2
            continue
        }
        '--require-verified' {
            $remediationRequireVerified = 'true'
            $index++
            continue
        }
        '--allow-dirty' {
            $remediationAllowDirty = 'true'
            $index++
            continue
        }
        '--max-packages' {
            if ($index + 1 -ge $scriptArgs.Count) { throw 'Missing value for --max-packages' }
            $rebuildMaxPackages = $scriptArgs[$index + 1]
            $index += 2
            continue
        }
        '--rebuild-max-packages' {
            if ($index + 1 -ge $scriptArgs.Count) { throw 'Missing value for --rebuild-max-packages' }
            $rebuildMaxPackages = $scriptArgs[$index + 1]
            $index += 2
            continue
        }
        '-h' {
            Show-Usage
            exit 0
        }
        '--help' {
            Show-Usage
            exit 0
        }
        default {
            Write-Error "Unknown option: $arg"
            Show-Usage
            exit 1
        }
    }
}

if ($commands.Count -eq 0) {
    Show-Usage
    exit 1
}

# The resolver (GlogService.buildBaseUrl) ignores GLOG_API_URL and derives the
# server from CLIENT/ENV. An --api-url that names a different host would send
# the host-side uploads to one server and the resolver's findings to another,
# so refuse that combination up front.
if ($apiUrl -and $resolverUpload -eq 'true') {
    $apiNorm = $apiUrl.TrimEnd('/')
    if ($apiNorm.EndsWith('/api')) { $apiNorm = $apiNorm.Substring(0, $apiNorm.Length - 4) }
    $resolverUrl = Get-ResolverServerUrl -Client $client -EnvironmentName $environmentName
    if ($apiNorm -ne $resolverUrl) {
        [Console]::Error.WriteLine("ERROR: --api-url is $apiUrl but the resolver will upload to $resolverUrl (derived from --client/--env).")
        [Console]::Error.WriteLine('       For a local server pass --env localhost; for a hosted tenant drop --api-url or make it match.')
        exit 1
    }
}

if ($supplyChainFailOn -and $supplyChainFailOn -notin @('INFO', 'LOW', 'MEDIUM', 'HIGH', 'CRITICAL')) {
    [Console]::Error.WriteLine("Invalid --supply-chain-fail-on: $supplyChainFailOn (expected INFO, LOW, MEDIUM, HIGH or CRITICAL)")
    exit 1
}

try {
    $projectPath = Get-AbsolutePath -PathValue $projectPath

    foreach ($command in $commands) {
        switch ($command) {
            'remediate' {
                # Remediation on its own, over the .glog/glog-scan.sarif an
                # earlier scan left. "scan --remediate" already runs it.
                if (-not ($commands -contains 'scan' -and $remediate -eq 'true')) {
                    if ($remediationMode -notin @('patch','branch','local')) { throw "Invalid --remediation-mode: $remediationMode (expected: patch, branch, local)" }
                    Invoke-GlogRemediation -ProjectPath $projectPath -Registry $registry -GlogToken $glogToken -ApiUrl $apiUrl -Client $client -EnvironmentName $environmentName -Mode $remediationMode -Apply $remediationApply -RequireVerified $remediationRequireVerified -AllowDirty $remediationAllowDirty -MinSeverity $remediationMinSeverity -MaxFindings $remediationMaxFindings
                }
            }
            'clean' {
                Write-Output "Cleaning .glog directory in $projectPath..."
                $glogDir = Join-Path -Path $projectPath -ChildPath '.glog'
                if (Test-Path -LiteralPath $glogDir -PathType Container) {
                    Get-ChildItem -LiteralPath $glogDir -Force | Remove-Item -Recurse -Force
                }
                New-Item -ItemType Directory -Path $glogDir -Force | Out-Null
            }
            'scan' {
                $scanPath = $projectPath
                New-Item -ItemType File -Force -Path $scanStartStamp | Out-Null

                if ($files.Count -gt 0) {
                    Write-Output 'Preparing scoped scan for selected files...'
                    $scanPath = New-ScopedFilesDir -ProjectDir $projectPath -InputFiles @($files)
                    $tempScanDir = $scanPath
                    Write-Output "Scoped scan directory: $scanPath"
                }

                if ($languages.Count -eq 0) {
                    $detected = Get-DetectedLanguages -ProjectDir $scanPath
                    foreach ($lang in $detected) {
                        [void]$languages.Add($lang)
                    }
                }

                # Reachability is not a language, it is the CPG/dataflow engine
                # that runs over Python sources. Get-DetectedLanguages maps file
                # EXTENSIONS to scanner keys, so nothing it returns could ever
                # select it. Chosen here, after $languages is populated, so it
                # applies however Python was selected: by detection or by an
                # explicit -l python. A scan with no Python is untouched, and an
                # explicit -l reachability is not queued twice.
                if ($languages -contains 'python' -and -not ($languages -contains 'reachability')) {
                    [void]$languages.Add('reachability')
                }

                # SBOM must run BEFORE resolver so the resolver can pick up
                # /app/.glog/sbom.cdx.json and upload it to /api/sca/resolver/sbom/.
                if ($withSbom -eq 'true' -and -not ($languages -contains 'sbom')) {
                    [void]$languages.Add('sbom')
                }
                if ($withVex -eq 'true') {
                    [void]$languages.Add('vex')
                }

                [void]$languages.Add('resolver')

                $sbomMode = if ($resolverUpload -eq 'true') { 'persist' } else { 'stateless' }
                $forceInventoryFlag = if ($forceInventory) { 'true' } else { 'false' }

                Write-Output "Glog scan options: WITH_SBOM=$withSbom SBOM_ONLY=$sbomOnly FORCE_INVENTORY=$forceInventoryFlag RESOLVER_UPLOAD=$resolverUpload SCL_UUID=$(if ($sclUuid) { $sclUuid } else { '<auto>' })"
                if ($withSbom -eq 'true' -and $resolverUpload -ne 'true') {
                    Write-Output 'Note: SBOM will be written locally to .glog/ only. To send it to the Glog server pass on-prem-upload=true.'
                }

                if ($privacyTier -notin @('full','metrics','none')) { throw "Invalid --privacy-tier: $privacyTier (expected: full, metrics, none)" }
                if ($remediationMode -notin @('patch','branch','local')) { throw "Invalid --remediation-mode: $remediationMode (expected: patch, branch, local)" }

                # Shared arguments, so the four call sites below cannot drift.
                $scanArgs = @{
                    PathToScan           = $scanPath
                    Ignore               = $ignore
                    Client               = $client
                    EnvironmentName      = $environmentName
                    Registry             = $registry
                    GlogToken            = $glogToken
                    WithSbom             = $withSbom
                    SbomOnly             = $sbomOnly
                    SbomMode             = $sbomMode
                    SclUuid              = $sclUuid
                    ForceInventory       = $forceInventoryFlag
                    ApiUrl               = $apiUrl
                    SupplyChainEnabled   = $supplyChainEnabled
                    SupplyChainPolicy    = $supplyChainPolicy
                    SupplyChainOffline   = $supplyChainOffline
                    SupplyChainCacheOnly = $supplyChainCacheOnly
                    SupplyChainFailOn    = $supplyChainFailOn
                    SupplyChainFormat    = $supplyChainFormat
                }

                # Every scanner but the resolver runs offline: the resolver is
                # the only stage that talks to the server, in the passes below.
                foreach ($lang in $languages) {
                    if ($lang -eq 'resolver') { continue }
                    Write-Output "Analyzing language: $lang"
                    Invoke-ScanLang @scanArgs -Lang $lang -SarifFormatType $sarifFormatType -ResolverUpload 'false' -PrivacyTier $privacyTier
                }

                # Resolver passes. When the platform (committed / native SARIF
                # UI) needs a different structure than the Glog server, the
                # resolver runs twice:
                #   1. server format, with upload  -> what the server ingests
                #   2. platform format, no upload  -> what stays in .glog/
                if ($serverSarifFormatType -and $serverSarifFormatType -ne $sarifFormatType -and $resolverUpload -eq 'true') {
                    Write-Output "Resolver pass 1/2: format=$serverSarifFormatType (server upload)"
                    Invoke-ScanLang @scanArgs -Lang 'resolver' -SarifFormatType $serverSarifFormatType -ResolverUpload 'true' -PrivacyTier $privacyTier
                    Write-Output "Resolver pass 2/2: format=$sarifFormatType (local/platform artifact)"
                    # This pass only rewrites the local platform artifact. Keep
                    # it fully offline so it cannot duplicate or fail an upload
                    # that already completed.
                    Invoke-ScanLang @scanArgs -Lang 'resolver' -SarifFormatType $sarifFormatType -ResolverUpload 'false' -PrivacyTier 'none'
                } else {
                    Write-Output "Resolver pass: format=$sarifFormatType upload=$resolverUpload"
                    Invoke-ScanLang @scanArgs -Lang 'resolver' -SarifFormatType $sarifFormatType -ResolverUpload $resolverUpload -PrivacyTier $privacyTier
                }

                if ($withVex -eq 'true') {
                    Send-GlogVex -ScanPath $scanPath -ResolverUpload $resolverUpload -PrivacyTier $privacyTier -ApiUrl $apiUrl -Client $client -EnvironmentName $environmentName -GlogToken $glogToken -SclUuid $sclUuid
                }
                if ($withCbom -eq 'true') {
                    Invoke-GlogCbom -ScanPath $scanPath -Registry $registry
                    Send-GlogCbom -ScanPath $scanPath -ResolverUpload $resolverUpload -PrivacyTier $privacyTier -ApiUrl $apiUrl -Client $client -EnvironmentName $environmentName -GlogToken $glogToken -SclUuid $sclUuid
                }
                if ($withSbom -eq 'true') {
                    if (Test-GlogSbomQuality -ScanPath $scanPath -MinGrade $sbomMinGrade -ApiUrl $apiUrl -Client $client -EnvironmentName $environmentName -GlogToken $glogToken) {
                        $sbomGateFailed = $true
                    }
                }

                # The resolver container exits 0 even when its uploads failed
                # (entrypoint.py discards the jar's exit code), so the only
                # signal is the UPLOAD_FAILED line it writes to
                # .glog/glog-scan.log. Only a log written by this run counts:
                # .glog/ is not emptied first, so an older log must not trip it.
                if ($resolverUpload -eq 'true') {
                    $resolverLog = Join-Path -Path $scanPath -ChildPath '.glog/glog-scan.log'
                    if ((Test-Path -LiteralPath $resolverLog) -and
                        ((Get-Item -LiteralPath $resolverLog).LastWriteTime -gt (Get-Item -LiteralPath $scanStartStamp).LastWriteTime)) {
                        $failure = [regex]::Match((Get-Content -LiteralPath $resolverLog -Raw), 'UPLOAD_FAILED[^|]*(\| details=\[[^\]]{0,200})?')
                        if ($failure.Success) {
                            $uploadFailed = $true
                            [Console]::Error.WriteLine("ERROR: resolver upload failed: $($failure.Value)")
                        }
                    }
                }

                Persist-ScopedScanArtifacts -ScanPath $scanPath -ProjectPath $projectPath
                if (-not (Test-ScanArtifacts -ProjectPath $projectPath -SbomOnly $sbomOnly -WithSbom $withSbom -ResolverUpload $resolverUpload)) {
                    throw 'Glog: expected scan artifacts are missing - failing the step.'
                }
                # On the real tree, not a scoped copy: the fixes have to land
                # where the developer will apply them.
                if ($remediate -eq 'true') {
                    Invoke-GlogRemediation -ProjectPath $projectPath -Registry $registry -GlogToken $glogToken -ApiUrl $apiUrl -Client $client -EnvironmentName $environmentName -Mode $remediationMode -Apply $remediationApply -RequireVerified $remediationRequireVerified -AllowDirty $remediationAllowDirty -MinSeverity $remediationMinSeverity -MaxFindings $remediationMaxFindings
                }
                if ($sbomGateFailed) {
                    [Console]::Error.WriteLine('Exiting 3 because the SBOM quality gate failed (artifacts were still written to .glog/).')
                    exit 3
                }
                if ($uploadFailed -and $failOnUploadError -eq 'true') {
                    [Console]::Error.WriteLine('Exiting 2 because --fail-on-upload-error is set (SARIF was still written to .glog/).')
                    exit 2
                }

                if ($rebuild -eq 'true') {
                    if (-not $apiUrl -and $client) {
                        # The resolver image carries its own server URL; the
                        # host-side rebuild client does not, so derive the
                        # tenant URL from client and env.
                        $apiUrl = if ($environmentName -match '^(dev|development)$') { "https://$client.dev.glog.ai" } else { "https://$client.glog.ai" }
                        Write-Output "Rebuild: --api-url not set, using $apiUrl"
                    }
                    if (-not $apiUrl -or -not $glogToken) {
                        [Console]::Error.WriteLine('Warning: rebuild skipped, it requires GLOG_API_URL (--api-url) and GLOG_TOKEN')
                    } else {
                        $python = Get-Command python3 -ErrorAction SilentlyContinue
                        if (-not $python) { $python = Get-Command python -ErrorAction SilentlyContinue }
                        if (-not $python) {
                            [Console]::Error.WriteLine('Warning: rebuild skipped, it requires python3 (or python) on PATH.')
                        } else {
                            Write-Output 'Running reproducible-build worker for all discovered dependencies'
                            $rebuildArgs = @('--api-url', $apiUrl, '--token', $glogToken, '--image', $rebuildImage, '--project-path', $projectPath)
                            if ($sclUuid) { $rebuildArgs += @('--source-code-location', $sclUuid) }
                            # By default this is all-dependency mode. The legacy
                            # flags opt into one artifact.
                            if ($rebuildArtifact) {
                                if (-not $rebuildPackage -or -not $rebuildVersion -or -not $rebuildEcosystem) {
                                    [Console]::Error.WriteLine('Single-artifact mode requires --rebuild-package, --rebuild-version and --rebuild-ecosystem')
                                    exit 1
                                }
                                $rebuildArgs += @('--artifact', $rebuildArtifact, '--package-name', $rebuildPackage, '--package-version', $rebuildVersion, '--ecosystem', $rebuildEcosystem)
                                if ($rebuildManifest) { $rebuildArgs += @('--published-manifest', $rebuildManifest) }
                            } else {
                                $rebuildArgs += @('--auto')
                                if ($rebuildMaxPackages) { $rebuildArgs += @('--max-packages', $rebuildMaxPackages) }
                            }
                            & $python.Source (Join-Path -Path $PSScriptRoot -ChildPath 'rebuild_client.py') @rebuildArgs
                            if ($LASTEXITCODE -ne 0) {
                                [Console]::Error.WriteLine('Warning: rebuild submission failed; SARIF/SBOM results are unaffected')
                            }
                        }
                    }
                }

                $glogDir = Join-Path -Path $projectPath -ChildPath '.glog'
                if (Test-Path -LiteralPath $glogDir -PathType Container) {
                    $keepPatterns = @('glog-scan.sarif', '*.cdx.json', '*.vdr.json', 'sbom*.json', 'glog-ai-*')
                    Get-ChildItem -LiteralPath $glogDir -Force |
                        Where-Object {
                            $name = $_.Name
                            -not ($keepPatterns | Where-Object { $name -like $_ })
                        } |
                        Remove-Item -Recurse -Force
                    Write-Output "Removed intermediate artifacts from $glogDir"
                }
            }
        }
    }
} finally {
    if ($tempScanDir -and (Test-Path -LiteralPath $tempScanDir -PathType Container)) {
        Remove-Item -LiteralPath $tempScanDir -Recurse -Force
    }
    if ($scanStartStamp -and (Test-Path -LiteralPath $scanStartStamp)) {
        Remove-Item -LiteralPath $scanStartStamp -Force
    }
}
