param([switch]$SelfTest)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

$StudyId='STOIX-VCFE-C1C2-D4T-FC-20261110-01'
$BundleSha='9bfae179671ad17170357b84683e6ff2d11a1428b440c1685f23ead50c118a7b'
$AuthorizationSha='3d154420fd58eb57b508e9651277e7dc48d9f80195d4463548fdb60d7ddafc44'
$CustodyReceiptSha='67e266f483ad75b622b16259c924225cc23591a30e80aea8e8ac0690f270671a'
$SeparationReceiptSha='b86d1eef280b19ff77f38bd9a90c74847fe1b913949eb875759966c118c8e43f'
$PreflightPythonSha='bbc23cd9b361c42ed63b064eff63051c4efbdebcd1f04c94db83ad492d341d7f'
$BridgePythonSha='93b2520ba65fbcccdec41da02ce56c51aed95b26a16b4d14be0ba3a574fc7448'
$RuntimeImage='sha256:de727f8cdd1e2fcb9cb80d3444b95839af7e76302ca9778520a7243ebe6577ba'

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

function Test-FrozenInventory([string]$Root){
    $inventoryPath=Join-Path $Root 'STOIX_VCFE_C1C2_D4T_IMPLEMENTATION_SOURCE_INVENTORY_FROZEN.json'
    Require-Condition (Test-Path -LiteralPath $inventoryPath -PathType Leaf) 'D4T_PREFLIGHT_INVENTORY_MISSING'
    $inventory=Get-Content -LiteralPath $inventoryPath -Raw|ConvertFrom-Json
    Require-Condition ($inventory.study_id -eq $StudyId -and $inventory.file_count -eq 93) 'D4T_PREFLIGHT_INVENTORY_IDENTITY'
    [int]$count=0
    foreach($row in $inventory.files){
        $path=Join-Path $Root ([string]$row.path)
        Require-Condition (Test-Path -LiteralPath $path -PathType Leaf) "D4T_PREFLIGHT_FROZEN_FILE_MISSING::$($row.path)"
        $item=Get-Item -LiteralPath $path
        Require-Condition ($item.Length -eq [int64]$row.bytes) "D4T_PREFLIGHT_FROZEN_FILE_BYTES::$($row.path)"
        Require-Condition ((Get-FileSha256Hex $path) -eq [string]$row.sha256) "D4T_PREFLIGHT_FROZEN_FILE_HASH::$($row.path)"
        $count++
    }
    Require-Condition ($count -eq 93) 'D4T_PREFLIGHT_INVENTORY_COUNT'
}

function Get-DockerArgList([string]$Root,[string]$Inputs,[string]$PythonScript){
    $dockerArgList=[Collections.Generic.List[string]]::new()
    foreach($x in @(
        'run','--rm',
        '--network=none',
        '--read-only',
        '--cap-drop=ALL',
        '--security-opt=no-new-privileges',
        '--env','PYTHONDONTWRITEBYTECODE=1',
        '--tmpfs','/tmp:rw,exec,nosuid,size=1073741824',
        '--mount',"type=bind,source=$Root,target=/out,readonly",
        '--mount',"type=bind,source=$Inputs,target=/inputs,readonly"
    )){[void]$dockerArgList.Add($x)}
    foreach($cap in @('SYS_CHROOT','SETUID','SETGID','CHOWN','DAC_OVERRIDE','FOWNER')){
        [void]$dockerArgList.Add('--cap-add')
        [void]$dockerArgList.Add($cap)
    }
    foreach($x in @('--entrypoint','/opt/pyvenv/bin/python',$RuntimeImage,'-B',$PythonScript)){
        [void]$dockerArgList.Add($x)
    }
    return [string[]]$dockerArgList.ToArray()
}

function Invoke-DockerCapture([string[]]$DockerArgList){
    Require-Condition ($null -ne $DockerArgList -and $DockerArgList.Count -ge 20) 'D4T_DOCKER_ARG_LIST_EMPTY_OR_SHORT'
    Require-Condition ($DockerArgList[0] -eq 'run') 'D4T_DOCKER_ARG_LIST_NO_RUN'
    Require-Condition ($DockerArgList -contains '--network=none') 'D4T_DOCKER_ARG_LIST_NO_NETWORK_NONE'
    Require-Condition ($DockerArgList -contains '--read-only') 'D4T_DOCKER_ARG_LIST_NO_READ_ONLY'
    Require-Condition ($DockerArgList -contains $RuntimeImage) 'D4T_DOCKER_ARG_LIST_NO_RUNTIME_IMAGE'

    $psi=[Diagnostics.ProcessStartInfo]::new()
    $dockerExe=if($env:D4T_DOCKER_EXE_OVERRIDE){$env:D4T_DOCKER_EXE_OVERRIDE}else{'docker'}
    $psi.FileName=$dockerExe
    $psi.UseShellExecute=$false
    $psi.RedirectStandardInput=$true
    $psi.RedirectStandardOutput=$true
    $psi.RedirectStandardError=$true
    if($env:D4T_DOCKER_PREFIX_JSON){
        $prefixArgs=@($env:D4T_DOCKER_PREFIX_JSON|ConvertFrom-Json)
        foreach($prefixArg in $prefixArgs){[void]$psi.ArgumentList.Add([string]$prefixArg)}
    }
    foreach($dockerArg in $DockerArgList){[void]$psi.ArgumentList.Add($dockerArg)}
    foreach($name in @('OPENAI_API_KEY','VCFE_MASTER_SEED_HEX','D3_MASTER_SEED_HEX','C1C2_MASTER_SEED_HEX')){
        $psi.Environment.Remove($name)|Out-Null
    }

    $proc=[Diagnostics.Process]::Start($psi)
    try{
        $stdoutTask=$proc.StandardOutput.ReadToEndAsync()
        $stderrTask=$proc.StandardError.ReadToEndAsync()
        $proc.StandardInput.Close()
        $proc.WaitForExit()
        return [pscustomobject]@{
            ExitCode=$proc.ExitCode
            StdOut=$stdoutTask.GetAwaiter().GetResult()
            StdErr=$stderrTask.GetAwaiter().GetResult()
            ArgumentCount=$DockerArgList.Count
        }
    }finally{$proc.Dispose()}
}

function Require-PreflightMarkers([object]$Result){
    Require-Condition ($Result.ExitCode -eq 0) "D4T_LINUX_PREFLIGHT_EXIT::$($Result.ExitCode)"
    foreach($marker in @(
        'D4T_LINUX_PREFLIGHT_STATUS=PASS',
        'D4T_LINUX_PREFLIGHT_PYTHON=3.12',
        'D4T_LINUX_PREFLIGHT_PARENT_ARCHIVE_PATH=PASS',
        'D4T_LINUX_PREFLIGHT_SYNTHETIC_EVALUATOR_CALLS=3',
        'D4T_LINUX_PREFLIGHT_MODEL_CALLS=0',
        'D4T_LINUX_PREFLIGHT_SCIENTIFIC_EXECUTIONS=0'
    )){
        Require-Condition (([string]$Result.StdOut).Contains($marker)) "D4T_LINUX_PREFLIGHT_MISSING_MARKER::$marker"
    }
}

function Get-DockerImageIdentity(){
    $psi=[Diagnostics.ProcessStartInfo]::new()
    $psi.FileName='docker'
    $psi.UseShellExecute=$false
    $psi.RedirectStandardOutput=$true
    $psi.RedirectStandardError=$true
    foreach($a in @('image','inspect','--format','{{.Id}} {{.Os}} {{.Architecture}}',$RuntimeImage)){
        [void]$psi.ArgumentList.Add($a)
    }
    $p=[Diagnostics.Process]::Start($psi)
    try{
        $o=$p.StandardOutput.ReadToEnd()
        $e=$p.StandardError.ReadToEnd()
        $p.WaitForExit()
        Require-Condition ($p.ExitCode -eq 0) ('D4T_RUNTIME_IMAGE_UNAVAILABLE::'+$e.Trim())
        return $o.Trim()
    }finally{$p.Dispose()}
}

if($SelfTest -or $env:D4T_PQ_PREFLIGHT_SELFTEST -eq '1'){
    $tmp=Join-Path $env:TEMP ('d4t_pq_preflight_ci_'+[Guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($tmp)|Out-Null
    $fake=Join-Path $tmp 'fake-docker.cmd'
    $oldOverride=$env:D4T_DOCKER_EXE_OVERRIDE
    $oldPrefix=$env:D4T_DOCKER_PREFIX_JSON
    try{
        $fakeText=@'
@echo off
echo FAKE_DOCKER_ARGS=%*
echo D4T_LINUX_PREFLIGHT_STATUS=PASS
echo D4T_LINUX_PREFLIGHT_PYTHON=3.12
echo D4T_LINUX_PREFLIGHT_PARENT_ARCHIVE_PATH=PASS
echo D4T_LINUX_PREFLIGHT_SYNTHETIC_EVALUATOR_CALLS=3
echo D4T_LINUX_PREFLIGHT_MODEL_CALLS=0
echo D4T_LINUX_PREFLIGHT_SCIENTIFIC_EXECUTIONS=0
exit /b 0
'@
        [IO.File]::WriteAllText($fake,$fakeText,[Text.Encoding]::ASCII)
        $env:D4T_DOCKER_EXE_OVERRIDE=(Get-Command cmd.exe -ErrorAction Stop).Source
        $env:D4T_DOCKER_PREFIX_JSON=(@('/d','/s','/c',$fake)|ConvertTo-Json -Compress)

        $dockerArgList=Get-DockerArgList 'C:\fake-root' 'C:\fake-inputs' '/inputs/D4T_LINUX_PREFLIGHT_FROZEN.py'
        Require-Condition ($dockerArgList.Count -ge 20) 'D4T_SELFTEST_ARG_COUNT'
        Require-Condition ($dockerArgList[0] -eq 'run') 'D4T_SELFTEST_ARG0'
        $result=Invoke-DockerCapture $dockerArgList
        Require-PreflightMarkers $result
        Require-Condition (([string]$result.StdOut).Contains('FAKE_DOCKER_ARGS=run --rm')) 'D4T_SELFTEST_ARGUMENT_TRANSPORT'
        Require-Condition (([string]$result.StdOut).Contains('--network=none')) 'D4T_SELFTEST_NETWORK_NONE_TRANSPORT'
        Require-Condition (([string]$result.StdOut).Contains($RuntimeImage)) 'D4T_SELFTEST_RUNTIME_IMAGE_TRANSPORT'
        Write-Output ('D4T_PQ_PREFLIGHT_SELFTEST_ARGUMENT_COUNT='+$result.ArgumentCount)
        Write-Output 'D4T_PQ_PREFLIGHT_SELFTEST_ARGUMENT_TRANSPORT=PASS'
        Write-Output 'D4T_PQ_PREFLIGHT_WINDOWS_SELFTEST=PASS'
    }finally{
        if($null -eq $oldOverride){Remove-Item Env:D4T_DOCKER_EXE_OVERRIDE -ErrorAction SilentlyContinue}
        else{$env:D4T_DOCKER_EXE_OVERRIDE=$oldOverride}
        if($null -eq $oldPrefix){Remove-Item Env:D4T_DOCKER_PREFIX_JSON -ErrorAction SilentlyContinue}
        else{$env:D4T_DOCKER_PREFIX_JSON=$oldPrefix}
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
    exit 0
}

$EvidenceDir='C:\Users\Admin\AppData\Local\STOIXLAB\VCFE\evidence\c1c2_d4t'
$RuntimeBase='C:\Users\Admin\AppData\Local\STOIXLAB\VCFE\runtime\c1c2_d4t\freeze_9bfae179'
$BundlePath=Join-Path $RuntimeBase 'C1C2_D4T_PREREGISTRATION_AND_IMPLEMENTATION_FREEZE_HANDOFF.zip'
$Root=Join-Path $RuntimeBase 'd4t_preregistration_implementation_freeze_v1'
$AuthorizationPath=Join-Path $EvidenceDir 'D4T_PREQUALIFY_AUTHORIZATION_FROZEN.json'
$CustodyPath=Join-Path $EvidenceDir 'D4T_MASTER_SEED_CUSTODY_PROTOCOL_RECEIPT_FROZEN.json'
$SeparationPath=Join-Path $EvidenceDir 'D4T_DERIVATION_SEPARATION_FROZEN.json'
$PreflightPath=Join-Path $EvidenceDir 'D4T_LINUX_PREFLIGHT_FROZEN.py'
$BridgePath=Join-Path $EvidenceDir 'D4T_PREQUALIFY_LINUX_BRIDGE_FROZEN.py'
$StartPath=Join-Path $EvidenceDir 'D4T_PREQUALIFICATION_STARTED.json'
$CanonicalReceiptPath=Join-Path $Root 'D4T_PREQUALIFICATION_RECEIPT_FROZEN.json'

try{
    Require-Condition (-not (Test-Path -LiteralPath $StartPath)) 'D4T_PREQUALIFICATION_ALREADY_STARTED'
    Require-Condition (-not (Test-Path -LiteralPath $CanonicalReceiptPath)) 'D4T_PREQUALIFICATION_RECEIPT_ALREADY_EXISTS'

    foreach($binding in @(
        @($BundlePath,$BundleSha,'BUNDLE'),
        @($AuthorizationPath,$AuthorizationSha,'AUTHORIZATION'),
        @($CustodyPath,$CustodyReceiptSha,'CUSTODY'),
        @($SeparationPath,$SeparationReceiptSha,'SEPARATION'),
        @($PreflightPath,$PreflightPythonSha,'PREFLIGHT_PYTHON'),
        @($BridgePath,$BridgePythonSha,'BRIDGE_PYTHON')
    )){
        Require-Condition (Test-Path -LiteralPath $binding[0] -PathType Leaf) "D4T_PREFLIGHT_INPUT_MISSING::$($binding[2])"
        Require-Condition ((Get-FileSha256Hex $binding[0]) -eq $binding[1]) "D4T_PREFLIGHT_INPUT_HASH::$($binding[2])"
    }
    Require-Condition (Test-Path -LiteralPath $Root -PathType Container) 'D4T_PREFLIGHT_RUNTIME_ROOT_MISSING'
    Test-FrozenInventory $Root

    $actualImage=Get-DockerImageIdentity
    Require-Condition ($actualImage -eq "$RuntimeImage linux amd64") ('D4T_RUNTIME_V2_IDENTITY::'+$actualImage)

    $dockerArgList=Get-DockerArgList $Root $EvidenceDir '/inputs/D4T_LINUX_PREFLIGHT_FROZEN.py'
    $result=Invoke-DockerCapture $dockerArgList

    if(-not [string]::IsNullOrWhiteSpace([string]$result.StdErr)){
        foreach($line in ([string]$result.StdErr -split "`r?`n")){
            if($line.Length -gt 0){Write-Output ('DOCKER_STDERR='+$line)}
        }
    }
    if(-not [string]::IsNullOrWhiteSpace([string]$result.StdOut)){
        foreach($line in ([string]$result.StdOut -split "`r?`n")){
            if($line.Length -gt 0){Write-Output $line}
        }
    }

    Require-PreflightMarkers $result
    Test-FrozenInventory $Root
    Require-Condition (-not (Test-Path -LiteralPath $StartPath)) 'D4T_PREFLIGHT_CREATED_START_MARKER'
    Require-Condition (-not (Test-Path -LiteralPath $CanonicalReceiptPath)) 'D4T_PREFLIGHT_CREATED_PREQUAL_RECEIPT'

    Write-Output 'D4T_PQ_PREFLIGHT_STATUS=PASS'
    Write-Output ('D4T_PQ_PREFLIGHT_DOCKER_ARGUMENT_COUNT='+$result.ArgumentCount)
    Write-Output 'D4T_PREQUALIFICATION_ONE_SHOT_CONSUMED=NO'
    Write-Output 'D4T_RAW_SEED_ACCESSED=NO'
    Write-Output 'D4T_FIXTURE_GENERATION_PERFORMED=NO'
    Write-Output 'D4T_SCIENTIFIC_EXECUTION_PERFORMED=NO'
    exit 0
}catch{
    Write-Output 'D4T_PQ_PREFLIGHT_STATUS=FAIL'
    Write-Output ('D4T_PQ_PREFLIGHT_ERROR='+$_.Exception.Message)
    Write-Output 'D4T_PREQUALIFICATION_ONE_SHOT_CONSUMED=NO'
    Write-Output 'D4T_RAW_SEED_ACCESSED=NO'
    exit 2
}
