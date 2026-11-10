param([switch]$SelfTest)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

$InputBundleSha='d7c29223180cbcba7ce4f3f51b399988e672ae47ce2ef5ed5198665571724266'
$RuntimeRef='python@sha256:5e2bdb1b0d542d5039cffb8181c65930093949194a65c365dfb1b0fe13a4fa5b'
$ManifestDigest='sha256:5e2bdb1b0d542d5039cffb8181c65930093949194a65c365dfb1b0fe13a4fa5b'
$HelperSha='52ceb95318eb09bb5e2d1d62138b2db21c6a401c531afe8f058a69b500c28b0a'

$Helper=@'
import hashlib
import json
import os
import sys
import zipfile
from pathlib import Path

ROOT=Path("/out").resolve()
if sys.version_info[:2] != (3,12):
    raise SystemExit("D4V_PATCH_PYTHON_3_12_REQUIRED")
if not sys.platform.startswith("linux") or os.name!="posix":
    raise SystemExit("D4V_PATCH_LINUX_REQUIRED")
if "OPENAI_API_KEY" in os.environ:
    raise SystemExit("D4V_PATCH_OPENAI_SECRET_ENV_FORBIDDEN")

PORTABLE_SANDBOX = 'from __future__ import annotations\nimport ctypes, errno, hashlib, json, os, pathlib, posixpath, resource, shutil, subprocess, sys, sysconfig, tempfile\nfrom dataclasses import dataclass\n\nNOBODY_UID = 65534\nNOBODY_GID = 65534\n\n@dataclass(frozen=True)\nclass SandboxResult:\n    returncode: int\n    stdout: str\n    stderr: str\n    source_sha256: str\n\nclass SandboxUnavailable(RuntimeError):\n    pass\nclass ProtocolViolation(RuntimeError):\n    pass\n\ndef sha256_bytes(b: bytes) -> str:\n    return hashlib.sha256(b).hexdigest()\n\ndef _copy_file_bytes(src: pathlib.Path, dst: pathlib.Path, mode: int = 0o555) -> None:\n    dst.parent.mkdir(parents=True, exist_ok=True)\n    shutil.copy2(src, dst)\n    os.chmod(dst, mode)\n\ndef _ldd_deps(path: pathlib.Path) -> list[str]:\n    try:\n        cp = subprocess.run(["ldd", str(path)], text=True, capture_output=True, check=True, timeout=5.0)\n    except Exception as e:\n        raise SandboxUnavailable(f"ldd failed for {path}: {type(e).__name__}: {e}") from e\n    out = []\n    for raw in cp.stdout.splitlines():\n        line = raw.strip()\n        if not line:\n            continue\n        candidate = None\n        if "=>" in line:\n            rhs = line.split("=>", 1)[1].strip().split(" ", 1)[0]\n            if rhs.startswith("/"):\n                candidate = rhs\n        else:\n            tok = line.split(" ", 1)[0]\n            if tok.startswith("/"):\n                candidate = tok\n        if candidate and candidate not in out:\n            out.append(candidate)\n    return out\n\ndef _dependency_destination(src_path: str) -> pathlib.PurePosixPath:\n    if src_path == "/lib64/ld-linux-x86-64.so.2":\n        normalized = src_path\n    else:\n        normalized = posixpath.normpath(src_path)\n    p = pathlib.PurePosixPath(normalized)\n    if not p.is_absolute() or ".." in p.parts:\n        raise SandboxUnavailable(f"unsafe dependency path: {src_path}")\n    return p\n\n_RUNTIME_LAYOUT = None\n\ndef _runtime_layout():\n    global _RUNTIME_LAYOUT\n    if _RUNTIME_LAYOUT is not None:\n        return _RUNTIME_LAYOUT\n    if (sys.version_info.major, sys.version_info.minor) != (3, 12):\n        raise SandboxUnavailable(f"python runtime mismatch: {sys.version_info.major}.{sys.version_info.minor}")\n    py = pathlib.Path(sys.executable).resolve()\n    stdlib = pathlib.Path(sysconfig.get_paths()["stdlib"]).resolve()\n    prefix = pathlib.Path(sys.prefix).resolve()\n    if py != pathlib.Path("/usr/local/bin/python3.12") or stdlib != pathlib.Path("/usr/local/lib/python3.12") or prefix != pathlib.Path("/usr/local"):\n        raise SandboxUnavailable(f"python layout mismatch: executable={py} stdlib={stdlib} prefix={prefix}")\n    try:\n        import _hashlib, _json\n    except Exception as e:\n        raise SandboxUnavailable(f"runtime extension import failed: {type(e).__name__}: {e}") from e\n    targets = [py, pathlib.Path(_hashlib.__file__).resolve(), pathlib.Path(_json.__file__).resolve()]\n    deps = []\n    for target in targets:\n        for dep in _ldd_deps(target):\n            if dep not in deps:\n                deps.append(dep)\n    if "/lib64/ld-linux-x86-64.so.2" not in deps:\n        raise SandboxUnavailable("ELF loader dependency missing")\n    _RUNTIME_LAYOUT = (py, stdlib, prefix, tuple(deps))\n    return _RUNTIME_LAYOUT\n\ndef _copy_runtime(root: pathlib.Path) -> tuple[str, str]:\n    py, stdlib, prefix, deps = _runtime_layout()\n    _copy_file_bytes(py, root / py.relative_to("/"), 0o555)\n    shutil.copytree(stdlib, root / stdlib.relative_to("/"), dirs_exist_ok=True,\n                    ignore=shutil.ignore_patterns("__pycache__", "site-packages"))\n    for p in (root / stdlib.relative_to("/")).rglob("*"):\n        try:\n            os.chmod(p, 0o555 if p.is_dir() else 0o444)\n        except FileNotFoundError:\n            pass\n    for dep in deps:\n        src = pathlib.Path(dep).resolve()\n        if not src.is_file():\n            raise SandboxUnavailable(f"runtime dependency missing: {dep}")\n        dest = _dependency_destination(dep)\n        _copy_file_bytes(src, root / dest.relative_to("/"), 0o555)\n    required = (\n        root / "usr/local/bin/python3.12",\n        root / "usr/local/lib/libpython3.12.so.1.0",\n        root / "lib64/ld-linux-x86-64.so.2",\n    )\n    if not all(p.is_file() for p in required):\n        raise SandboxUnavailable("portable runtime bootstrap incomplete")\n    return "/" + str(py.relative_to("/")), str(prefix)\n\ndef _install_seccomp_network_deny() -> None:\n    lib = ctypes.CDLL("libseccomp.so.2")\n    lib.seccomp_init.argtypes=[ctypes.c_uint32]; lib.seccomp_init.restype=ctypes.c_void_p\n    lib.seccomp_syscall_resolve_name.argtypes=[ctypes.c_char_p]; lib.seccomp_syscall_resolve_name.restype=ctypes.c_int\n    lib.seccomp_rule_add.argtypes=[ctypes.c_void_p,ctypes.c_uint32,ctypes.c_int,ctypes.c_uint32]; lib.seccomp_rule_add.restype=ctypes.c_int\n    lib.seccomp_load.argtypes=[ctypes.c_void_p]; lib.seccomp_load.restype=ctypes.c_int\n    lib.seccomp_release.argtypes=[ctypes.c_void_p]\n    SCMP_ACT_ALLOW=0x7fff0000; SCMP_ACT_ERRNO=0x00050000 | (errno.EPERM & 0xFFFF)\n    ctx=lib.seccomp_init(SCMP_ACT_ALLOW)\n    if not ctx: raise SandboxUnavailable("seccomp_init failed")\n    try:\n        for name in (b"socket",b"socketpair",b"connect",b"bind",b"listen",b"accept",b"accept4",b"sendto",b"recvfrom",b"sendmsg",b"recvmsg",b"ptrace",b"process_vm_readv",b"process_vm_writev",b"pidfd_getfd",b"fork",b"vfork",b"clone",b"clone3"):\n            nr=lib.seccomp_syscall_resolve_name(name)\n            if nr >= 0:\n                rc=lib.seccomp_rule_add(ctx,SCMP_ACT_ERRNO,nr,0)\n                if rc != 0: raise SandboxUnavailable(f"seccomp rule failed {name!r}: {rc}")\n        rc=lib.seccomp_load(ctx)\n        if rc != 0: raise SandboxUnavailable(f"seccomp_load failed: {rc}")\n    finally:\n        lib.seccomp_release(ctx)\n\ndef _set_resource_limits() -> None:\n    resource.setrlimit(resource.RLIMIT_CPU,(3,3))\n    resource.setrlimit(resource.RLIMIT_AS,(768*1024*1024,768*1024*1024))\n    resource.setrlimit(resource.RLIMIT_FSIZE,(16*1024*1024,16*1024*1024))\n    resource.setrlimit(resource.RLIMIT_NOFILE,(32,32))\n    try: resource.setrlimit(resource.RLIMIT_NPROC,(8,8))\n    except (ValueError,OSError): pass\n\ndef run_isolated_python(source_text: str, timeout: float = 5.0, input_text: str = "", declared_sha256: str | None = None) -> SandboxResult:\n    source_bytes=source_text.encode("utf-8"); actual=sha256_bytes(source_bytes)\n    if declared_sha256 is not None and declared_sha256 != actual:\n        raise ProtocolViolation("candidate source hash mismatch")\n    base = pathlib.Path(tempfile.mkdtemp(prefix="vcfe_a3_sbox_"))\n    try:\n        root = base / "root"; root.mkdir()\n        python_inside, python_home = _copy_runtime(root)\n        (root / "candidate").mkdir(); (root / "scratch").mkdir()\n        script = root / "candidate/probe.py"; script.write_bytes(source_bytes)\n        os.chmod(script,0o444); os.chmod(root/"candidate",0o555)\n        os.chown(root/"scratch",NOBODY_UID,NOBODY_GID); os.chmod(root/"scratch",0o700)\n        def preexec():\n            _install_seccomp_network_deny(); _set_resource_limits(); os.chroot(root); os.chdir("/scratch")\n            os.setgroups([]); os.setgid(NOBODY_GID); os.setuid(NOBODY_UID); os.umask(0o077)\n        env={"PATH":"/usr/local/bin:/usr/bin","PYTHONHOME":python_home,"LD_LIBRARY_PATH":"/usr/local/lib",\n             "PYTHONDONTWRITEBYTECODE":"1","LANG":"C.UTF-8"}\n        cp=subprocess.run([python_inside,"-I","/candidate/probe.py"],input=input_text,text=True,capture_output=True,\n                          timeout=timeout,env=env,preexec_fn=preexec)\n        return SandboxResult(cp.returncode,cp.stdout,cp.stderr,actual)\n    finally:\n        shutil.rmtree(base,ignore_errors=True)\n\ndef run_isolated_jsonl(source_text: str, request: dict, declared_sha256: str, timeout: float = 5.0) -> dict:\n    inp=json.dumps(request,sort_keys=True,separators=(",",":"))+"\\n"\n    r=run_isolated_python(source_text,timeout=timeout,input_text=inp,declared_sha256=declared_sha256)\n    if r.returncode != 0: raise ProtocolViolation(f"candidate failed rc={r.returncode}")\n    lines=[x for x in r.stdout.splitlines() if x.strip()]\n    if len(lines)!=1: raise ProtocolViolation("candidate stdout must contain exactly one non-empty JSON line")\n    try: obj=json.loads(lines[0])\n    except json.JSONDecodeError as e: raise ProtocolViolation("candidate stdout is not valid JSON") from e\n    if not isinstance(obj,dict): raise ProtocolViolation("candidate JSON response must be an object")\n    return {"response":obj,"source_sha256":r.source_sha256,"stderr":r.stderr}\n'
EXPECTED_SANDBOX_SHA = "d41ce3caef8fc9f69f690f93a4c2bdc8da8af2e4fda6d5fd4ffa70e7a2465606"

def sha(b):
    return hashlib.sha256(b).hexdigest()

def write_json(path,obj):
    path.write_text(json.dumps(obj,sort_keys=True,indent=2)+"\n",encoding="utf-8",newline="\n")

sandbox_bytes=PORTABLE_SANDBOX.encode("utf-8")
if sha(sandbox_bytes)!=EXPECTED_SANDBOX_SHA:
    raise SystemExit("D4V_PATCH_SANDBOX_SOURCE_HASH")

candidate=ROOT/"borrowed_c1c2/borrowed_parent/candidate.zip"
manifest_path=ROOT/"borrowed_c1c2/borrowed_parent/manifest.json"
ids_path=ROOT/"borrowed_c1c2/C1C2_FROZEN_INPUT_IDENTITIES.json"
inventory_path=ROOT/"STOIX_VCFE_C1C2_D4U_IMPLEMENTATION_SOURCE_INVENTORY_FROZEN.json"

if sha(candidate.read_bytes())!="38db87341fbfbca72622ea39c14ac659b234689c284a3275240fbac29d0ac0cb":
    raise SystemExit("D4V_PATCH_ORIGINAL_PARENT_ZIP_HASH")
if sha(manifest_path.read_bytes())!="d89de612f429ba418b497b9336fe6bb504473c7aa96105962d13999a8ac32bfd":
    raise SystemExit("D4V_PATCH_ORIGINAL_PARENT_MANIFEST_HASH")

# Patch only a3_runtime/sandbox.py inside candidate.zip.
patched=candidate.with_suffix(".patched.zip")
with zipfile.ZipFile(candidate,"r") as zin, zipfile.ZipFile(patched,"w") as zout:
    names=[x.filename for x in zin.infolist()]
    if names.count("a3_runtime/sandbox.py")!=1:
        raise SystemExit("D4V_PATCH_SANDBOX_MEMBER_COUNT")
    for info in zin.infolist():
        data=sandbox_bytes if info.filename=="a3_runtime/sandbox.py" else zin.read(info.filename)
        new=zipfile.ZipInfo(info.filename,date_time=info.date_time)
        new.compress_type=info.compress_type
        new.comment=info.comment
        new.extra=info.extra
        new.create_system=info.create_system
        new.create_version=info.create_version
        new.extract_version=info.extract_version
        new.flag_bits=info.flag_bits
        new.volume=info.volume
        new.internal_attr=info.internal_attr
        new.external_attr=info.external_attr
        zout.writestr(new,data)
patched.replace(candidate)
candidate_sha=sha(candidate.read_bytes())

manifest=json.loads(manifest_path.read_bytes())
rows=[x for x in manifest["files"] if x["path"]=="a3_runtime/sandbox.py"]
if len(rows)!=1:
    raise SystemExit("D4V_PATCH_PARENT_MANIFEST_SANDBOX_COUNT")
rows[0]["bytes"]=len(sandbox_bytes)
rows[0]["sha256"]=EXPECTED_SANDBOX_SHA
write_json(manifest_path,manifest)
manifest_sha=sha(manifest_path.read_bytes())

ids=json.loads(ids_path.read_bytes())
ids["hashes"]["borrowed_parent/candidate.zip"]=candidate_sha
ids["hashes"]["borrowed_parent/manifest.json"]=manifest_sha
write_json(ids_path,ids)
ids_sha=sha(ids_path.read_bytes())

inventory=json.loads(inventory_path.read_bytes())
changed={
    "borrowed_c1c2/borrowed_parent/candidate.zip":candidate,
    "borrowed_c1c2/borrowed_parent/manifest.json":manifest_path,
    "borrowed_c1c2/C1C2_FROZEN_INPUT_IDENTITIES.json":ids_path,
}
seen=set()
for row in inventory["files"]:
    if row["path"] in changed:
        b=changed[row["path"]].read_bytes()
        row["bytes"]=len(b)
        row["sha256"]=sha(b)
        seen.add(row["path"])
if seen!=set(changed):
    raise SystemExit("D4V_PATCH_INVENTORY_BINDINGS_MISSING")
write_json(inventory_path,inventory)

# Prove external parent manifest replays against patched parent archive.
with zipfile.ZipFile(candidate) as z:
    for item in manifest["files"]:
        if sha(z.read(item["path"]))!=item["sha256"]:
            raise SystemExit("D4V_PATCH_PARENT_MANIFEST_REPLAY::"+item["path"])

# Prove updated top-level inventory.
for row in inventory["files"]:
    b=(ROOT/row["path"]).read_bytes()
    if len(b)!=row["bytes"] or sha(b)!=row["sha256"]:
        raise SystemExit("D4V_PATCH_SOURCE_INVENTORY_REPLAY::"+row["path"])

print("D4V_PATCH_SANDBOX_SHA256="+EXPECTED_SANDBOX_SHA,flush=True)
print("D4V_PATCH_PARENT_ZIP_SHA256="+candidate_sha,flush=True)
print("D4V_PATCH_PARENT_MANIFEST_SHA256="+manifest_sha,flush=True)
print("D4V_PATCH_FROZEN_INPUT_IDENTITIES_SHA256="+ids_sha,flush=True)
print("D4V_PATCH_INTEGRITY_REPLAY=PASS",flush=True)

sys.path.insert(0,str(ROOT))
import d4u_protocol as d

d.verify_inputs()
d.runtime_preflight()
d.schema_neutrality()
if len(d.schedule_check())!=30:
    raise SystemExit("D4V_PATCH_SCHEDULE_FAIL")

receipt=ROOT/d.PREQUALIFICATION_NAME
if receipt.exists():
    receipt.unlink()

master=d.synthetic_master()
try:
    prior={"derived_seed_sha256s":[hashlib.sha256(b"D4V_PRE_FREEZE_INTEGRATION_PRIOR_SENTINEL").hexdigest()]}
    calls={"n":0}
    def evaluator(task,source,candidate):
        calls["n"]+=1
        if calls["n"]%120==0:
            print(f"D4V_INTEGRATION_PROGRESS={calls['n']}/720",flush=True)
        return d.verifier.evaluate_one(task,source,candidate)

    gate=d.prequalify(master,receipt,prior,evaluator=evaluator)
    if calls["n"]!=720:
        raise SystemExit(f"D4V_INTEGRATION_EVALUATOR_COUNT::{calls['n']}")
    gate.check()

    raw=receipt.read_bytes()
    data=json.loads(raw)
    rows=data["geometry_results"]
    if data["status"]!="PASS":
        raise SystemExit("D4V_INTEGRATION_STATUS_NOT_PASS")
    if not all(r["reference_success"] and r["reference_dataflow"] and r["reference_tasks_passed"]==24 for r in rows):
        raise SystemExit("D4V_INTEGRATION_REFERENCE_FAIL")
    if not all(r["c1_useful_first_segment"] for r in rows):
        raise SystemExit("D4V_INTEGRATION_C1_USEFUL_FAIL")
    if sum(bool(r["c1_alone_success"]) for r in rows)!=0:
        raise SystemExit("D4V_INTEGRATION_C1_ALONE_FAIL")
    if sum(bool(r["inert_success"]) for r in rows)>1:
        raise SystemExit("D4V_INTEGRATION_INERT_FAIL")
    if data["model_calls"]!=0 or data["scientific_executions"]!=0:
        raise SystemExit("D4V_INTEGRATION_ZERO_MODEL_BOUNDARY_FAIL")

    print("D4V_RUNTIME_PATCH_INTEGRATION_STATUS=PASS",flush=True)
    print("D4V_INTEGRATION_EVALUATOR_CALLS=720",flush=True)
    print("D4V_INTEGRATION_REFERENCE_FIXTURES_PASS=10/10",flush=True)
    print("D4V_INTEGRATION_C1_USEFUL_FIXTURES_PASS=10/10",flush=True)
    print("D4V_INTEGRATION_C1_ALONE_SUCCESS_FIXTURES=0",flush=True)
    print("D4V_INTEGRATION_INERT_SUCCESS_FIXTURES="+str(sum(bool(r["inert_success"]) for r in rows)),flush=True)
    print("D4V_INTEGRATION_MODEL_CALLS=0",flush=True)
    print("D4V_INTEGRATION_SCIENTIFIC_EXECUTIONS=0",flush=True)
    print("D4V_INTEGRATION_SYNTHETIC_RECEIPT_SHA256="+sha(raw),flush=True)
finally:
    master.clear()
'@
$Helper += "`n"

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

function Assert-ResultMarkers([string[]]$Lines){
    $required=@(
        'D4V_PATCH_INTEGRITY_REPLAY=PASS',
        'D4V_RUNTIME_PATCH_INTEGRATION_STATUS=PASS',
        'D4V_INTEGRATION_EVALUATOR_CALLS=720',
        'D4V_INTEGRATION_REFERENCE_FIXTURES_PASS=10/10',
        'D4V_INTEGRATION_C1_USEFUL_FIXTURES_PASS=10/10',
        'D4V_INTEGRATION_C1_ALONE_SUCCESS_FIXTURES=0',
        'D4V_INTEGRATION_MODEL_CALLS=0',
        'D4V_INTEGRATION_SCIENTIFIC_EXECUTIONS=0'
    )
    foreach($m in $required){
        Require-Condition ($Lines -contains $m) "D4V_RESULT_MARKER_MISSING::$m"
    }
}

$helperBytes=[Text.UTF8Encoding]::new($false).GetBytes($Helper)
try{
    Require-Condition ((Get-Sha256Hex $helperBytes) -eq $HelperSha) 'D4V_HELPER_HASH'

    if($SelfTest -or $env:D4V_PRE_FREEZE_PATCH_SELFTEST -eq '1'){
        $positive=@(
            'D4V_PATCH_INTEGRITY_REPLAY=PASS',
            'D4V_RUNTIME_PATCH_INTEGRATION_STATUS=PASS',
            'D4V_INTEGRATION_EVALUATOR_CALLS=720',
            'D4V_INTEGRATION_REFERENCE_FIXTURES_PASS=10/10',
            'D4V_INTEGRATION_C1_USEFUL_FIXTURES_PASS=10/10',
            'D4V_INTEGRATION_C1_ALONE_SUCCESS_FIXTURES=0',
            'D4V_INTEGRATION_MODEL_CALLS=0',
            'D4V_INTEGRATION_SCIENTIFIC_EXECUTIONS=0'
        )
        Assert-ResultMarkers $positive
        $negative=$false
        try{Assert-ResultMarkers @('D4V_RUNTIME_PATCH_INTEGRATION_STATUS=PASS')}catch{
            if($_.Exception.Message -like 'D4V_RESULT_MARKER_MISSING::*'){$negative=$true}else{throw}
        }
        Require-Condition $negative 'D4V_FALSE_PASS_GUARD_NOT_ENFORCED'
        Require-Condition ($Helper -like '*D4V_PATCH_SANDBOX_SHA256*') 'D4V_SELFTEST_PATCH_MARKER'
        Require-Condition ($Helper -like '*D4V_INTEGRATION_PROGRESS=*') 'D4V_SELFTEST_720_PATH'
        Write-Output 'D4V_PRE_FREEZE_PATCH_V3_WINDOWS_SELFTEST=PASS'
        Write-Output 'D4V_PRE_FREEZE_PATCH_V3_FALSE_PASS_GUARD=PASS'
        Write-Output ('D4V_PRE_FREEZE_PATCH_V3_HELPER_SHA256='+$HelperSha)
        exit 0
    }

    $input=Get-ChildItem -LiteralPath "$HOME\Downloads" -Filter 'D4U_CANDIDATE_PREFLIGHT*.zip' -File |
        Where-Object { (Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash.ToLowerInvariant() -eq $InputBundleSha } |
        Select-Object -First 1
    Require-Condition ($null -ne $input) 'D4V_INPUT_D4U_BUNDLE_NOT_FOUND_OR_HASH_MISMATCH'

    $tag=[Guid]::NewGuid().ToString('N')
    $tmp=Join-Path $env:TEMP ('d4v_patch_'+$tag)
    [IO.Directory]::CreateDirectory($tmp)|Out-Null
    try{
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $extract=Join-Path $tmp 'x'
        [IO.Directory]::CreateDirectory($extract)|Out-Null
        [IO.Compression.ZipFile]::ExtractToDirectory($input.FullName,$extract)
        $root=Join-Path $extract 'd4u_preregistration_implementation_freeze_v1'
        Require-Condition (Test-Path -LiteralPath $root -PathType Container) 'D4V_INPUT_ROOT_MISSING'

        $helperPath=Join-Path $tmp 'D4V_PATCH_INTEGRATION.py'
        [IO.File]::WriteAllBytes($helperPath,$helperBytes)
        Require-Condition ((Get-FileSha256Hex $helperPath) -eq $HelperSha) 'D4V_WRITTEN_HELPER_HASH'

        $inspect=@(& docker image inspect $RuntimeRef 2>&1 | ForEach-Object{"$_"})
        Require-Condition ($LASTEXITCODE -eq 0) 'D4V_RUNTIME_IMAGE_MISSING'
        $doc=($inspect -join "`n")|ConvertFrom-Json
        Require-Condition (@($doc).Count -eq 1) 'D4V_RUNTIME_OBJECT_COUNT'
        $o=@($doc)[0]
        Require-Condition ([string]$o.Os -eq 'linux' -and [string]$o.Architecture -eq 'amd64') 'D4V_RUNTIME_PLATFORM'
        $digests=@($o.RepoDigests|ForEach-Object{"$_"})
        Require-Condition ((@($digests|Where-Object{$_ -eq "python@$ManifestDigest"}).Count) -gt 0) 'D4V_RUNTIME_MANIFEST_DIGEST'

        $saved=@{}
        foreach($name in @('OPENAI_API_KEY','VCFE_MASTER_SEED_HEX','D3_MASTER_SEED_HEX','C1C2_MASTER_SEED_HEX')){
            if(Test-Path "Env:$name"){$saved[$name]=(Get-Item "Env:$name").Value;Remove-Item "Env:$name"}
        }
        try{
            $dockerArgs=@(
                'run','--rm',
                '--network=none',
                '--read-only',
                '--cap-drop=ALL',
                '--security-opt=no-new-privileges',
                '--env','PYTHONDONTWRITEBYTECODE=1',
                '--tmpfs','/tmp:rw,exec,nosuid,size=1073741824',
                '--mount',"type=bind,source=$root,target=/out",
                '--mount',"type=bind,source=$helperPath,target=/inputs/D4V_PATCH_INTEGRATION.py,readonly",
                '--cap-add','SYS_CHROOT',
                '--cap-add','SETUID',
                '--cap-add','SETGID',
                '--cap-add','CHOWN',
                '--cap-add','DAC_OVERRIDE',
                '--cap-add','FOWNER',
                '--entrypoint','python',
                $RuntimeRef,
                '-B','/inputs/D4V_PATCH_INTEGRATION.py'
            )
            $lines=@(& docker @dockerArgs 2>&1 | ForEach-Object{"$_"})
            $dockerExit=$LASTEXITCODE
        }finally{
            foreach($kv in $saved.GetEnumerator()){Set-Item -Path ("Env:"+$kv.Key) -Value $kv.Value}
        }
        foreach($line in $lines){Write-Output $line}
        Require-Condition ($dockerExit -eq 0) "D4V_PATCH_DOCKER_EXIT::$dockerExit"
        Assert-ResultMarkers $lines

        Write-Output 'D4V_PRE_FREEZE_PATCH_V3_TARGET_STATUS=PASS'
        Write-Output 'D4V_REAL_SEED_CREATED=NO'
        Write-Output 'D4V_REAL_SEED_ACCESSED=NO'
        Write-Output 'D4V_MODEL_CALLS=0'
        Write-Output 'D4V_SCIENTIFIC_EXECUTION=NO'
        exit 0
    }finally{
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}catch{
    Write-Output 'D4V_PRE_FREEZE_PATCH_V3_TARGET_STATUS=FAIL'
    Write-Output ('D4V_PRE_FREEZE_PATCH_V3_ERROR='+$_.Exception.Message)
    Write-Output 'D4V_REAL_SEED_CREATED=NO'
    Write-Output 'D4V_REAL_SEED_ACCESSED=NO'
    exit 2
}finally{
    [Array]::Clear($helperBytes,0,$helperBytes.Length)
}
