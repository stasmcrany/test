param([switch]$SelfTest)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

$RuntimeRef='python@sha256:5e2bdb1b0d542d5039cffb8181c65930093949194a65c365dfb1b0fe13a4fa5b'
$ExpectedManifestDigest='sha256:5e2bdb1b0d542d5039cffb8181c65930093949194a65c365dfb1b0fe13a4fa5b'
$ExpectedProofImageId='sha256:78976a69c067520ef8be34cde307ef9f6fea6dcefa50edb57039773d241ca0db'

function Require-Condition([bool]$Condition,[string]$Code){if(-not $Condition){throw $Code}}

function Inspect-Runtime {
    $jsonLines=@(& docker image inspect $RuntimeRef 2>&1 | ForEach-Object{"$_"})
    $inspectExit=$LASTEXITCODE
    Require-Condition ($inspectExit -eq 0) "D4U_LOCAL_INSPECT_EXIT::$inspectExit"
    $inspectText=$jsonLines -join "`n"
    $arr=$inspectText|ConvertFrom-Json
    Require-Condition (@($arr).Count -eq 1) 'D4U_LOCAL_INSPECT_OBJECT_COUNT'
    $o=@($arr)[0]

    $id=[string]$o.Id
    $os=[string]$o.Os
    $arch=[string]$o.Architecture
    $digests=@($o.RepoDigests|ForEach-Object{"$_"})

    Write-Output ('D4U_LOCAL_IMAGE_ID='+$id)
    Write-Output ('D4U_LOCAL_IMAGE_OS='+$os)
    Write-Output ('D4U_LOCAL_IMAGE_ARCHITECTURE='+$arch)
    Write-Output ('D4U_LOCAL_REPODIGEST_COUNT='+$digests.Count)
    foreach($d in $digests){Write-Output ('D4U_LOCAL_REPODIGEST='+$d)}

    $probe=@(& docker run --rm --network=none --read-only --cap-drop=ALL --security-opt=no-new-privileges $RuntimeRef python -c 'import os,platform,sys;print("D4U_LOCAL_PYTHON_VERSION="+platform.python_version());print("D4U_LOCAL_PYTHON_MAJOR_MINOR="+str(sys.version_info.major)+"."+str(sys.version_info.minor));print("D4U_LOCAL_PYTHON_EXECUTABLE="+sys.executable);print("D4U_LOCAL_PLATFORM="+sys.platform);print("D4U_LOCAL_OS_NAME="+os.name)' 2>&1 | ForEach-Object{"$_"})
    $probeExit=$LASTEXITCODE
    foreach($line in $probe){Write-Output $line}
    Require-Condition ($probeExit -eq 0) "D4U_LOCAL_PYTHON_PROBE_EXIT::$probeExit"

    $mm=($probe|Where-Object{$_ -like 'D4U_LOCAL_PYTHON_MAJOR_MINOR=*'}|Select-Object -First 1)
    Require-Condition ($null -ne $mm) 'D4U_LOCAL_PYTHON_MARKER_MISSING'
    $mm=$mm.Split('=',2)[1]

    $repoDigestMatch=(@($digests|Where-Object{$_ -like "*@$ExpectedManifestDigest"}).Count -gt 0)
    $idMatch=($id -eq $ExpectedProofImageId)
    $platformMatch=($os -eq 'linux' -and $arch -eq 'amd64')
    $pythonMatch=($mm -eq '3.12')

    Write-Output ('D4U_LOCAL_MANIFEST_DIGEST_MATCH='+$(if($repoDigestMatch){'PASS'}else{'FAIL'}))
    Write-Output ('D4U_LOCAL_PROOF_IMAGE_ID_MATCH='+$(if($idMatch){'PASS'}else{'FAIL'}))
    Write-Output ('D4U_LOCAL_PLATFORM_MATCH='+$(if($platformMatch){'PASS'}else{'FAIL'}))
    Write-Output ('D4U_LOCAL_PYTHON_3_12_MATCH='+$(if($pythonMatch){'PASS'}else{'FAIL'}))

    if($repoDigestMatch -and $platformMatch -and $pythonMatch -and $idMatch){
        Write-Output 'D4U_LOCAL_RUNTIME_CLASSIFICATION=FULL_FREEZE_MATCH'
    }elseif($repoDigestMatch -and $platformMatch -and $pythonMatch -and -not $idMatch){
        Write-Output 'D4U_LOCAL_RUNTIME_CLASSIFICATION=MANIFEST_PLATFORM_PYTHON_MATCH_IMAGE_ID_MISMATCH'
    }else{
        Write-Output 'D4U_LOCAL_RUNTIME_CLASSIFICATION=RUNTIME_CONTRACT_MISMATCH'
    }

    Write-Output 'D4U_LOCAL_RUNTIME_INSPECTION_STATUS=PASS'
    Write-Output 'D4U_LOCAL_SEED_ACCESSED=NO'
    Write-Output ('D4U_LOCAL_ONE_SHOT_CONSUMED=NO'
    Write-Output ('D4U_LOCAL_FIXTURE_GENERATION=NO')
    Write-Output 'D4U_LOCAL_SCIENTIFIC_EXECUTION=NO'
}

if($SelfTest -or $env:D4U_LOCAL_RUNTIME_INSPECT_SELFTEST -eq '1'){
    $tag=[Guid]::NewGuid().ToString('N')
    $tmp=Join-Path $env:RUNNER_TEMP ('d4u_local_inspect_'+$tag)
    [IO.Directory]::CreateDirectory($tmp)|Out-Null
    $stub=Join-Path $tmp 'docker.cmd'
    $body=@'
@echo off
if /I "%1"=="image" (
  echo [{"Id":"sha256:DIFFERENT_LOCAL_ID","RepoDigests":["python@sha256:5e2bdb1b0d542d5039cffb8181c65930093949194a65c365dfb1b0fe13a4fa5b"],"Os":"linux","Architecture":"amd64"}]
  exit /b 0
)
if /I "%1"=="run" (
  echo D4U_LOCAL_PYTHON_VERSION=3.12.16
  echo D4U_LOCAL_PYTHON_MAJOR_MINOR=3.12
  echo D4U_LOCAL_PYTHON_EXECUTABLE=/usr/local/bin/python
  echo D4U_LOCAL_PLATFORM=linux
  echo D4U_LOCAL_OS_NAME=posix
  exit /b 0
)
exit /b 92
'@
    [IO.File]::WriteAllText($stub,$body,[Text.ASCIIEncoding]::new())
    $old=$env:PATH
    try{
        $env:PATH=$tmp+';'+$old
        $lines=@(Inspect-Runtime)
        foreach($line in $lines){Write-Output $line}
        Require-Condition (($lines -contains 'D4U_LOCAL_MANIFEST_DIGEST_MATCH=PASS')) 'D4U_SELFTEST_DIGEST'
        Require-Condition (($lines -contains 'D4U_LOCAL_PROOF_IMAGE_ID_MATCH=FAIL')) 'D4U_SELFTEST_ID_MISMATCH'
        Require-Condition (($lines -contains 'D4U_LOCAL_PLATFORM_MATCH=PASS')) 'D4U_SELFTEST_PLATFORM'
        Require-Condition (($lines -contains 'D4U_LOCAL_PYTHON_3_12_MATCH=PASS')) 'D4U_SELFTEST_PYTHON'
        Require-Condition (($lines -contains 'D4U_LOCAL_RUNTIME_CLASSIFICATION=MANIFEST_PLATFORM_PYTHON_MATCH_IMAGE_ID_MISMATCH')) 'D4U_SELFTEST_CLASSIFICATION'
        Write-Output 'D4U_LOCAL_RUNTIME_INSPECT_WINDOWS_SELFTEST=PASS'
    }finally{
        $env:PATH=$old
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
    exit 0
}

try{
    Inspect-Runtime
    exit 0
}catch{
    Write-Output 'D4U_LOCAL_RUNTIME_INSPECTION_STATUS=FAIL'
    Write-Output ('D4U_LOCAL_RUNTIME_INSPECTION_ERROR='+$_.Exception.Message)
    Write-Output 'D4U_LOCAL_SEED_ACCESSED=NO'
    Write-Output 'D4U_LOCAL_ONE_SHOT_CONSUMED=NO'
    exit 2
}
