#!/usr/bin/env pwsh
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$defaultLangs = @('cpp', 'java', 'javascript', 'python', 'kotlin', 'php', 'ruby', 'csharp', 'oss', 'terraform', 'secrets', 'resolver', 'inventory', 'objectscript', 'go')

$imageMap = @{
    oss          = @('glog-scan-oss-cc90')
    java         = @('glog-scan-java-b608', 'glog-scan-java-3e9a', 'glog-scan-java-e2b1')
    ruby         = @('glog-scan-ruby-35d9')
    terraform    = @('glog-scan-terraform-51c8', 'glog-scan-terraform-6b93', 'glog-scan-terraform-8bd5')
    cpp          = @('glog-scan-cpp-c97a')
    inventory    = @('glog-scan-inventory-5a5b')
    python       = @('glog-scan-python-5f95', 'glog-scan-python-0386', 'glog-scan-python-4166')
    secrets      = @('glog-scan-secrets-f27b')
    csharp       = @('glog-scan-csharp-b460', 'glog-scan-csharp-6c24')
    php          = @('glog-scan-php-7d88', 'glog-scan-php-4719', 'glog-scan-php-ba41')
    kotlin       = @('glog-scan-kotlin-d734')
    resolver     = @('glog-scan-resolver-fbbb')
    javascript   = @('glog-scan-javascript-0af1', 'glog-scan-javascript-3cb4')
    objectscript = @('glog-scan-objectscript-b977')
    go           = @('glog-scan-go-cb38', 'glog-scan-go-c6d3')
}

function Show-Usage {
    @'
Glog.AI Scanner CLI
Usage: glog.ps1 [clean] [scan] [options]

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
  -u|--upload               Upload scan results to On-Prem Dashboard
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

    $isWindows = $env:OS -eq 'Windows_NT'
    if ($isWindows) {
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
        [Parameter(Mandatory = $true)][string]$Client,
        [Parameter(Mandatory = $true)][string]$EnvironmentName,
        [Parameter(Mandatory = $true)][string]$Registry,
        [Parameter(Mandatory = $true)][string]$SarifFormatType,
        [Parameter(Mandatory = $true)][string]$GlogToken,
        [Parameter(Mandatory = $true)][string]$ResolverUpload
    )

    if (-not $imageMap.ContainsKey($Lang)) {
        return
    }

    $hostUid = Get-HostIdValue -Kind uid
    $hostGid = Get-HostIdValue -Kind gid
    $resolvedScanPath = Get-AbsolutePath -PathValue $PathToScan
    $isWindows = $env:OS -eq 'Windows_NT'
    $volName = $null
    $scanMount = "${resolvedScanPath}:/app"

    try {
        if ($isWindows) {
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

            $dockerArgs = @(
                'run', '--pull', 'always', '--rm',
                '-e', "GLOGSERVICE=$GlogToken",
                '-e', "GLOG_TOKEN=$GlogToken",
                '-e', "HOST_UID=$hostUid",
                '-e', "HOST_GID=$hostGid",
                '-e', "SARIF_FORMAT_TYPE=$SarifFormatType",
                '-e', "RESOLVER_UPLOAD=$ResolverUpload",
                '-e', "IGNORE=$Ignore",
                '-e', "CLIENT=$Client",
                '-e', "ENV=$EnvironmentName",
                '-e', "GLOG_IMAGE=$imageName"
            )

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

        if ($isWindows) {
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
$glogToken = if ($env:GLOG_TOKEN) { $env:GLOG_TOKEN } else { '' }
$sarifFormatType = if ($env:SARIF_FORMAT_TYPE) { $env:SARIF_FORMAT_TYPE } else { 'GITHUB' }
$resolverUpload = 'false'
$files = [System.Collections.Generic.List[string]]::new()
$tempScanDir = $null

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
                [void]$languages.Add($item)
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

try {
    $projectPath = Get-AbsolutePath -PathValue $projectPath

    foreach ($command in $commands) {
        switch ($command) {
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

                [void]$languages.Add('resolver')

                foreach ($lang in $languages) {
                    Write-Output "Analyzing language: $lang"
                    Invoke-ScanLang -Lang $lang -PathToScan $scanPath -Ignore $ignore -Client $client -EnvironmentName $environmentName -Registry $registry -SarifFormatType $sarifFormatType -GlogToken $glogToken -ResolverUpload $resolverUpload
                }

                Persist-ScopedScanArtifacts -ScanPath $scanPath -ProjectPath $projectPath

                $glogDir = Join-Path -Path $projectPath -ChildPath '.glog'
                if (Test-Path -LiteralPath $glogDir -PathType Container) {
                    Get-ChildItem -LiteralPath $glogDir -Force |
                        Where-Object { $_.Name -ne 'glog-scan.sarif' } |
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
}
