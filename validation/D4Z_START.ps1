Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$ExpectedMainSha256 = '9fa26170a488573a7b0755ecfe963a7b8799cda7805cebd0744b13dfda3c3f79'
$ExpectedPackageSha256 = 'a1959b53a8b4b165c58ded83bc3bef8e51f1881bf5bd40541c2e749fe8f8b736'

function Get-Sha256Lower([string]$Path) {
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Find-Pwsh {
    $Cmd = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if ($Cmd) { return $Cmd.Source }

    $Candidates = @(
        (Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\pwsh.exe')
    )
    foreach ($Candidate in $Candidates) {
        if ($Candidate -and (Test-Path -LiteralPath $Candidate -PathType Leaf)) {
            return $Candidate
        }
    }
    return $null
}

$Root = $PSScriptRoot
if (-not $Root) { $Root = (Get-Location).Path }

$Main = Join-Path $Root 'D4Z_PATH_A_ONE_CLICK_SELF_HOSTED.ps1'
$Package = Join-Path $Root 'D4Z_PATH_A_SELF_HOSTED_RUNNER_CANDIDATE.zip'

if (-not (Test-Path -LiteralPath $Main -PathType Leaf)) {
    throw "D4Z_MAIN_SCRIPT_MISSING::$Main"
}
if (-not (Test-Path -LiteralPath $Package -PathType Leaf)) {
    throw "D4Z_INNER_PACKAGE_MISSING::$Package"
}

$MainSha = Get-Sha256Lower $Main
if ($MainSha -ne $ExpectedMainSha256) {
    throw "D4Z_MAIN_SCRIPT_HASH_MISMATCH::$MainSha"
}
$PackageSha = Get-Sha256Lower $Package
if ($PackageSha -ne $ExpectedPackageSha256) {
    throw "D4Z_INNER_PACKAGE_HASH_MISMATCH::$PackageSha"
}

$Pwsh = Find-Pwsh
if (-not $Pwsh) {
    $Winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if (-not $Winget) {
        throw 'POWERSHELL_7_MISSING_AND_WINGET_UNAVAILABLE'
    }

    Write-Host 'Installing PowerShell 7...' -ForegroundColor Cyan
    & $Winget.Source install --id Microsoft.PowerShell --exact --accept-package-agreements --accept-source-agreements --silent
    if ($LASTEXITCODE -ne 0) {
        throw "POWERSHELL_7_INSTALL_FAILED::$LASTEXITCODE"
    }

    $Pwsh = Find-Pwsh
    if (-not $Pwsh) {
        throw 'POWERSHELL_7_INSTALLED_BUT_NOT_FOUND'
    }
}

Write-Host "D4Z_START_MAIN_SHA256=$MainSha"
Write-Host "D4Z_START_PACKAGE_SHA256=$PackageSha"
Write-Host "D4Z_START_PWSH=$Pwsh"
Write-Host 'D4Z_START=PASS'

& $Pwsh -NoProfile -ExecutionPolicy Bypass -File $Main -PackageZip $Package
if ($LASTEXITCODE -ne 0) {
    throw "D4Z_ONE_CLICK_FAILED::$LASTEXITCODE"
}
