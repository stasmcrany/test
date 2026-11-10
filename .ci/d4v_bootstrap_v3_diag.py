import ctypes, errno, os, pathlib, resource, shutil, subprocess, sys, sysconfig, tempfile, _hashlib, _json
def emit(k,v): print(f"{k}={v}",flush=True)
def copy_bytes_to_exact_path(src_path, root):
    original=pathlib.Path(src_path)
    resolved=original.resolve()
    dst=root/original.relative_to("/")
    dst.parent.mkdir(parents=True,exist_ok=True)
    shutil.copy2(resolved,dst)
    os.chmod(dst,0o555)
def ldd_deps(path):
    cp=subprocess.run(["ldd",str(path)],text=True,capture_output=True,check=True)
    out=[]
    for raw in cp.stdout.splitlines():
        line=raw.strip()
        if not line: continue
        candidate=None
        if "=>" in line:
            rhs=line.split("=>",1)[1].strip().split(" ",1)[0]
            if rhs.startswith("/"): candidate=rhs
        else:
            tok=line.split(" ",1)[0]
            if tok.startswith("/"): candidate=tok
        if candidate and candidate not in out: out.append(candidate)
    return out
def install_seccomp():
    lib=ctypes.CDLL("libseccomp.so.2")
    lib.seccomp_init.argtypes=[ctypes.c_uint32]; lib.seccomp_init.restype=ctypes.c_void_p
    lib.seccomp_syscall_resolve_name.argtypes=[ctypes.c_char_p]; lib.seccomp_syscall_resolve_name.restype=ctypes.c_int
    lib.seccomp_rule_add.argtypes=[ctypes.c_void_p,ctypes.c_uint32,ctypes.c_int,ctypes.c_uint32]; lib.seccomp_rule_add.restype=ctypes.c_int
    lib.seccomp_load.argtypes=[ctypes.c_void_p]; lib.seccomp_load.restype=ctypes.c_int
    lib.seccomp_release.argtypes=[ctypes.c_void_p]
    allow=0x7fff0000; deny=0x00050000 | (errno.EPERM & 0xffff)
    ctx=lib.seccomp_init(allow)
    if not ctx: raise RuntimeError("seccomp_init")
    try:
        for name in (b"socket",b"socketpair",b"connect",b"bind",b"listen",b"accept",b"accept4",b"sendto",b"recvfrom",b"sendmsg",b"recvmsg",b"ptrace",b"process_vm_readv",b"process_vm_writev",b"pidfd_getfd",b"fork",b"vfork",b"clone",b"clone3"):
            nr=lib.seccomp_syscall_resolve_name(name)
            if nr>=0:
                rc=lib.seccomp_rule_add(ctx,deny,nr,0)
                if rc!=0: raise RuntimeError(f"rule:{name!r}:{rc}")
        rc=lib.seccomp_load(ctx)
        if rc!=0: raise RuntimeError(f"load:{rc}")
    finally: lib.seccomp_release(ctx)
def copy_runtime(root):
    py=pathlib.Path(sys.executable).resolve()
    stdlib=pathlib.Path(sysconfig.get_paths()["stdlib"]).resolve()
    prefix=pathlib.Path(sys.prefix).resolve()
    if sys.version_info[:2]!=(3,12): raise RuntimeError("python-version")
    copy_bytes_to_exact_path(str(py),root)
    shutil.copytree(stdlib,root/stdlib.relative_to("/"),dirs_exist_ok=True,ignore=shutil.ignore_patterns("__pycache__","site-packages"))
    for p in (root/stdlib.relative_to("/")).rglob("*"):
        try: os.chmod(p,0o555 if p.is_dir() else 0o444)
        except FileNotFoundError: pass
    targets=[py,pathlib.Path(_hashlib.__file__).resolve(),pathlib.Path(_json.__file__).resolve()]
    deps=[]
    for t in targets:
        for d in ldd_deps(t):
            if d not in deps: deps.append(d)
    emit("D4V_BOOTSTRAP_V3_DEP_COUNT",len(deps))
    for d in deps:
        emit("D4V_BOOTSTRAP_V3_DEP",d)
        copy_bytes_to_exact_path(d,root)
    return "/"+str(py.relative_to("/")),str(prefix)
base=pathlib.Path(tempfile.mkdtemp(prefix="d4v_boot3_"))
try:
    root=base/"root"; root.mkdir()
    py_inside,py_home=copy_runtime(root)
    emit("D4V_BOOTSTRAP_V3_LOADER_AT_LIB64",(root/"lib64/ld-linux-x86-64.so.2").exists())
    (root/"candidate").mkdir(); (root/"scratch").mkdir()
    script=root/"candidate/probe.py"
    script.write_text('import builtins,hashlib,json,sys,time; print("D4V_BOOTSTRAP_V3_INNER_OK="+hashlib.sha256(b"x").hexdigest())\n',encoding="utf-8")
    os.chmod(script,0o444); os.chmod(root/"candidate",0o555); os.chown(root/"scratch",65534,65534); os.chmod(root/"scratch",0o700)
    def preexec():
        install_seccomp()
        resource.setrlimit(resource.RLIMIT_CPU,(3,3)); resource.setrlimit(resource.RLIMIT_AS,(768*1024*1024,768*1024*1024)); resource.setrlimit(resource.RLIMIT_FSIZE,(16*1024*1024,16*1024*1024)); resource.setrlimit(resource.RLIMIT_NOFILE,(32,32))
        try: resource.setrlimit(resource.RLIMIT_NPROC,(8,8))
        except (ValueError,OSError): pass
        os.chroot(root); os.chdir("/scratch"); os.setgroups([]); os.setgid(65534); os.setuid(65534); os.umask(0o077)
    env={"PATH":"/usr/local/bin:/usr/bin","PYTHONHOME":py_home,"PYTHONDONTWRITEBYTECODE":"1","LANG":"C.UTF-8"}
    cp=subprocess.run([py_inside,"-I","/candidate/probe.py"],text=True,capture_output=True,timeout=10,env=env,preexec_fn=preexec)
    emit("D4V_BOOTSTRAP_V3_INNER_RC",cp.returncode); emit("D4V_BOOTSTRAP_V3_INNER_STDOUT",cp.stdout.strip()); emit("D4V_BOOTSTRAP_V3_INNER_STDERR",cp.stderr.strip().replace("\n","|"))
    if cp.returncode!=0 or not cp.stdout.startswith("D4V_BOOTSTRAP_V3_INNER_OK="): raise SystemExit(41)
    emit("D4V_BOOTSTRAP_V3_STATUS","PASS")
finally:
    shutil.rmtree(base,ignore_errors=True)
