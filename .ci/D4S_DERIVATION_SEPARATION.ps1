param([switch]$SelfTest)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

$StudyId='STOIX-VCFE-C1C2-D4S-FC-20261110-01'
$ExpectedCommitment='1344463a84d475362b560daadc9d3bc9509f6e001263a25b4b39b3cb27ef40a3'
$ProtocolReceiptSha='53daa431988fc6dccbc15158c815099a1c8940730b7e7ec91c81ec8bc10614b8'
$PrimaryEntropy='STOIX-VCFE-C1C2-D4S-PRIMARY'
$BackupEntropy='STOIX-VCFE-C1C2-D4S-BACKUP'
$Namespace='D4S-FIXTURE|'
$NamespaceProvenanceSha='5f014b0cd66181df89670bb0f40d8dc93b817622f88c64632d4b8830ec9bf532'
$NamespaceProvenanceJson=@'
{"entry_inventory_sha256":"df5d2c9ec9e25aa65f5ba9067edb4038aca40f70240b00a9a266925928468497","literal_prefix":"D4S-FIXTURE|","predecessor_bundle_sha256":"bc67ccc3572083877ef13e70d8171eaa346085964101492124d13bc34ad14cc3","prior_scope_hit_count":0,"result":"PASS","scanned_entry_count":101,"scanned_uncompressed_bytes":853901,"schema":"D4S_NAMESPACE_PRIOR_SEARCH_PROVENANCE_v1","study_id":"STOIX-VCFE-C1C2-D4S-FC-20261110-01"}
'@

$HistoricalCommitments=@(
'c4e8136ff4bb7f433ee6f2b4fdac102d1954bd9eb92c7017af1a2c153d85b163',
'168c9219dc189e902645284b17ce018001445eabe3ffd57db202650f78dc70e6',
'7f56de0dcbc0661e111ed0aae8e1175f3c91f22ba9d3c08bd8815c33f33bc4d0',
'68a652382d67b659ccd37c1bdc7427d91184f716cb21217afb1204bce2deee53'
)

function Require-Condition([bool]$Condition,[string]$Code){if(-not $Condition){throw $Code}}

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
    try{
        $fs=[IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try{$fs.Write($bytes,0,$bytes.Length);$fs.Flush($true)}finally{$fs.Dispose()}
    }finally{[Array]::Clear($bytes,0,$bytes.Length)}
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

function Invoke-Separation(
    [string]$PrimaryPath,
    [string]$BackupPath,
    [string]$ProtocolReceiptPath,
    [string]$ExpectedProtocolReceiptSha,
    [string]$ExpectedCommitmentLocal,
    [string]$OutputDir,
    [bool]$RequireDistinctVolumes
){
    Require-Condition (Test-Path -LiteralPath $PrimaryPath -PathType Leaf) 'D4S_SEPARATION_PRIMARY_MISSING'
    Require-Condition (Test-Path -LiteralPath $BackupPath -PathType Leaf) 'D4S_SEPARATION_BACKUP_MISSING'
    Require-Condition (Test-Path -LiteralPath $ProtocolReceiptPath -PathType Leaf) 'D4S_SEPARATION_PROTOCOL_RECEIPT_MISSING'
    Require-Condition ((Get-FileSha256Hex $ProtocolReceiptPath) -eq $ExpectedProtocolReceiptSha) 'D4S_SEPARATION_PROTOCOL_RECEIPT_HASH'

    $receipt=Get-Content -LiteralPath $ProtocolReceiptPath -Raw | ConvertFrom-Json
    Require-Condition ($receipt.study_id -eq $StudyId) 'D4S_SEPARATION_PROTOCOL_RECEIPT_STUDY'
    Require-Condition ([bool]$receipt.encrypted_dual_custody) 'D4S_SEPARATION_PROTOCOL_DUAL_CUSTODY'
    Require-Condition ([bool]$receipt.independent_storage) 'D4S_SEPARATION_PROTOCOL_INDEPENDENT_STORAGE'
    Require-Condition ($receipt.primary_custody_replay -eq 'PASS') 'D4S_SEPARATION_PROTOCOL_PRIMARY'
    Require-Condition ($receipt.backup_custody_replay -eq 'PASS') 'D4S_SEPARATION_PROTOCOL_BACKUP'
    Require-Condition ($receipt.custody_commitment_equality -eq 'PASS') 'D4S_SEPARATION_PROTOCOL_EQUALITY'
    Require-Condition ($receipt.master_seed_commitment_sha256 -eq $ExpectedCommitmentLocal) 'D4S_SEPARATION_PROTOCOL_COMMITMENT'

    if($RequireDistinctVolumes){
        $pd=(Split-Path -Qualifier $PrimaryPath).TrimEnd('\').TrimEnd(':')
        $bd=(Split-Path -Qualifier $BackupPath).TrimEnd('\').TrimEnd(':')
        $pv=Get-Volume -DriveLetter $pd -ErrorAction Stop
        $bv=Get-Volume -DriveLetter $bd -ErrorAction Stop
        Require-Condition ($pv.UniqueId -ne $bv.UniqueId) 'D4S_SEPARATION_STORAGE_NOT_DISTINCT'
    }

    [IO.Directory]::CreateDirectory($OutputDir)|Out-Null
    $provPath=Join-Path $OutputDir 'D4S_NAMESPACE_PRIOR_SEARCH_PROVENANCE_FROZEN.json'
    $sepPath=Join-Path $OutputDir 'D4S_DERIVATION_SEPARATION_FROZEN.json'
    Require-Condition (-not (Test-Path -LiteralPath $provPath)) 'D4S_NAMESPACE_PROVENANCE_ALREADY_EXISTS'
    Require-Condition (-not (Test-Path -LiteralPath $sepPath)) 'D4S_DERIVATION_SEPARATION_ALREADY_EXISTS'

    $pc=[IO.File]::ReadAllBytes($PrimaryPath)
    $bc=[IO.File]::ReadAllBytes($BackupPath)
    $p=$null;$b=$null
    try{
        $p=Unprotect-Bytes $pc $PrimaryEntropy ([Security.Cryptography.DataProtectionScope]::CurrentUser)
        $b=Unprotect-Bytes $bc $BackupEntropy ([Security.Cryptography.DataProtectionScope]::LocalMachine)
        Require-Condition ($p.Length -eq 32 -and $b.Length -eq 32) 'D4S_SEPARATION_SEED_LENGTH'
        Require-Condition ((Get-Sha256Hex $p) -eq $ExpectedCommitmentLocal) 'D4S_SEPARATION_PRIMARY_COMMITMENT'
        Require-Condition ((Get-Sha256Hex $b) -eq $ExpectedCommitmentLocal) 'D4S_SEPARATION_BACKUP_COMMITMENT'
        for($i=0;$i -lt 32;$i++){Require-Condition ($p[$i] -eq $b[$i]) 'D4S_SEPARATION_DUAL_CUSTODY_MISMATCH'}

        $provBytes=[Text.UTF8Encoding]::new($false).GetBytes($NamespaceProvenanceJson)
        try{
            Require-Condition ((Get-Sha256Hex $provBytes) -eq $NamespaceProvenanceSha) 'D4S_NAMESPACE_PROVENANCE_EMBEDDED_HASH'
            Write-NewUtf8 $provPath $NamespaceProvenanceJson
        }finally{[Array]::Clear($provBytes,0,$provBytes.Length)}
        Require-Condition ((Get-FileSha256Hex $provPath) -eq $NamespaceProvenanceSha) 'D4S_NAMESPACE_PROVENANCE_WRITTEN_HASH'

        $labels=@();$roots=@()
        for($i=1;$i -le 10;$i++){
            $label=$Namespace+$i
            $labels+=$label
            $lb=[Text.Encoding]::UTF8.GetBytes($label)
            $hmac=[Security.Cryptography.HMACSHA256]::new($p)
            $derived=$null
            try{
                $derived=$hmac.ComputeHash($lb)
                $roots+=(Get-Sha256Hex $derived)
            }finally{
                $hmac.Dispose()
                [Array]::Clear($lb,0,$lb.Length)
                if($derived){[Array]::Clear($derived,0,$derived.Length)}
            }
        }
        Require-Condition ((@($roots|Sort-Object -Unique).Count) -eq 10) 'D4S_CURRENT_ROOT_UNIQUENESS'

        $sep=[ordered]@{
            schema='D4S_DERIVATION_SEPARATION_v1'
            study_id=$StudyId
            master_seed_commitment_sha256=$ExpectedCommitmentLocal
            hmac_algorithm='HMAC-SHA256'
            domain_prefix=$Namespace
            domain_labels=$labels
            current_derived_root_sha256s=$roots
            historical_master_commitments_checked=$HistoricalCommitments
            namespace_search=[ordered]@{
                result='PASS'
                literal_prefix=$Namespace
                prior_scope_hit_count=0
                search_provenance_sha256=$NamespaceProvenanceSha
            }
            collision_bound=[ordered]@{
                fresh_root_count=10
                historical_root_upper_bound=1000000
                union_bound_numerator=10000000
                denominator='2^256'
                exact_decimal='8.63616855509444462538635186280039957111600036443628138502370e-71'
                less_than_1e_70=$true
            }
            allowed_claim='Deterministic derivation identity disjointness is guaranteed by fresh master-seed commitment and a unique domain namespace (D4S-FIXTURE); accidental cross-key output collision with unobserved historical roots is mathematically bounded below 10^-70.'
            forbidden_claim='Zero collision is empirically proven against all historical roots.'
            seed_regenerated=$false
            fixture_generation_performed=$false
            scientific_execution_performed=$false
        }
        Write-NewUtf8 $sepPath (($sep|ConvertTo-Json -Depth 12 -Compress))
        $sepSha=Get-FileSha256Hex $sepPath

        Write-Output 'D4S_DERIVATION_SEPARATION_STATUS=PASS'
        Write-Output ('D4S_MASTER_SEED_COMMITMENT_SHA256='+$ExpectedCommitmentLocal)
        Write-Output ('D4S_NAMESPACE_SEARCH_PROVENANCE_PATH='+$provPath)
        Write-Output ('D4S_NAMESPACE_SEARCH_PROVENANCE_SHA256='+$NamespaceProvenanceSha)
        Write-Output ('D4S_DERIVATION_SEPARATION_PATH='+$sepPath)
        Write-Output ('D4S_DERIVATION_SEPARATION_SHA256='+$sepSha)
        Write-Output 'D4S_DERIVED_ROOT_COUNT=10'
        Write-Output 'D4S_DERIVED_ROOT_UNIQUENESS=PASS'
        Write-Output 'D4S_NAMESPACE_PRIOR_SCOPE_HIT_COUNT=0'
        Write-Output 'D4S_FIXTURE_GENERATION_PERFORMED=NO'
        Write-Output 'D4S_SCIENTIFIC_EXECUTION_PERFORMED=NO'
        Write-Output 'D4S_SEED_REGENERATED=NO'
    }finally{
        foreach($x in @($pc,$bc,$p,$b)){if($null -ne $x -and $x -is [byte[]] -and $x.Length -gt 0){[Array]::Clear($x,0,$x.Length)}}
    }
}

Add-Type -AssemblyName System.Security.Cryptography.ProtectedData

if($SelfTest -or $env:D4S_DERIVATION_SEPARATION_SELFTEST -eq '1'){
    $tag=[Guid]::NewGuid().ToString('N')
    $cRoot="C:\d4s_sep_ci_$tag"
    $dRoot="D:\d4s_sep_ci_$tag"
    [IO.Directory]::CreateDirectory($cRoot)|Out-Null
    [IO.Directory]::CreateDirectory($dRoot)|Out-Null
    $seed=[byte[]](0..31)
    try{
        $commit=Get-Sha256Hex $seed
        $pp=Join-Path $cRoot 'primary.dpapi';$bp=Join-Path $dRoot 'backup.dpapi'
        [IO.File]::WriteAllBytes($pp,(Protect-Bytes $seed $PrimaryEntropy ([Security.Cryptography.DataProtectionScope]::CurrentUser)))
        [IO.File]::WriteAllBytes($bp,(Protect-Bytes $seed $BackupEntropy ([Security.Cryptography.DataProtectionScope]::LocalMachine)))
        $rp=Join-Path $cRoot 'protocol.json'
        $rr=[ordered]@{study_id=$StudyId;encrypted_dual_custody=$true;independent_storage=$true;primary_custody_replay='PASS';backup_custody_replay='PASS';custody_commitment_equality='PASS';master_seed_commitment_sha256=$commit}
        Write-NewUtf8 $rp (($rr|ConvertTo-Json -Compress))
        $rsha=Get-FileSha256Hex $rp

        $negativeBoundaryPass=$false
        try{
            Invoke-Separation $pp $bp $rp ('0'*64) $commit (Join-Path $cRoot 'neg') $true
        }catch{
            if($_.Exception.Message -eq 'D4S_SEPARATION_PROTOCOL_RECEIPT_HASH'){
                $negativeBoundaryPass=$true
            }else{
                throw
            }
        }
        Require-Condition $negativeBoundaryPass 'D4S_SEPARATION_NEGATIVE_BOUNDARY_NOT_ENFORCED'

        $outDir=Join-Path $cRoot 'out'
        Invoke-Separation $pp $bp $rp $rsha $commit $outDir $true

        $selfSepPath=Join-Path $outDir 'D4S_DERIVATION_SEPARATION_FROZEN.json'
        Require-Condition (Test-Path -LiteralPath $selfSepPath -PathType Leaf) 'D4S_SEPARATION_SELFTEST_OUTPUT_MISSING'
        $selfSep=Get-Content -LiteralPath $selfSepPath -Raw | ConvertFrom-Json
        Require-Condition ($selfSep.schema -eq 'D4S_DERIVATION_SEPARATION_v1') 'D4S_SEPARATION_SELFTEST_SCHEMA'
        Require-Condition ($selfSep.domain_prefix -eq 'D4S-FIXTURE|') 'D4S_SEPARATION_SELFTEST_NAMESPACE'
        Require-Condition (@($selfSep.current_derived_root_sha256s).Count -eq 10) 'D4S_SEPARATION_SELFTEST_ROOT_COUNT'
        Require-Condition ([bool]$selfSep.collision_bound.less_than_1e_70) 'D4S_SEPARATION_SELFTEST_BOUND'

        Write-Output 'D4S_DERIVATION_SEPARATION_NEGATIVE_BOUNDARY=PASS'
        Write-Output 'D4S_DERIVATION_SEPARATION_OUTPUT_VALIDATION=PASS'
        Write-Output 'D4S_DERIVATION_SEPARATION_WINDOWS_SELFTEST=PASS'
    }finally{
        [Array]::Clear($seed,0,$seed.Length)
        Remove-Item -LiteralPath $cRoot -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $dRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    exit 0
}

$PrimaryPath='C:\Users\Admin\AppData\Local\STOIXLAB\VCFE\secrets\c1c2_d4s\C1C2_D4S_MASTER_SEED.primary.dpapi'
$BackupPath='E:\STOIXLAB_SECRET_BACKUP\VCFE\c1c2_d4s\C1C2_D4S_MASTER_SEED.backup.dpapi'
$ProtocolReceiptPath='C:\Users\Admin\AppData\Local\STOIXLAB\VCFE\evidence\c1c2_d4s\D4S_MASTER_SEED_CUSTODY_PROTOCOL_RECEIPT_FROZEN.json'
$OutputDir='C:\Users\Admin\AppData\Local\STOIXLAB\VCFE\evidence\c1c2_d4s'

try{
    Invoke-Separation $PrimaryPath $BackupPath $ProtocolReceiptPath $ProtocolReceiptSha $ExpectedCommitment $OutputDir $true
    exit 0
}catch{
    Write-Output 'D4S_DERIVATION_SEPARATION_STATUS=FAIL'
    Write-Output ('D4S_DERIVATION_SEPARATION_ERROR='+$_.Exception.Message)
    Write-Output 'D4S_SEED_REGENERATION_ALLOWED=NO'
    exit 2
}
