import ctypes, ctypes.util, os, pathlib, subprocess, sys, sysconfig, tempfile, shutil
def emit(k,v): print(f"{k}={v}", flush=True)
emit("PYTHON",sys.version.split()[0])
emit("EXECUTABLE",sys.executable)
emit("STDLIB",sysconfig.get_paths()["stdlib"])
emit("PREFIX",sys.prefix)
emit("LIBDIR",sysconfig.get_config_var("LIBDIR"))
emit("LDLIBRARY",sysconfig.get_config_var("LDLIBRARY"))
for p in ["/usr/local/bin/python3.12","/usr/local/lib/python3.12","/usr/local/lib/libpython3.12.so.1.0","/lib/x86_64-linux-gnu/libseccomp.so.2","/usr/lib/x86_64-linux-gnu/libseccomp.so.2"]:
    emit("PATH_"+p.replace("/","_").replace(".","_"), pathlib.Path(p).exists())
emit("FIND_SECCOMP",ctypes.util.find_library("seccomp"))
try:
    ctypes.CDLL("libseccomp.so.2"); emit("CDLL_SECCOMP","PASS")
except Exception as e:
    emit("CDLL_SECCOMP","FAIL:"+type(e).__name__+":"+str(e))
tmp=pathlib.Path(tempfile.mkdtemp(prefix="d4v_capdiag_"))
try:
    s=tmp/"scratch"; s.mkdir()
    try:
        os.chown(s,65534,65534); emit("CHOWN_65534","PASS")
    except Exception as e:
        emit("CHOWN_65534","FAIL:"+type(e).__name__+":"+str(e))
    r=tmp/"root"; r.mkdir(); (r/"scratch").mkdir()
    pid=os.fork()
    if pid==0:
        try:
            os.chroot(r); os.chdir("/scratch"); os.setgroups([]); os.setgid(65534); os.setuid(65534); os._exit(0)
        except BaseException as e:
            try: os.write(2,("CHROOT_CHILD_FAIL="+type(e).__name__+":"+str(e)+"\n").encode())
            finally: os._exit(201)
    _,status=os.waitpid(pid,0)
    emit("CHROOT_DROP_RC",os.waitstatus_to_exitcode(status))
finally:
    shutil.rmtree(tmp,ignore_errors=True)
