param(
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$StudyId = 'STOIX-VCFE-C1C2-D4S-FC-20261110-01'
$ExpectedCommitment = '1344463a84d475362b560daadc9d3bc9509f6e001263a25b4b39b3cb27ef40a3'
$FailedRunnerSha256 = '4694579c80edfb02f2eab6cf4854977e42f0267eee0802ae1679cc910d9d535b'
$FreezeBundleSha256 = '5792d146d135d1a655feb05aa6434d5c4711b8098d6788cc3ac128721bbbc8fd'
$SmokeVerificationSha256 = 'edf45ce738d4de2e38bef6df8b43b2840ba48185718bbcb93047abbe336c9ab9'
$SmokeReceiptSha256 = '7695b525c0598fa5c9c2301942de67b5a74343ab8f173d65d1a900965b6b4add'
$SmokeContractSha256 = '681b6ecc6be032d39d135ed6a40e804d1210af47ea973ff1135dd7963ec9035f'
$OriginalFailure = "The process does not possess the 'SeSecurityPrivilege' privilege which is required for this operation."
$PrimaryEntropyText = 'STOIX-VCFE-C1C2-D4S-PRIMARY'
$BackupEntropyText  = 'STOIX-VCFE-C1C2-D4S-BACKUP'

function Require-Condition {
    param([bool]$Condition,[string]$Code)
    if (-not $Condition) { throw $Code }
}

function Get-Sha256Hex {
    param([byte[]]$Bytes)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-FileSha256Hex {
    param([string]$Path)
    $b = [IO.File]::ReadAllBytes($Path)
    try { return Get-Sha256Hex $b }
    finally { if ($b) { [Array]::Clear($b,0,$b.Length) } }
}

function Assert-NoReparseChain {
    param([string]$Path)
    $item = Get-Item -LiteralPath $Path -Force
    while ($null -ne $item) {
        Require-Condition (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) "D4S_REPARSE_ALIAS::$($item.FullName)"
        $parent = Split-Path -Parent $item.FullName
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $item.FullName -or -not (Test-Path -LiteralPath $parent)) { break }
        $item = Get-Item -LiteralPath $parent -Force
    }
}

function Set-And-VerifyCustodyAcl {
    param([string]$Path,[bool]$Directory)
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $userGrant = if ($Directory) { "*$($sid):(OI)(CI)F" } else { "*$($sid):F" }
    $systemGrant = if ($Directory) { '*S-1-5-18:(OI)(CI)F' } else { '*S-1-5-18:F' }

    & icacls.exe $Path /inheritance:r | Out-Null
    Require-Condition ($LASTEXITCODE -eq 0) "D4S_ICACLS_INHERITANCE_FAILED::$Path::$LASTEXITCODE"

    & icacls.exe $Path /grant:r $userGrant $systemGrant | Out-Null
    Require-Condition ($LASTEXITCODE -eq 0) "D4S_ICACLS_GRANT_FAILED::$Path::$LASTEXITCODE"

    $acl = Get-Acl -LiteralPath $Path
    Require-Condition $acl.AreAccessRulesProtected "D4S_ACL_INHERITANCE::$Path"
    $rules = @($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))
    Require-Condition ($rules.Count -eq 2) "D4S_ACL_RULE_COUNT::$Path::$($rules.Count)"
    foreach ($rule in $rules) {
        Require-Condition ($rule.IdentityReference.Value -in @($sid,'S-1-5-18')) "D4S_ACL_PRINCIPAL::$Path"
        Require-Condition ($rule.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow) "D4S_ACL_TYPE::$Path"
        $full = [Security.AccessControl.FileSystemRights]::FullControl
        Require-Condition ((($rule.FileSystemRights -band $full) -eq $full)) "D4S_ACL_RIGHTS::$Path"
    }
    return [ordered]@{
        inheritance_protected = $true
        explicit_ace_count = 2
        current_user_sid = $sid
        system_sid = 'S-1-5-18'
        full_control_only = $true
        mechanism = 'icacls.exe'
    }
}

function Protect-Bytes {
    param([byte[]]$Plain,[string]$EntropyText,[Security.Cryptography.DataProtectionScope]$Scope)
    $entropy = [Text.Encoding]::UTF8.GetBytes($EntropyText)
    try { return [byte[]][Security.Cryptography.ProtectedData]::Protect($Plain,$entropy,$Scope) }
    finally { [Array]::Clear($entropy,0,$entropy.Length) }
}

function Unprotect-Bytes {
    param([byte[]]$Cipher,[string]$EntropyText,[Security.Cryptography.DataProtectionScope]$Scope)
    $entropy = [Text.Encoding]::UTF8.GetBytes($EntropyText)
    try { return [byte[]][Security.Cryptography.ProtectedData]::Unprotect($Cipher,$entropy,$Scope) }
    finally { [Array]::Clear($entropy,0,$entropy.Length) }
}

function Write-NewBytes {
    param([string]$Path,[byte[]]$Bytes)
    $fs = [IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try { $fs.Write($Bytes,0,$Bytes.Length); $fs.Flush($true) }
    finally { $fs.Dispose() }
}

function Write-NewUtf8 {
    param([string]$Path,[string]$Text)
    $enc = [Text.UTF8Encoding]::new($false)
    $bytes = $enc.GetBytes($Text)
    try { Write-NewBytes $Path $bytes }
    finally { [Array]::Clear($bytes,0,$bytes.Length) }
}

function Invoke-Recovery {
    param(
        [string]$PrimaryPath,
        [string]$BackupPath,
        [string]$StartMarkerPath,
        [string]$ReceiptPath,
        [string]$ExpectedCommitmentLocal,
        [string]$OriginalReceiptPathLocal
    )

    Require-Condition (Test-Path -LiteralPath $StartMarkerPath -PathType Leaf) 'D4S_RECOVERY_START_MARKER_MISSING'
    Require-Condition (Test-Path -LiteralPath $PrimaryPath -PathType Leaf) 'D4S_RECOVERY_PRIMARY_MISSING'
    Require-Condition (-not (Test-Path -LiteralPath $ReceiptPath)) 'D4S_RECOVERY_RECEIPT_ALREADY_EXISTS'
    if (-not [string]::IsNullOrWhiteSpace($OriginalReceiptPathLocal)) {
        Require-Condition (-not (Test-Path -LiteralPath $OriginalReceiptPathLocal)) 'D4S_RECOVERY_ORIGINAL_RECEIPT_UNEXPECTEDLY_EXISTS'
    }

    $marker = Get-Content -LiteralPath $StartMarkerPath -Raw | ConvertFrom-Json
    Require-Condition ($marker.schema -eq 'STOIX_VCFE_C1C2_D4S_MASTER_SEED_CEREMONY_START_v1') 'D4S_RECOVERY_MARKER_SCHEMA'
    Require-Condition ($marker.study_id -eq $StudyId) 'D4S_RECOVERY_MARKER_STUDY'
    Require-Condition ($marker.freeze_bundle_sha256 -eq $FreezeBundleSha256) 'D4S_RECOVERY_MARKER_FREEZE'
    Require-Condition ($marker.smoke_verification_sha256 -eq $SmokeVerificationSha256) 'D4S_RECOVERY_MARKER_SMOKE_VERIFICATION'
    Require-Condition ($marker.smoke_receipt_sha256 -eq $SmokeReceiptSha256) 'D4S_RECOVERY_MARKER_SMOKE_RECEIPT'
    Require-Condition ($marker.smoke_contract_sha256 -eq $SmokeContractSha256) 'D4S_RECOVERY_MARKER_SMOKE_CONTRACT'
    Require-Condition ([bool]$marker.seed_generation_may_occur_after_marker) 'D4S_RECOVERY_MARKER_SEED_GATE'
    Require-Condition (-not [bool]$marker.seed_regeneration_allowed) 'D4S_RECOVERY_MARKER_REGENERATION_POLICY'

    $primaryDir = Split-Path -Parent $PrimaryPath
    $backupDir = Split-Path -Parent $BackupPath
    $receiptDir = Split-Path -Parent $ReceiptPath
    [IO.Directory]::CreateDirectory($backupDir) | Out-Null
    [IO.Directory]::CreateDirectory($receiptDir) | Out-Null

    Assert-NoReparseChain $primaryDir
    Assert-NoReparseChain $backupDir
    Assert-NoReparseChain $PrimaryPath

    $pDrive = (Split-Path -Qualifier $PrimaryPath).TrimEnd('\').TrimEnd(':')
    $bDrive = (Split-Path -Qualifier $BackupPath).TrimEnd('\').TrimEnd(':')
    $pVol = Get-Volume -DriveLetter $pDrive -ErrorAction Stop
    $bVol = Get-Volume -DriveLetter $bDrive -ErrorAction Stop
    Require-Condition ($pVol.UniqueId -ne $bVol.UniqueId) 'D4S_RECOVERY_STORAGE_NOT_DISTINCT'

    $primaryCipher = [IO.File]::ReadAllBytes($PrimaryPath)
    $seed = $null
    $backupCipher = $null
    $primaryReplay = $null
    $backupReplay = $null
    try {
        $seed = Unprotect-Bytes $primaryCipher $PrimaryEntropyText ([Security.Cryptography.DataProtectionScope]::CurrentUser)
        Require-Condition ($seed.Length -eq 32) 'D4S_RECOVERY_PRIMARY_LENGTH'
        $commitment = Get-Sha256Hex $seed
        Require-Condition ($commitment -eq $ExpectedCommitmentLocal) 'D4S_RECOVERY_COMMITMENT_MISMATCH'

        $primaryDirAcl = Set-And-VerifyCustodyAcl $primaryDir $true
        $primaryFileAcl = Set-And-VerifyCustodyAcl $PrimaryPath $false
        $backupDirAcl = Set-And-VerifyCustodyAcl $backupDir $true

        if (Test-Path -LiteralPath $BackupPath -PathType Leaf) {
            Assert-NoReparseChain $BackupPath
            $backupCipher = [IO.File]::ReadAllBytes($BackupPath)
        } else {
            $backupCipher = Protect-Bytes $seed $BackupEntropyText ([Security.Cryptography.DataProtectionScope]::LocalMachine)
            Write-NewBytes $BackupPath $backupCipher
        }
        Assert-NoReparseChain $BackupPath
        $backupFileAcl = Set-And-VerifyCustodyAcl $BackupPath $false

        $primaryReplay = Unprotect-Bytes ([IO.File]::ReadAllBytes($PrimaryPath)) $PrimaryEntropyText ([Security.Cryptography.DataProtectionScope]::CurrentUser)
        $backupReplay  = Unprotect-Bytes ([IO.File]::ReadAllBytes($BackupPath))  $BackupEntropyText  ([Security.Cryptography.DataProtectionScope]::LocalMachine)

        Require-Condition ($primaryReplay.Length -eq 32) 'D4S_RECOVERY_PRIMARY_REPLAY_LENGTH'
        Require-Condition ($backupReplay.Length -eq 32) 'D4S_RECOVERY_BACKUP_REPLAY_LENGTH'
        Require-Condition ((Get-Sha256Hex $primaryReplay) -eq $ExpectedCommitmentLocal) 'D4S_RECOVERY_PRIMARY_REPLAY_COMMITMENT'
        Require-Condition ((Get-Sha256Hex $backupReplay) -eq $ExpectedCommitmentLocal) 'D4S_RECOVERY_BACKUP_REPLAY_COMMITMENT'
        for ($i=0; $i -lt 32; $i++) {
            Require-Condition ($primaryReplay[$i] -eq $backupReplay[$i]) 'D4S_RECOVERY_DUAL_COPY_MISMATCH'
        }

        $receipt = [ordered]@{
            schema = 'STOIX_VCFE_C1C2_D4S_MASTER_SEED_CUSTODY_RECOVERY_RECEIPT_v1'
            study_id = $StudyId
            checkpoint = 'D4S_MASTER_SEED_AND_DUAL_CUSTODY_RECOVERY'
            status = 'PASS'
            lineage = [ordered]@{
                failed_runner_sha256 = $FailedRunnerSha256
                original_failure = $OriginalFailure
                seed_regenerated = $false
                same_master_seed_recovered = $true
            }
            master_seed_commitment_sha256 = $ExpectedCommitmentLocal
            primary = [ordered]@{
                path = $PrimaryPath
                dpapi_scope = 'CurrentUser'
                encrypted_file_sha256 = Get-FileSha256Hex $PrimaryPath
                encrypted_file_bytes = (Get-Item -LiteralPath $PrimaryPath).Length
                acl = $primaryFileAcl
                directory_acl = $primaryDirAcl
                replay = 'PASS'
            }
            backup = [ordered]@{
                path = $BackupPath
                dpapi_scope = 'LocalMachine'
                encrypted_file_sha256 = Get-FileSha256Hex $BackupPath
                encrypted_file_bytes = (Get-Item -LiteralPath $BackupPath).Length
                acl = $backupFileAcl
                directory_acl = $backupDirAcl
                replay = 'PASS'
            }
            independent_storage = $true
            custody_commitment_equality = 'PASS'
            raw_seed_persisted_plaintext = $false
            raw_seed_logged = $false
            raw_seed_emitted = $false
            fixture_generation_performed = $false
            scientific_execution_performed = $false
            created_utc = [DateTime]::UtcNow.ToString('o')
        }

        Write-NewUtf8 $ReceiptPath (($receipt | ConvertTo-Json -Depth 12 -Compress))
        $receiptSha = Get-FileSha256Hex $ReceiptPath

        Write-Output 'D4S_RECOVERY_STATUS=PASS'
        Write-Output ('D4S_MASTER_SEED_COMMITMENT_SHA256=' + $ExpectedCommitmentLocal)
        Write-Output ('D4S_CUSTODY_RECOVERY_RECEIPT_PATH=' + $ReceiptPath)
        Write-Output ('D4S_CUSTODY_RECOVERY_RECEIPT_SHA256=' + $receiptSha)
        Write-Output 'D4S_PRIMARY_REPLAY=PASS'
        Write-Output 'D4S_BACKUP_REPLAY=PASS'
        Write-Output 'D4S_CUSTODY_COMMITMENT_EQUALITY=PASS'
        Write-Output 'D4S_SEED_REGENERATED=NO'
        Write-Output 'D4S_FIXTURE_GENERATION_PERFORMED=NO'
        Write-Output 'D4S_SCIENTIFIC_EXECUTION_PERFORMED=NO'
    }
    finally {
        foreach ($b in @($primaryCipher,$seed,$backupCipher,$primaryReplay,$backupReplay)) {
            if ($null -ne $b -and $b -is [byte[]] -and $b.Length -gt 0) { [Array]::Clear($b,0,$b.Length) }
        }
    }
}

Add-Type -AssemblyName System.Security.Cryptography.ProtectedData

if ($SelfTest) {
    $vols = @(Get-Volume | Where-Object { $_.DriveLetter -and $_.UniqueId } | Sort-Object DriveLetter)
    $pair = $null
    for ($i=0; $i -lt $vols.Count; $i++) {
        for ($j=$i+1; $j -lt $vols.Count; $j++) {
            if ($vols[$i].UniqueId -ne $vols[$j].UniqueId) { $pair=@($vols[$i],$vols[$j]); break }
        }
        if ($pair) { break }
    }
    Require-Condition ($null -ne $pair) 'D4S_SELFTEST_TWO_DISTINCT_VOLUMES_REQUIRED'

    $tag = [Guid]::NewGuid().ToString('N')
    $rootA = "$($pair[0].DriveLetter):\d4s_ci_$tag"
    $rootB = "$($pair[1].DriveLetter):\d4s_ci_$tag"
    $p = Join-Path $rootA 'primary.dpapi'
    $b = Join-Path $rootB 'backup.dpapi'
    $m = Join-Path $rootA 'started.json'
    $r = Join-Path $rootA 'receipt.json'
    [IO.Directory]::CreateDirectory($rootA) | Out-Null
    [IO.Directory]::CreateDirectory($rootB) | Out-Null
    $synthetic = [byte[]](0..31)
    try {
        $c = Get-Sha256Hex $synthetic
        $pc = Protect-Bytes $synthetic $PrimaryEntropyText ([Security.Cryptography.DataProtectionScope]::CurrentUser)
        try { Write-NewBytes $p $pc } finally { [Array]::Clear($pc,0,$pc.Length) }
        $selfMarker = [ordered]@{
            schema = 'STOIX_VCFE_C1C2_D4S_MASTER_SEED_CEREMONY_START_v1'
            study_id = $StudyId
            freeze_bundle_sha256 = $FreezeBundleSha256
            smoke_verification_sha256 = $SmokeVerificationSha256
            smoke_receipt_sha256 = $SmokeReceiptSha256
            smoke_contract_sha256 = $SmokeContractSha256
            seed_generation_may_occur_after_marker = $true
            seed_regeneration_allowed = $false
        }
        Write-NewUtf8 $m (($selfMarker | ConvertTo-Json -Depth 8 -Compress))
        Invoke-Recovery $p $b $m $r $c ''
        Write-Output 'D4S_WINDOWS_CI_SELFTEST=PASS'
    }
    finally {
        [Array]::Clear($synthetic,0,$synthetic.Length)
        Remove-Item -LiteralPath $rootA -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $rootB -Recurse -Force -ErrorAction SilentlyContinue
    }
    exit 0
}

$PrimaryPath = 'C:\Users\Admin\AppData\Local\STOIXLAB\VCFE\secrets\c1c2_d4s\C1C2_D4S_MASTER_SEED.primary.dpapi'
$BackupPath = 'E:\STOIXLAB_SECRET_BACKUP\VCFE\c1c2_d4s\C1C2_D4S_MASTER_SEED.backup.dpapi'
$StartMarkerPath = 'C:\Users\Admin\AppData\Local\STOIXLAB\VCFE\evidence\c1c2_d4s\D4S_MASTER_SEED_CEREMONY_STARTED.json'
$ReceiptPath = 'C:\Users\Admin\AppData\Local\STOIXLAB\VCFE\evidence\c1c2_d4s\STOIX_VCFE_C1C2_D4S_MASTER_SEED_CUSTODY_RECOVERY_RECEIPT_FROZEN.json'
$OriginalReceiptPath = 'C:\Users\Admin\AppData\Local\STOIXLAB\VCFE\evidence\c1c2_d4s\STOIX_VCFE_C1C2_D4S_MASTER_SEED_CUSTODY_RECEIPT_FROZEN.json'

try {
    Invoke-Recovery $PrimaryPath $BackupPath $StartMarkerPath $ReceiptPath $ExpectedCommitment $OriginalReceiptPath
    exit 0
}
catch {
    Write-Output 'D4S_RECOVERY_STATUS=FAIL'
    Write-Output ('D4S_MASTER_SEED_COMMITMENT_SHA256=' + $ExpectedCommitment)
    Write-Output 'D4S_SEED_REGENERATION_ALLOWED=NO'
    Write-Output ('D4S_RECOVERY_ERROR=' + $_.Exception.Message)
    exit 2
}
