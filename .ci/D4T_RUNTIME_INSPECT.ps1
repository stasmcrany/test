param([switch]$SelfTest)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

$RuntimeImage='sha256:de727f8cdd1e2fcb9cb80d3444b95839af7e76302ca9778520a7243ebe6577ba'

function Require-Condition([bool]$Condition,[string]$Code){if(-not $Condition){throw $Code}}

function Invoke-DockerText([string[]]$DockerArgs){
    $lines=@(& docker @DockerArgs 2>&1 | ForEach-Object { "$_" })
    $exit=$LASTEXITCODE
    return [ordered]@{exit_code=$exit;lines=$lines}
}

function Invoke-Inspection {
    $inspect=Invoke-DockerText @('image','inspect','--format','{{.Id}} {{.Os}} {{.Architecture}}',$RuntimeImage)
    foreach($line in $inspect.lines){Write-Output $line}
    Require-Condition ($inspect.exit_code -eq 0) "D4T_RUNTIME_INSPECT_EXIT::$($inspect.exit_code)"
    $identity=($inspect.lines -join "`n").Trim()
    Require-Condition ($identity -eq "$RuntimeImage linux amd64") "D4T_RUNTIME_IMAGE_IDENTITY::$identity"

    $probe=Invoke-DockerText @(
        'run','--rm',
        '--network=none',
        '--read-only',
        '--cap-drop=ALL',
        '--security-opt=no-new-privileges',
        '--entrypoint','/opt/pyvenv/bin/python',
        $RuntimeImage,
        '-c',
        'import os,platform,sys;print("D4T_RUNTIME_PYTHON_VERSION="+platform.python_version());print("D4T_RUNTIME_PYTHON_MAJOR_MINOR="+str(sys.version_info.major)+"."+str(sys.version_info.minor));print("D4T_RUNTIME_PYTHON_EXECUTABLE="+sys.executable);print("D4T_RUNTIME_PLATFORM="+sys.platform);print("D4T_RUNTIME_OS_NAME="+os.name)'
    )
    foreach($line in $probe.lines){Write-Output $line}
    Require-Condition ($probe.exit_code -eq 0) "D4T_RUNTIME_PROBE_EXIT::$($probe.exit_code)"

    $text=$probe.lines -join "`n"
    foreach($required in @(
        'D4T_RUNTIME_PYTHON_VERSION=',
        'D4T_RUNTIME_PYTHON_MAJOR_MINOR=',
        'D4T_RUNTIME_PYTHON_EXECUTABLE=',
        'D4T_RUNTIME_PLATFORM=linux',
        'D4T_RUNTIME_OS_NAME=posix'
    )){
        Require-Condition ($text -match [regex]::Escape($required)) "D4T_RUNTIME_PROBE_MARKER_MISSING::$required"
    }

    $mm=($probe.lines|Where-Object{$_ -like 'D4T_RUNTIME_PYTHON_MAJOR_MINOR=*'}|Select-Object -First 1).Split('=',2)[1]
    Write-Output 'D4T_RUNTIME_INSPECTION_STATUS=PASS'
    Write-Output ('D4T_RUNTIME_IMAGE_ID='+$RuntimeImage)
    Write-Output ('D4T_RUNTIME_PYTHON_3_12_MATCH='+$(if($mm -eq '3.12'){'PASS'}else{'FAIL'}))
    Write-Output 'D4T_RUNTIME_SEED_ACCESSED=NO'
    Write-Output 'D4T_RUNTIME_ONE_SHOT_CONSUMED=NO'
    Write-Output 'D4T_RUNTIME_FIXTURE_GENERATION=NO'
    Write-Output 'D4T_RUNTIME_SCIENTIFIC_EXECUTION=NO'
}

if($SelfTest -or $env:D4T_RUNTIME_INSPECT_SELFTEST -eq '1'){
    $tag=[Guid]::NewGuid().ToString('N')
    $tmp=Join-Path $env:RUNNER_TEMP ('d4t_runtime_inspect_'+$tag)
    [IO.Directory]::CreateDirectory($tmp)|Out-Null
    $stub=Join-Path $tmp 'docker.cmd'
    $body=@'
@echo off
if /I "%1"=="image" (
  echo sha256:de727f8cdd1e2fcb9cb80d3444b95839af7e76302ca9778520a7243ebe6577ba linux amd64
  exit /b 0
)
if /I "%1"=="run" (
  echo D4T_RUNTIME_PYTHON_VERSION=3.13.9
  echo D4T_RUNTIME_PYTHON_MAJOR_MINOR=3.13
  echo D4T_RUNTIME_PYTHON_EXECUTABLE=/opt/pyvenv/bin/python
  echo D4T_RUNTIME_PLATFORM=linux
  echo D4T_RUNTIME_OS_NAME=posix
  exit /b 0
)
exit /b 92
'@
    [IO.File]::WriteAllText($stub,$body,[Text.ASCIIEncoding]::new())
    $oldPath=$env:PATH
    try{
        $env:PATH=$tmp+';'+$oldPath
        Invoke-Inspection
        Write-Output 'D4T_RUNTIME_INSPECT_WINDOWS_SELFTEST=PASS'
    }finally{
        $env:PATH=$oldPath
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
    exit 0
}

try{
    Invoke-Inspection
    exit 0
}catch{
    Write-Output 'D4T_RUNTIME_INSPECTION_STATUS=FAIL'
    Write-Output ('D4T_RUNTIME_INSPECTION_ERROR='+$_.Exception.Message)
    Write-Output 'D4T_RUNTIME_SEED_ACCESSED=NO'
    Write-Output 'D4T_RUNTIME_ONE_SHOT_CONSUMED=NO'
    exit 2
}
