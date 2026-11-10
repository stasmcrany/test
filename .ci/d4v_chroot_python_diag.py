import os, pathlib, resource, shutil, subprocess, sys, sysconfig, tempfile
def emit(k,v): print(f"{k}={v}",flush=True)
for p in ["/lib/x86_64-linux-gnu/libm.so.6","/lib/x86_64-linux-gnu/libz.so.1","/lib/x86_64-linux-gnu/libexpat.so.1","/lib/x86_64-linux-gnu/libc.so.6","/lib64/ld-linux-x86-64.so.2","/lib/x86_64-linux-gnu/libcrypto.so.3","/usr/local/lib/libpython3.12.so","/usr/local/lib/libpython3.12.so.1.0"]:
    emit("EXISTS_"+p.replace("/","_").replace(".","_"),pathlib.Path(p).exists())
cp=subprocess.run(["ldd","/usr/local/bin/python3.12"],text=True,capture_output=True)
emit("LDD_RC",cp.returncode); print(cp.stdout,flush=True); print(cp.stderr,flush=True)

def copy_file(src,dst,mode=0o555):
    src=pathlib.Path(src); dst=pathlib.Path(dst); dst.parent.mkdir(parents=True,exist_ok=True); shutil.copy2(src,dst); os.chmod(dst,mode)
def copy_runtime(root):
    py=pathlib.Path(sys.executable).resolve()
    stdlib=pathlib.Path(sysconfig.get_paths()["stdlib"]).resolve()
    prefix=pathlib.Path(sys.prefix).resolve()
    libdir=pathlib.Path(sysconfig.get_config_var("LIBDIR")).resolve()
    ldlib=sysconfig.get_config_var("LDLIBRARY")
    copy_file(py,root/py.relative_to("/"))
    shutil.copytree(stdlib,root/stdlib.relative_to("/"),dirs_exist_ok=True,ignore=shutil.ignore_patterns("__pycache__","site-packages"))
    for p in (root/stdlib.relative_to("/")).rglob("*"):
        try: os.chmod(p,0o555 if p.is_dir() else 0o444)
        except FileNotFoundError: pass
    libpython=(libdir/ldlib).resolve(); copy_file(libpython,root/libpython.relative_to("/"))
    for src in ["/lib/x86_64-linux-gnu/libm.so.6","/lib/x86_64-linux-gnu/libz.so.1","/lib/x86_64-linux-gnu/libexpat.so.1","/lib/x86_64-linux-gnu/libc.so.6","/lib64/ld-linux-x86-64.so.2","/lib/x86_64-linux-gnu/libcrypto.so.3"]:
        if not pathlib.Path(src).is_file(): raise RuntimeError("MISSING:"+src)
        copy_file(src,root/pathlib.Path(src).relative_to("/"))
    return "/"+str(py.relative_to("/")),str(prefix)

base=pathlib.Path(tempfile.mkdtemp(prefix="d4v_chrootpy_"))
try:
    root=base/"root"; root.mkdir()
    try:
        python_inside,python_home=copy_runtime(root); emit("COPY_RUNTIME","PASS")
    except Exception as e:
        emit("COPY_RUNTIME","FAIL:"+type(e).__name__+":"+str(e)); raise SystemExit(31)
    (root/"candidate").mkdir(); (root/"scratch").mkdir()
    (root/"candidate/probe.py").write_text('import hashlib,json,sys,time; print("INNER_OK",sys.version.split()[0],hashlib.sha256(b"x").hexdigest())\n',encoding="utf-8")
    os.chmod(root/"candidate/probe.py",0o444); os.chmod(root/"candidate",0o555)
    os.chown(root/"scratch",65534,65534); os.chmod(root/"scratch",0o700)
    def preexec():
        try:
            resource.setrlimit(resource.RLIMIT_NOFILE,(32,32))
            os.chroot(root); os.chdir("/scratch"); os.setgroups([]); os.setgid(65534); os.setuid(65534)
        except BaseException as e:
            try: os.write(2,("PREEXEC_FAIL="+type(e).__name__+":"+str(e)+"\n").encode())
            finally: os._exit(200)
    env={"PATH":"/usr/local/bin:/usr/bin","PYTHONHOME":python_home,"LD_LIBRARY_PATH":"/usr/local/lib","PYTHONDONTWRITEBYTECODE":"1","LANG":"C.UTF-8"}
    try:
        cp=subprocess.run([python_inside,"-I","/candidate/probe.py"],text=True,capture_output=True,timeout=10,env=env,preexec_fn=preexec)
        emit("INNER_RC",cp.returncode); emit("INNER_STDOUT",cp.stdout.strip().replace("\n","|")); emit("INNER_STDERR",cp.stderr.strip().replace("\n","|"))
    except Exception as e:
        emit("INNER_EXCEPTION",type(e).__name__+":"+str(e))
finally:
    shutil.rmtree(base,ignore_errors=True)
