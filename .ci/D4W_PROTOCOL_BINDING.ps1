param([switch]$SelfTest)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

$StudyId='STOIX-VCFE-C1C2-D4W-FC-20261110-01'
$ExpectedCommitment='9808cec46dafbcd26e0b0e6bd0248b60d872ad6961d00b67335f830b8b8e1ef3'
$ExpectedCustodyReceiptSha256='adc2699df4a3d6476c4bfe01fed9a5b84c1928e9560901a78c857c91df158bff'
$ExpectedFreezeBundleSha256='6c122a1a2ba546af1c5a3951b754b9b91b8040371f738dd5a389b99a5914411b'
$ExpectedSmokeVerificationSha256='382eeed9be14e3c0b54a3e86bb62ba33df4126501201ecf9044873fd599f7a45'
$ExpectedSmokeReceiptSha256='dbc0d77a904fdf475091b6238fc6ed48304b3ceee4074c8a8b874c8e0cb29fb3'
$ExpectedSmokeContractSha256='399dc9c0c594f4e95d979fa695e97731314b081ee4fc951135063c89ba10bfbf'
$PrimaryEntropyText='STOIX-VCFE-C1C2-D4W-PRIMARY'
$BackupEntropyText='STOIX-VCFE-C1C2-D4W-BACKUP'

function Require-Condition([bool]$Condition,[string]$Code){
    if(-not $Condition){throw $Code}
}

function Get-Sha256Hex([byte[]]$Bytes){
    $sha=[Security.Cryptography.SHA256]::Create()
    try{return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-','').ToLowerInvariant()}
    finally{$sha.Dispose()}
}

function Get-FileSha256Hex([string]$Path){
    $b=[IO.File]::ReadAllBytes($Path)
    try{return Get-Sha256Hex $b}
    finally{if($b){[Array]::Clear($b,0,$b.Length)}}
}

function Write-NewUtf8([string]$Path,[string]$Text){
    $enc=[Text.UTF8Encoding]::new($false)
    $bytes=$enc.GetBytes($Text)
    $fs=[IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{$fs.Write($bytes,0,$bytes.Length);$fs.Flush($true)}
    finally{$fs.Dispose();[Array]::Clear($bytes,0,$bytes.Length)}
}

function Write-NewBytes([string]$Path,[byte[]]$Bytes){
    $fs=[IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{$fs.Write($Bytes,0,$Bytes.Length);$fs.Flush($true)}
    finally{$fs.Dispose()}
}

function Protect-Bytes([byte[]]$Plain,[string]$EntropyText,[Security.Cryptography.DataProtectionScope]$Scope){
    $entropy=[Text.Encoding]::UTF8.GetBytes($EntropyText)
    try{return [byte[]][Security.Cryptography.ProtectedData]::Protect($Plain,$entropy,$Scope)}
    finally{[Array]::Clear($entropy,0,$entropy.Length)}
}

function Unprotect-Bytes([byte[]]$Cipher,[string]$EntropyText,[Security.Cryptography.DataProtectionScope]$Scope){
    $entropy=[Text.Encoding]::UTF8.GetBytes($EntropyText)
    try{return [byte[]][Security.Cryptography.ProtectedData]::Unprotect($Cipher,$entropy,$Scope)}
    finally{[Array]::Clear($entropy,0,$entropy.Length)}
}

function Set-TestAcl([string]$Path,[bool]$Directory){
    $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User
    $systemSid=[Security.Principal.SecurityIdentifier]::new('S-1-5-18')
    $inherit=[Security.AccessControl.InheritanceFlags]::None
    $prop=[Security.AccessControl.PropagationFlags]::None
    if($Directory){
        $inherit=[Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit
    }
    $acl=if($Directory){[Security.AccessControl.DirectorySecurity]::new()}else{[Security.AccessControl.FileSecurity]::new()}
    $acl.SetAccessRuleProtection($true,$false)
    foreach($identity in @($sid,$systemSid)){
        $rule=[Security.AccessControl.FileSystemAccessRule]::new(
            $identity,
            [Security.AccessControl.FileSystemRights]::FullControl,
            $inherit,
            $prop,
            [Security.AccessControl.AccessControlType]::Allow
        )
        [void]$acl.AddAccessRule($rule)
    }
    if($Directory){
        [IO.FileSystemAclExtensions]::SetAccessControl([IO.DirectoryInfo]::new($Path),$acl)
    }else{
        [IO.FileSystemAclExtensions]::SetAccessControl([IO.FileInfo]::new($Path),$acl)
    }
}

function Assert-StrictAcl([string]$Path){
    $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $allowed=@($sid,'S-1-5-18')
    $item=Get-Item -LiteralPath $Path
    $acl=if($item.PSIsContainer){
        [IO.FileSystemAclExtensions]::GetAccessControl([IO.DirectoryInfo]::new($Path))
    }else{
        [IO.FileSystemAclExtensions]::GetAccessControl([IO.FileInfo]::new($Path))
    }
    Require-Condition $acl.AreAccessRulesProtected "D4W_PROTOCOL_ACL_INHERITANCE::$Path"
    $rules=@($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))
    Require-Condition ($rules.Count -eq 2) "D4W_PROTOCOL_ACL_RULE_COUNT::$Path::$($rules.Count)"
    foreach($rule in $rules){
        Require-Condition ($rule.IdentityReference.Value -in $allowed) "D4W_PROTOCOL_ACL_PRINCIPAL::$Path"
        Require-Condition ($rule.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow) "D4W_PROTOCOL_ACL_TYPE::$Path"
        $full=[Security.AccessControl.FileSystemRights]::FullControl
        Require-Condition ((($rule.FileSystemRights -band $full) -eq $full)) "D4W_PROTOCOL_ACL_RIGHTS::$Path"
    }
    return [ordered]@{
        inheritance_protected=$true
        explicit_ace_count=2
        current_user_sid=$sid
        system_sid='S-1-5-18'
        full_control_only=$true
    }
}

function Invoke-ProtocolBinding(
    [string]$PrimaryPath,
    [string]$BackupPath,
    [string]$CustodyReceiptPath,
    [string]$OutputReceiptPath,
    [string]$ExpectedCommitmentLocal,
    [string]$ExpectedCustodyReceiptShaLocal,
    [bool]$RequireDistinctVolumes
){
    Require-Condition (Test-Path -LiteralPath $PrimaryPath -PathType Leaf) 'D4W_PROTOCOL_PRIMARY_MISSING'
    Require-Condition (Test-Path -LiteralPath $BackupPath -PathType Leaf) 'D4W_PROTOCOL_BACKUP_MISSING'
    Require-Condition (Test-Path -LiteralPath $CustodyReceiptPath -PathType Leaf) 'D4W_PROTOCOL_CUSTODY_RECEIPT_MISSING'
    Require-Condition (-not (Test-Path -LiteralPath $OutputReceiptPath)) 'D4W_PROTOCOL_BINDING_RECEIPT_ALREADY_EXISTS'

    $custodySha=Get-FileSha256Hex $CustodyReceiptPath
    Require-Condition ($custodySha -eq $ExpectedCustodyReceiptShaLocal) 'D4W_PROTOCOL_CUSTODY_RECEIPT_HASH'
    $cr=Get-Content -LiteralPath $CustodyReceiptPath -Raw|ConvertFrom-Json

    Require-Condition ($cr.schema -eq 'D4W_MASTER_SEED_CUSTODY_PROTOCOL_RECEIPT_v1') 'D4W_PROTOCOL_CUSTODY_SCHEMA'
    Require-Condition ($cr.study_id -eq $StudyId -and $cr.status -eq 'PASS') 'D4W_PROTOCOL_CUSTODY_IDENTITY'
    Require-Condition ([bool]$cr.encrypted_dual_custody -and [bool]$cr.independent_storage) 'D4W_PROTOCOL_CUSTODY_DUAL'
    Require-Condition ($cr.primary_custody_replay -eq 'PASS' -and $cr.backup_custody_replay -eq 'PASS' -and $cr.custody_commitment_equality -eq 'PASS') 'D4W_PROTOCOL_CUSTODY_REPLAY'
    Require-Condition ($cr.master_seed_commitment_sha256 -eq $ExpectedCommitmentLocal) 'D4W_PROTOCOL_CUSTODY_COMMITMENT'
    Require-Condition ($cr.freeze_bundle_sha256 -eq $ExpectedFreezeBundleSha256) 'D4W_PROTOCOL_FREEZE_BINDING'
    Require-Condition ($cr.smoke_verification_sha256 -eq $ExpectedSmokeVerificationSha256) 'D4W_PROTOCOL_SMOKE_VERIFICATION_BINDING'
    Require-Condition ($cr.smoke_receipt_sha256 -eq $ExpectedSmokeReceiptSha256) 'D4W_PROTOCOL_SMOKE_RECEIPT_BINDING'
    Require-Condition ($cr.smoke_contract_sha256 -eq $ExpectedSmokeContractSha256) 'D4W_PROTOCOL_SMOKE_CONTRACT_BINDING'
    Require-Condition ([int]$cr.seed_generation_count -eq 1 -and -not [bool]$cr.seed_regeneration_allowed) 'D4W_PROTOCOL_ONE_SHOT'
    Require-Condition (-not [bool]$cr.raw_seed_persisted_plaintext -and -not [bool]$cr.raw_seed_logged -and -not [bool]$cr.raw_seed_emitted) 'D4W_PROTOCOL_RAW_SEED_BOUNDARY'
    Require-Condition (-not [bool]$cr.fixture_generation_performed -and -not [bool]$cr.scientific_execution_performed) 'D4W_PROTOCOL_NO_SCIENCE'
    Require-Condition (-not [bool]$cr.test_only) 'D4W_PROTOCOL_PRODUCTION_RECEIPT'
    Require-Condition ($cr.primary.path -eq $PrimaryPath -and $cr.backup.path -eq $BackupPath) 'D4W_PROTOCOL_PATH_BINDING'

    if($RequireDistinctVolumes){
        $pDrive=(Split-Path -Qualifier $PrimaryPath).TrimEnd('\').TrimEnd(':')
        $bDrive=(Split-Path -Qualifier $BackupPath).TrimEnd('\').TrimEnd(':')
        $pVol=Get-Volume -DriveLetter $pDrive -ErrorAction Stop
        $bVol=Get-Volume -DriveLetter $bDrive -ErrorAction Stop
        Require-Condition ($pVol.UniqueId -ne $bVol.UniqueId) 'D4W_PROTOCOL_STORAGE_NOT_DISTINCT'
    }

    $primaryAcl=Assert-StrictAcl $PrimaryPath
    $backupAcl=Assert-StrictAcl $BackupPath

    $pc=[IO.File]::ReadAllBytes($PrimaryPath)
    $bc=[IO.File]::ReadAllBytes($BackupPath)
    $p=$null
    $b=$null
    try{
        Require-Condition ((Get-Sha256Hex $pc) -eq $cr.primary.encrypted_file_sha256) 'D4W_PROTOCOL_PRIMARY_CIPHER_HASH'
        Require-Condition ((Get-Sha256Hex $bc) -eq $cr.backup.encrypted_file_sha256) 'D4W_PROTOCOL_BACKUP_CIPHER_HASH'

        $p=Unprotect-Bytes $pc $PrimaryEntropyText ([Security.Cryptography.DataProtectionScope]::CurrentUser)
        $b=Unprotect-Bytes $bc $BackupEntropyText ([Security.Cryptography.DataProtectionScope]::LocalMachine)

        Require-Condition ($p.Length -eq 32 -and $b.Length -eq 32) 'D4W_PROTOCOL_REPLAY_LENGTH'
        $pCommit=Get-Sha256Hex $p
        $bCommit=Get-Sha256Hex $b
        Require-Condition ($pCommit -eq $ExpectedCommitmentLocal) 'D4W_PROTOCOL_PRIMARY_COMMITMENT'
        Require-Condition ($bCommit -eq $ExpectedCommitmentLocal) 'D4W_PROTOCOL_BACKUP_COMMITMENT'
        for($i=0;$i -lt 32;$i++){Require-Condition ($p[$i] -eq $b[$i]) 'D4W_PROTOCOL_DUAL_COPY_MISMATCH'}

        $receipt=[ordered]@{
            schema='D4W_CUSTODY_RECEIPT_PROTOCOL_BINDING_v1'
            study_id=$StudyId
            checkpoint='D4W_MASTER_SEED_AND_DUAL_CUSTODY_PROTOCOL_BINDING'
            status='PASS'
            source_custody_receipt_sha256=$custodySha
            freeze_bundle_sha256=$ExpectedFreezeBundleSha256
            smoke_verification_sha256=$ExpectedSmokeVerificationSha256
            smoke_receipt_sha256=$ExpectedSmokeReceiptSha256
            smoke_contract_sha256=$ExpectedSmokeContractSha256
            encrypted_dual_custody=$true
            independent_storage=$true
            primary_custody_replay='PASS'
            backup_custody_replay='PASS'
            custody_commitment_equality='PASS'
            master_seed_commitment_sha256=$ExpectedCommitmentLocal
            primary=[ordered]@{
                path=$PrimaryPath
                dpapi_scope='CurrentUser'
                encrypted_file_sha256=Get-Sha256Hex $pc
                encrypted_file_bytes=$pc.Length
                acl=$primaryAcl
            }
            backup=[ordered]@{
                path=$BackupPath
                dpapi_scope='LocalMachine'
                encrypted_file_sha256=Get-Sha256Hex $bc
                encrypted_file_bytes=$bc.Length
                acl=$backupAcl
            }
            seed_generation_count=1
            seed_regenerated=$false
            seed_regeneration_allowed=$false
            raw_seed_persisted_plaintext=$false
            raw_seed_logged=$false
            raw_seed_emitted=$false
            fixture_generation_performed=$false
            scientific_execution_performed=$false
            created_utc=[DateTime]::UtcNow.ToString('o')
        }

        Write-NewUtf8 $OutputReceiptPath (($receipt|ConvertTo-Json -Depth 14 -Compress)+"`n")
        $receiptSha=Get-FileSha256Hex $OutputReceiptPath
        $verify=Get-Content -LiteralPath $OutputReceiptPath -Raw|ConvertFrom-Json

        Require-Condition ($verify.study_id -eq $StudyId) 'D4W_PROTOCOL_FINAL_STUDY'
        Require-Condition ([bool]$verify.encrypted_dual_custody -and [bool]$verify.independent_storage) 'D4W_PROTOCOL_FINAL_DUAL'
        Require-Condition ($verify.primary_custody_replay -eq 'PASS' -and $verify.backup_custody_replay -eq 'PASS' -and $verify.custody_commitment_equality -eq 'PASS') 'D4W_PROTOCOL_FINAL_REPLAY'
        Require-Condition ($verify.master_seed_commitment_sha256 -eq $ExpectedCommitmentLocal) 'D4W_PROTOCOL_FINAL_COMMITMENT'
        Require-Condition (-not [bool]$verify.seed_regenerated -and -not [bool]$verify.fixture_generation_performed -and -not [bool]$verify.scientific_execution_performed) 'D4W_PROTOCOL_FINAL_BOUNDARY'

        Write-Output 'D4W_PROTOCOL_BINDING_STATUS=PASS'
        Write-Output ('D4W_MASTER_SEED_COMMITMENT_SHA256='+$ExpectedCommitmentLocal)
        Write-Output ('D4W_PROTOCOL_BINDING_RECEIPT_PATH='+$OutputReceiptPath)
        Write-Output ('D4W_PROTOCOL_BINDING_RECEIPT_SHA256='+$receiptSha)
        Write-Output 'D4W_PRIMARY_CUSTODY_REPLAY=PASS'
        Write-Output 'D4W_BACKUP_CUSTODY_REPLAY=PASS'
        Write-Output 'D4W_CUSTODY_COMMITMENT_EQUALITY=PASS'
        Write-Output 'D4W_SEED_REGENERATED=NO'
        Write-Output 'D4W_FIXTURE_GENERATION_PERFORMED=NO'
        Write-Output 'D4W_SCIENTIFIC_EXECUTION_PERFORMED=NO'
    }finally{
        foreach($x in @($pc,$bc,$p,$b)){
            if($null -ne $x -and $x -is [byte[]] -and $x.Length -gt 0){[Array]::Clear($x,0,$x.Length)}
        }
    }
}

Add-Type -AssemblyName System.Security.Cryptography.ProtectedData

if($SelfTest -or $env:D4W_PROTOCOL_BINDING_SELFTEST -eq '1'){
    $root=Join-Path $env:TEMP ('d4w_protocol_bind_'+[Guid]::NewGuid().ToString('N'))
    $primary=Join-Path $root 'primary\primary.dpapi'
    $backup=Join-Path $root 'backup\backup.dpapi'
    $evidence=Join-Path $root 'evidence'
    $crPath=Join-Path $evidence 'custody.json'
    $outPath=Join-Path $evidence 'binding.json'
    [IO.Directory]::CreateDirectory((Split-Path -Parent $primary))|Out-Null
    [IO.Directory]::CreateDirectory((Split-Path -Parent $backup))|Out-Null
    [IO.Directory]::CreateDirectory($evidence)|Out-Null
    $seed=[byte[]](0..31)
    $pc=$null
    $bc=$null
    try{
        $commit=Get-Sha256Hex $seed
        $pc=Protect-Bytes $seed $PrimaryEntropyText ([Security.Cryptography.DataProtectionScope]::CurrentUser)
        $bc=Protect-Bytes $seed $BackupEntropyText ([Security.Cryptography.DataProtectionScope]::LocalMachine)
        Write-NewBytes $primary $pc
        Write-NewBytes $backup $bc
        Set-TestAcl (Split-Path -Parent $primary) $true
        Set-TestAcl (Split-Path -Parent $backup) $true
        Set-TestAcl $evidence $true
        Set-TestAcl $primary $false
        Set-TestAcl $backup $false

        $cr=[ordered]@{
            schema='D4W_MASTER_SEED_CUSTODY_PROTOCOL_RECEIPT_v1'
            study_id=$StudyId
            checkpoint='D4W_MASTER_SEED_AND_DUAL_CUSTODY'
            status='PASS'
            encrypted_dual_custody=$true
            independent_storage=$true
            primary_custody_replay='PASS'
            backup_custody_replay='PASS'
            custody_commitment_equality='PASS'
            master_seed_commitment_sha256=$commit
            freeze_bundle_sha256=$ExpectedFreezeBundleSha256
            smoke_verification_sha256=$ExpectedSmokeVerificationSha256
            smoke_receipt_sha256=$ExpectedSmokeReceiptSha256
            smoke_contract_sha256=$ExpectedSmokeContractSha256
            seed_generation_count=1
            seed_regeneration_allowed=$false
            primary=[ordered]@{path=$primary;encrypted_file_sha256=Get-FileSha256Hex $primary}
            backup=[ordered]@{path=$backup;encrypted_file_sha256=Get-FileSha256Hex $backup}
            raw_seed_persisted_plaintext=$false
            raw_seed_logged=$false
            raw_seed_emitted=$false
            fixture_generation_performed=$false
            scientific_execution_performed=$false
            test_only=$false
        }
        Write-NewUtf8 $crPath (($cr|ConvertTo-Json -Depth 12 -Compress)+"`n")
        $crSha=Get-FileSha256Hex $crPath
        Invoke-ProtocolBinding $primary $backup $crPath $outPath $commit $crSha $false
        $vr=Get-Content -LiteralPath $outPath -Raw|ConvertFrom-Json
        Require-Condition ($vr.master_seed_commitment_sha256 -eq $commit) 'D4W_PROTOCOL_SELFTEST_COMMITMENT'
        Require-Condition (-not [bool]$vr.seed_regenerated) 'D4W_PROTOCOL_SELFTEST_REGEN'
        Write-Output 'D4W_PROTOCOL_BINDING_WINDOWS_SELFTEST=PASS'
        Write-Output 'D4W_PROTOCOL_BINDING_NO_SEED_REGENERATION_SELFTEST=PASS'
    }finally{
        foreach($x in @($seed,$pc,$bc)){if($null -ne $x -and $x -is [byte[]] -and $x.Length -gt 0){[Array]::Clear($x,0,$x.Length)}}
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
    exit 0
}

$PrimaryPath='C:\Users\Admin\AppData\Local\STOIXLAB\VCFE\secrets\c1c2_d4w\C1C2_D4W_MASTER_SEED.primary.dpapi'
$BackupPath='E:\STOIXLAB_SECRET_BACKUP\VCFE\c1c2_d4w\C1C2_D4W_MASTER_SEED.backup.dpapi'
$EvidenceDir='C:\Users\Admin\AppData\Local\STOIXLAB\VCFE\evidence\c1c2_d4w'
$CustodyReceiptPath=Join-Path $EvidenceDir 'D4W_MASTER_SEED_CUSTODY_PROTOCOL_RECEIPT_FROZEN.json'
$OutputReceiptPath=Join-Path $EvidenceDir 'D4W_MASTER_SEED_PROTOCOL_BINDING_RECEIPT_FROZEN.json'

try{
    Invoke-ProtocolBinding $PrimaryPath $BackupPath $CustodyReceiptPath $OutputReceiptPath $ExpectedCommitment $ExpectedCustodyReceiptSha256 $true
    exit 0
}catch{
    Write-Output 'D4W_PROTOCOL_BINDING_STATUS=FAIL'
    Write-Output ('D4W_MASTER_SEED_COMMITMENT_SHA256='+$ExpectedCommitment)
    Write-Output 'D4W_SEED_REGENERATION_ALLOWED=NO'
    Write-Output ('D4W_PROTOCOL_BINDING_ERROR='+$_.Exception.Message)
    exit 2
}
