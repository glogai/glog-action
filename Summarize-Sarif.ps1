[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [Alias('Path')]
  [string]$SarifFile,

  [string]$FailOnError = $env:FAIL_ON_ERROR,
  [string]$FailOnWarning = $env:FAIL_ON_WARNING
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $SarifFile -PathType Leaf)) {
  Write-Error "Missing SARIF file: $SarifFile"
  exit 1
}

try {
  $raw = Get-Content -LiteralPath $SarifFile -Raw -ErrorAction Stop
  $sarif = ConvertFrom-Json -InputObject $raw -ErrorAction Stop
} catch {
  Write-Error $_
  exit 1
}

$errors = 0
$warnings = 0
$notes = 0

foreach ($run in @($sarif.runs)) {
  foreach ($result in @($run.results)) {
    $level = [string]$result.level
    if ([string]::IsNullOrWhiteSpace($level)) {
      $level = 'warning'
    }

    switch ($level.ToLowerInvariant()) {
      'error' { $errors++ }
      'warning' { $warnings++ }
      'note' { $notes++ }
    }
  }
}

Write-Output "SARIF summary: errors=$errors warnings=$warnings notes=$notes"

$shouldFailOnError = $true
if (-not [string]::IsNullOrWhiteSpace($FailOnError) -and $FailOnError.Equals('false', [System.StringComparison]::OrdinalIgnoreCase)) {
  $shouldFailOnError = $false
}

if ($errors -gt 0) {
  Write-Output 'Error: SARIF contains error-level findings'
  if ($shouldFailOnError) {
    Write-Output 'Blocking build because FAIL_ON_ERROR=true'
    exit 1
  }
}

$shouldFailOnWarning = $false
if (-not [string]::IsNullOrWhiteSpace($FailOnWarning) -and $FailOnWarning.Equals('true', [System.StringComparison]::OrdinalIgnoreCase)) {
  $shouldFailOnWarning = $true
}

if ($warnings -gt 0) {
  Write-Output 'Warning: SARIF contains warning-level findings'
  if ($shouldFailOnWarning) {
    Write-Output 'Blocking build because FAIL_ON_WARNING=true'
    exit 1
  }
}

exit 0
