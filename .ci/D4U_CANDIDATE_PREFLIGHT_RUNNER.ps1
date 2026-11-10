param([switch]$SelfTest)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$StudyId='STOIX-VCFE-C1C2-D4U-FC-20261110-01'
$CandidateZipSha='d7c29223180cbcba7ce4f3f51b399988e672ae47ce2ef5ed5198665571724266'
$RuntimeRef='python@sha256:5e2bdb1b0d542d5039cffb8181c65930093949194a65c365dfb1b0fe13a4fa5b'
$RuntimeProofImageId='sha256:78976a69c067520ef8be34cde307ef9f6fea6dcefa50edb57039773d241ca0db'
$RuntimeManifestDigest='sha256:5e2bdb1b0d542d5039cffb8181c65930093949194a65c365dfb1b0fe13a4fa5b'
$RunnerRevision='V2_MANIFEST_DIGEST_PORTABLE_IDENTITY'
$Helper=@'
import hashlib,json,os,sys
from pathlib import Path
ROOT=Path("/out").resolve()
sys.path.insert(0,str(ROOT))
import d4u_protocol as d
if sys.version_info[:2]!=(3,12): raise SystemExit("D4U_PREFLIGHT_PYTHON_3_12_REQUIRED")
if os.name!="posix" or not sys.platform.startswith("linux"): raise SystemExit("D4U_PREFLIGHT_LINUX_REQUIRED")
if "OPENAI_API_KEY" in os.environ: raise SystemExit("D4U_PREFLIGHT_SECRET_ENV_FORBIDDEN")
if not d.verify_inputs(): raise SystemExit("D4U_PREFLIGHT_VERIFY_INPUTS")
if not d.runtime_preflight(): raise SystemExit("D4U_PREFLIGHT_RUNTIME")
if not d.schema_neutrality(): raise SystemExit("D4U_PREFLIGHT_SCHEMA")
if len(d.schedule_check())!=30: raise SystemExit("D4U_PREFLIGHT_SCHEDULE")
master=d.synthetic_master(); count={"n":0}
try:
    prior={"derived_seed_sha256s":[hashlib.sha256(f"D4U-CANDIDATE-PRIOR-{i}".encode()).hexdigest() for i in range(1,33)]}
    def evaluator(task,source,candidate):
        count["n"]+=1
        if count["n"]%120==0: print(f"D4U_PREFLIGHT_PROGRESS={count['n']}/720",flush=True)
        return d.verifier.evaluate_one(task,source,candidate)
    receipt=ROOT/d.PREQUALIFICATION_NAME
    if receipt.exists(): raise SystemExit("D4U_PREFLIGHT_RECEIPT_ALREADY_EXISTS")
    gate=d.prequalify(master,receipt,prior,evaluator=evaluator)
    if count["n"]!=720: raise SystemExit(f"D4U_PREFLIGHT_EVALUATOR_COUNT::{count['n']}")
    gate.check()
    raw=receipt.read_bytes(); doc=json.loads(raw)
    if doc.get("status")!="PASS": raise SystemExit("D4U_PREFLIGHT_RECEIPT_STATUS")
    if doc.get("model_calls")!=0 or doc.get("scientific_executions")!=0: raise SystemExit("D4U_PREFLIGHT_ZERO_MODEL_BOUNDARY")
    rows=doc.get("geometry_results",[])
    if len(rows)!=10: raise SystemExit("D4U_PREFLIGHT_GEOMETRY_COUNT")
    if sum(bool(r.get("c1_alone_success")) for r in rows)!=0: raise SystemExit("D4U_PREFLIGHT_C1_ALONE")
    if sum(bool(r.get("inert_success")) for r in rows)>1: raise SystemExit("D4U_PREFLIGHT_INERT")
    if not all(r.get("reference_tasks_passed")==24 for r in rows): raise SystemExit("D4U_PREFLIGHT_REFERENCE")
    print("D4U_CANDIDATE_PREFLIGHT_STATUS=PASS")
    print("D4U_CANDIDATE_PREFLIGHT_PYTHON=3.12")
    print("D4U_CANDIDATE_PREFLIGHT_PARENT_ARCHIVE_PATH=PASS")
    print("D4U_CANDIDATE_PREFLIGHT_EVALUATOR_CALLS=720")
    print("D4U_CANDIDATE_PREFLIGHT_MODEL_CALLS=0")
    print("D4U_CANDIDATE_PREFLIGHT_SCIENTIFIC_EXECUTIONS=0")
    print("D4U_CANDIDATE_PREFLIGHT_RECEIPT_SHA256="+hashlib.sha256(raw).hexdigest())
finally:
    master.clear()
'@
$Helper+="`n"

function Require-Condition([bool]$Condition,[string]$Code){if(-not $Condition){throw $Code}}
function Get-FileSha256Hex([string]$Path){
    $b=[IO.File]::ReadAllBytes($Path); $sha=[Security.Cryptography.SHA256]::Create()
    try{return ([BitConverter]::ToString($sha.ComputeHash($b))).Replace('-','').ToLowerInvariant()}
    finally{$sha.Dispose();if($b){[Array]::Clear($b,0,$b.Length)}}
}

function Assert-RuntimeMetadata([object]$Image){
    $id=[string]$Image.Id
    $os=[string]$Image.Os
    $arch=[string]$Image.Architecture
    $digests=@($Image.RepoDigests|ForEach-Object{"$_"})
    Require-Condition ($os -eq 'linux' -and $arch -eq 'amd64') "D4U_RUNTIME_PLATFORM_FAIL::$os::$arch"
    Require-Condition ((@($digests|Where-Object{$_ -eq "python@$RuntimeManifestDigest"}).Count) -gt 0) 'D4U_RUNTIME_MANIFEST_DIGEST_FAIL'
    Write-Output ('D4U_RUNTIME_LOCAL_IMAGE_ID='+$id)
    Write-Output ('D4U_RUNTIME_MANIFEST_DIGEST='+$RuntimeManifestDigest)
    Write-Output ('D4U_RUNTIME_PROOF_IMAGE_ID_MATCH='+$(if($id -eq $RuntimeProofImageId){'PASS'}else{'INFO_MISMATCH_ALLOWED'}))
    Write-Output 'D4U_RUNTIME_MANIFEST_DIGEST_MATCH=PASS'
    Write-Output 'D4U_RUNTIME_PLATFORM_MATCH=PASS'
}

function Assert-RuntimePython([string[]]$Lines){
    $text=$Lines -join "`n"
    Require-Condition (($text -split "`n") -contains 'D4U_RUNTIME_PYTHON_MAJOR_MINOR=3.12') 'D4U_RUNTIME_PYTHON_3_12_FAIL'
    Require-Condition (($text -split "`n") -contains 'D4U_RUNTIME_PLATFORM=linux') 'D4U_RUNTIME_PYTHON_PLATFORM_FAIL'
    Require-Condition (($text -split "`n") -contains 'D4U_RUNTIME_OS_NAME=posix') 'D4U_RUNTIME_PYTHON_OS_FAIL'
}

function Assert-Markers([string[]]$Lines){
    $text=$Lines -join "`n"
    foreach($m in @(
        'D4U_CANDIDATE_PREFLIGHT_STATUS=PASS',
        'D4U_CANDIDATE_PREFLIGHT_PYTHON=3.12',
        'D4U_CANDIDATE_PREFLIGHT_PARENT_ARCHIVE_PATH=PASS',
        'D4U_CANDIDATE_PREFLIGHT_EVALUATOR_CALLS=720',
        'D4U_CANDIDATE_PREFLIGHT_MODEL_CALLS=0',
        'D4U_CANDIDATE_PREFLIGHT_SCIENTIFIC_EXECUTIONS=0'
    )){Require-Condition (($text -split "`n") -contains $m) "D4U_PREFLIGHT_MARKER_MISSING::$m"}
}
function Test-Inventory([string]$Root){
    $ip=Join-Path $Root 'STOIX_VCFE_C1C2_D4U_IMPLEMENTATION_SOURCE_INVENTORY_FROZEN.json'
    Require-Condition (Test-Path -LiteralPath $ip -PathType Leaf) 'D4U_INVENTORY_MISSING'
    $i=Get-Content -LiteralPath $ip -Raw|ConvertFrom-Json
    Require-Condition ($i.study_id -eq $StudyId -and $i.file_count -eq 92) 'D4U_INVENTORY_IDENTITY'
    $c=0
    foreach($row in $i.files){
        $p=Join-Path $Root ([string]$row.path)
        Require-Condition (Test-Path -LiteralPath $p -PathType Leaf) "D4U_FILE_MISSING::$($row.path)"
        Require-Condition ((Get-Item -LiteralPath $p).Length -eq [int64]$row.bytes) "D4U_FILE_BYTES::$($row.path)"
        Require-Condition ((Get-FileSha256Hex $p) -eq [string]$row.sha256) "D4U_FILE_HASH::$($row.path)"
        $c++
    }
    Require-Condition ($c -eq 92) 'D4U_INVENTORY_COUNT'
}
Add-Type -AssemblyName System.IO.Compression.FileSystem

if($SelfTest -or $env:D4U_CANDIDATE_PREFLIGHT_SELFTEST -eq '1'){
    $fake=@(
        'D4U_CANDIDATE_PREFLIGHT_STATUS=PASS',
        'D4U_CANDIDATE_PREFLIGHT_PYTHON=3.12',
        'D4U_CANDIDATE_PREFLIGHT_PARENT_ARCHIVE_PATH=PASS',
        'D4U_CANDIDATE_PREFLIGHT_EVALUATOR_CALLS=720',
        'D4U_CANDIDATE_PREFLIGHT_MODEL_CALLS=0',
        'D4U_CANDIDATE_PREFLIGHT_SCIENTIFIC_EXECUTIONS=0'
    )
    Assert-Markers $fake

    $targetStyle=[pscustomobject]@{
        Id=$RuntimeManifestDigest
        Os='linux'
        Architecture='amd64'
        RepoDigests=@("python@$RuntimeManifestDigest")
    }
    $metaLines=@(Assert-RuntimeMetadata $targetStyle)
    Require-Condition (($metaLines -contains 'D4U_RUNTIME_PROOF_IMAGE_ID_MATCH=INFO_MISMATCH_ALLOWED')) 'D4U_SELFTEST_TARGET_STORE_ID_CLASSIFICATION'
    Require-Condition (($metaLines -contains 'D4U_RUNTIME_MANIFEST_DIGEST_MATCH=PASS')) 'D4U_SELFTEST_MANIFEST_DIGEST'

    Assert-RuntimePython @(
        'D4U_RUNTIME_PYTHON_VERSION=3.12.16',
        'D4U_RUNTIME_PYTHON_MAJOR_MINOR=3.12',
        'D4U_RUNTIME_PLATFORM=linux',
        'D4U_RUNTIME_OS_NAME=posix'
    )

    $negative=$false
    try{Assert-Markers @('Usage: docker [OPTIONS] COMMAND')}catch{if($_.Exception.Message -like 'D4U_PREFLIGHT_MARKER_MISSING::*'){$negative=$true}else{throw}}
    Require-Condition $negative 'D4U_SELFTEST_FALSE_PASS_NOT_BLOCKED'

    $negativeDigest=$false
    try{
        Assert-RuntimeMetadata ([pscustomobject]@{Id='sha256:x';Os='linux';Architecture='amd64';RepoDigests=@('python@sha256:wrong')})
    }catch{
        if($_.Exception.Message -eq 'D4U_RUNTIME_MANIFEST_DIGEST_FAIL'){$negativeDigest=$true}else{throw}
    }
    Require-Condition $negativeDigest 'D4U_SELFTEST_MANIFEST_NEGATIVE_NOT_BLOCKED'

    Require-Condition ($Helper.Length -gt 1000) 'D4U_SELFTEST_HELPER'
    Write-Output 'D4U_CANDIDATE_PREFLIGHT_WINDOWS_SELFTEST=PASS'
    Write-Output 'D4U_CANDIDATE_PREFLIGHT_TARGET_STORE_ID_SCENARIO=PASS'
    Write-Output 'D4U_CANDIDATE_PREFLIGHT_MANIFEST_NEGATIVE_BOUNDARY=PASS'
    Write-Output 'D4U_CANDIDATE_PREFLIGHT_FALSE_PASS_GUARD=PASS'
    exit 0
}

$tmp=Join-Path $env:TEMP ('d4u_candidate_preflight_'+[Guid]::NewGuid().ToString('N'))
$extract=Join-Path $tmp 'extract'
$helperPath=Join-Path $tmp 'D4U_CANDIDATE_PREFLIGHT.py'
try{
    $zip=Get-ChildItem -LiteralPath "$HOME\Downloads" -Filter 'D4U_CANDIDATE_PREFLIGHT*.zip' -File |
        Where-Object { (Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash.ToLowerInvariant() -eq $CandidateZipSha } |
        Select-Object -First 1
    Require-Condition ($null -ne $zip) 'D4U_CANDIDATE_ZIP_NOT_FOUND_OR_HASH_MISMATCH'
    [IO.Directory]::CreateDirectory($extract)|Out-Null
    [IO.Compression.ZipFile]::ExtractToDirectory($zip.FullName,$extract)
    $root=Join-Path $extract 'd4u_preregistration_implementation_freeze_v1'
    Require-Condition (Test-Path -LiteralPath $root -PathType Container) 'D4U_CANDIDATE_ROOT'
    Test-Inventory $root
    [IO.File]::WriteAllText($helperPath,$Helper,[Text.UTF8Encoding]::new($false))

    & docker pull $RuntimeRef | Out-Host
    Require-Condition ($LASTEXITCODE -eq 0) 'D4U_RUNTIME_PULL_FAIL'

    $inspectLines=@(& docker image inspect $RuntimeRef 2>&1 | ForEach-Object{"$_"})
    Require-Condition ($LASTEXITCODE -eq 0) 'D4U_RUNTIME_INSPECT_FAIL'
    $inspectDoc=($inspectLines -join "`n")|ConvertFrom-Json
    Require-Condition (@($inspectDoc).Count -eq 1) 'D4U_RUNTIME_INSPECT_OBJECT_COUNT'
    Assert-RuntimeMetadata @($inspectDoc)[0]

    $runtimeProbe=@(& docker run --rm --network=none --read-only --cap-drop=ALL --security-opt=no-new-privileges $RuntimeRef python -c 'import os,platform,sys;print("D4U_RUNTIME_PYTHON_VERSION="+platform.python_version());print("D4U_RUNTIME_PYTHON_MAJOR_MINOR="+str(sys.version_info.major)+"."+str(sys.version_info.minor));print("D4U_RUNTIME_PLATFORM="+sys.platform);print("D4U_RUNTIME_OS_NAME="+os.name)' 2>&1 | ForEach-Object{"$_"})
    $runtimeProbeExit=$LASTEXITCODE
    foreach($line in $runtimeProbe){Write-Output $line}
    Require-Condition ($runtimeProbeExit -eq 0) "D4U_RUNTIME_PYTHON_PROBE_EXIT::$runtimeProbeExit"
    Assert-RuntimePython $runtimeProbe
    Write-Output 'D4U_RUNTIME_PYTHON_3_12_MATCH=PASS'
    Write-Output ('D4U_RUNNER_REVISION='+$RunnerRevision)

    $saved=@{}
    foreach($n in @('OPENAI_API_KEY','VCFE_MASTER_SEED_HEX','D3_MASTER_SEED_HEX','C1C2_MASTER_SEED_HEX')){
        if(Test-Path "Env:$n"){$saved[$n]=(Get-Item "Env:$n").Value;Remove-Item "Env:$n"}
    }
    try{
        $dockerArgs=@(
            'run','--rm','--network=none','--read-only','--cap-drop=ALL','--security-opt=no-new-privileges',
            '--env','PYTHONDONTWRITEBYTECODE=1','--tmpfs','/tmp:rw,exec,nosuid,size=1073741824',
            '--mount',"type=bind,source=$root,target=/out",
            '--mount',"type=bind,source=$helperPath,target=/inputs/D4U_CANDIDATE_PREFLIGHT.py,readonly",
            '--cap-add','SYS_CHROOT','--cap-add','SETUID','--cap-add','SETGID','--cap-add','CHOWN','--cap-add','DAC_OVERRIDE','--cap-add','FOWNER',
            '--entrypoint','python',$RuntimeRef,'-B','/inputs/D4U_CANDIDATE_PREFLIGHT.py'
        )
        $lines=@(& docker @dockerArgs 2>&1 | ForEach-Object{"$_"}); $exit=$LASTEXITCODE
    }finally{foreach($kv in $saved.GetEnumerator()){Set-Item -Path ("Env:"+$kv.Key) -Value $kv.Value}}
    foreach($line in $lines){Write-Output $line}
    Require-Condition ($exit -eq 0) "D4U_CANDIDATE_DOCKER_EXIT::$exit"
    Assert-Markers $lines
    Test-Inventory $root
    Write-Output 'D4U_TARGET_CANDIDATE_PREFLIGHT=PASS'
    Write-Output 'D4U_TARGET_SEED_ACCESSED=NO'
    Write-Output 'D4U_TARGET_MODEL_CALLS=0'
    Write-Output 'D4U_TARGET_SCIENTIFIC_EXECUTION=NO'
    exit 0
}catch{
    Write-Output 'D4U_TARGET_CANDIDATE_PREFLIGHT=FAIL'
    Write-Output ('D4U_TARGET_CANDIDATE_PREFLIGHT_ERROR='+$_.Exception.Message)
    Write-Output 'D4U_TARGET_SEED_ACCESSED=NO'
    exit 2
}finally{Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue}
