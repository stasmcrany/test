#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

REVISION = "A1_CAPTURE_LOCAL_MAIN_READONLY_V5"
DEFAULT_REPO = r"E:\Projects\stoixdome_recovery"
DEFAULT_OUTPUT = str(Path.home() / "Downloads" / "LOCAL_MAIN_CAPTURE_MANIFEST.json")
PRODUCT_ROOT_NAMES = {
    "Bunker", "EngineCore", "IAMCalibur", "DNS", "ui", "AxiomTerminal",
    "stoix_platform", "composition", "runtimes", "deployment", "build",
    "tests", "validation", "adapters", "AdaptersAWS", "Frontier"
}
CONFIG_RX = (
    r"^(core\.(worktree|sparseCheckout|sparseCheckoutCone|autocrlf|eol|"
    r"symlinks|longpaths|ignorecase|filemode)|extensions\.worktreeConfig|"
    r"submodule\..*\.(url|active|branch)|remote\..*\.url)$"
)
USERINFO_RX = re.compile(r"(?i)(https?://)[^/@\s]+@")

class CaptureError(RuntimeError):
    pass

def fail(msg: str) -> None:
    raise CaptureError(msg)

def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest().upper()

def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest().upper()

def run_git(repo: Path, *args: str, check: bool = True) -> subprocess.CompletedProcess[bytes]:
    cp = subprocess.run(
        ["git", "-C", str(repo), "-c", "core.quotepath=false", *args],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if check and cp.returncode != 0:
        fail(
            "GIT_FAILED::"
            + " ".join(args)
            + "::RC="
            + str(cp.returncode)
            + "::"
            + cp.stderr.decode("utf-8", "replace")[-1600:]
        )
    return cp

def git_text(repo: Path, *args: str, check: bool = True) -> str:
    return run_git(repo, *args, check=check).stdout.decode("utf-8", "surrogateescape").rstrip("\r\n")

def nul_paths(repo: Path, *args: str) -> list[str]:
    raw = run_git(repo, *args).stdout
    return sorted(
        x.decode("utf-8", "surrogateescape").replace("\\", "/")
        for x in raw.split(b"\0") if x
    )

def sanitize_line(s: str) -> str:
    return USERINFO_RX.sub(r"\1<REDACTED_USERINFO>@", s)

def pathset_sha(paths: list[str]) -> str:
    return sha256_bytes(("\n".join(sorted(paths)) + "\n").encode("utf-8", "surrogateescape"))

def win_ext(path: str) -> str:
    if os.name != "nt":
        return path
    p = os.path.abspath(path)
    if p.startswith("\\\\?\\"):
        return p
    if p.startswith("\\\\"):
        return "\\\\?\\UNC\\" + p[2:]
    return "\\\\?\\" + p

def win_unext(path: str) -> str:
    if path.startswith("\\\\?\\UNC\\"):
        return "\\\\" + path[8:]
    if path.startswith("\\\\?\\"):
        return path[4:]
    return path

def rel_from(repo_abs: str, full: str) -> str:
    rel = os.path.relpath(win_unext(full), repo_abs)
    return "." if rel == "." else rel.replace("\\", "/")

def filesystem_inventory(repo: Path) -> dict:
    repo_abs = os.path.abspath(str(repo))
    root_scan = win_ext(repo_abs)
    files: list[str] = []
    dirs: list[str] = []
    redirects: list[dict] = []
    stack: list[str] = [root_scan]
    errors: list[dict] = []

    while stack:
        current = stack.pop()
        try:
            entries = sorted(os.scandir(current), key=lambda e: e.name.lower())
        except OSError as exc:
            errors.append({"path": rel_from(repo_abs, current), "error": repr(exc)})
            continue

        for entry in entries:
            if rel_from(repo_abs, entry.path) == ".git":
                continue
            rel = rel_from(repo_abs, entry.path)
            try:
                is_link = entry.is_symlink()
                attrs = 0
                try:
                    st = entry.stat(follow_symlinks=False)
                    attrs = int(getattr(st, "st_file_attributes", 0) or 0)
                except OSError:
                    st = None
                is_reparse = bool(
                    os.name == "nt"
                    and attrs
                    and hasattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT")
                    and (attrs & stat.FILE_ATTRIBUTE_REPARSE_POINT)
                )
                is_redirect = is_link or is_reparse
                if is_redirect:
                    target = None
                    try:
                        target = os.readlink(entry.path)
                    except OSError:
                        pass
                    redirects.append(
                        {
                            "path": rel,
                            "kind": "SYMLINK" if is_link else "REPARSE_POINT_OR_JUNCTION",
                            "target": target,
                        }
                    )
                    continue
                if entry.is_dir(follow_symlinks=False):
                    dirs.append(rel)
                    stack.append(entry.path)
                elif entry.is_file(follow_symlinks=False):
                    files.append(rel)
                else:
                    redirects.append({"path": rel, "kind": "OTHER_NONREGULAR", "target": None})
            except OSError as exc:
                errors.append({"path": rel, "error": repr(exc)})

    files = sorted(set(files))
    dirs = sorted(set(dirs))
    redirects = sorted(redirects, key=lambda x: (x["path"], x["kind"]))
    if errors:
        fail("FILESYSTEM_INVENTORY_ERRORS::" + json.dumps(errors[:20], ensure_ascii=False))
    return {
        "files": files,
        "directories": dirs,
        "redirects": redirects,
        "file_count": len(files),
        "directory_count": len(dirs),
        "redirect_count": len(redirects),
        "error_count": 0,
        "file_pathset_sha256": pathset_sha(files),
    }

def index_path(repo: Path) -> Path:
    raw = git_text(repo, "rev-parse", "--git-path", "index")
    p = Path(raw)
    if not p.is_absolute():
        p = repo / p
    return p.resolve()

def capture_state(repo: Path) -> dict:
    branch_cp = run_git(repo, "symbolic-ref", "--short", "-q", "HEAD", check=False)
    branch = branch_cp.stdout.decode("utf-8", "replace").strip() or "DETACHED"
    head = git_text(repo, "rev-parse", "HEAD")
    tree = git_text(repo, "rev-parse", "HEAD^{tree}")
    status_raw = run_git(
        repo, "status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all"
    ).stdout
    idx = index_path(repo)
    return {
        "branch": branch,
        "head": head,
        "tree": tree,
        "status_sha256": sha256_bytes(status_raw),
        "status_bytes": len(status_raw),
        "index_path": str(idx),
        "index_sha256": sha256_file(idx),
    }

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", default=DEFAULT_REPO)
    ap.add_argument("--output", default=DEFAULT_OUTPUT)
    ns = ap.parse_args()

    repo = Path(ns.repo).resolve()
    output = Path(ns.output).expanduser().resolve()
    if not repo.is_dir():
        fail(f"REPO_NOT_FOUND::{repo}")
    top = Path(git_text(repo, "rev-parse", "--show-toplevel")).resolve()
    if top != repo:
        repo = top

    try:
        output.relative_to(repo)
        fail(f"REFUSE_OUTPUT_INSIDE_REPOSITORY::{output}")
    except ValueError:
        pass

    before = capture_state(repo)

    tracked = nul_paths(repo, "ls-files", "-z")
    untracked = nul_paths(repo, "ls-files", "--others", "--exclude-standard", "-z")
    ignored = nul_paths(repo, "ls-files", "--others", "--ignored", "--exclude-standard", "-z")

    sub_cp = run_git(repo, "submodule", "status", "--recursive", check=False)
    if sub_cp.returncode not in (0,):
        fail("SUBMODULE_STATUS_FAILED::" + sub_cp.stderr.decode("utf-8", "replace")[-1600:])
    submodules = [
        x for x in sub_cp.stdout.decode("utf-8", "surrogateescape").splitlines() if x.strip()
    ]

    worktrees = [
        x for x in git_text(repo, "worktree", "list", "--porcelain").splitlines() if x.strip()
    ]

    cfg_cp = run_git(repo, "config", "--show-origin", "--get-regexp", CONFIG_RX, check=False)
    if cfg_cp.returncode not in (0, 1):
        fail("GIT_CONFIG_QUERY_FAILED::" + cfg_cp.stderr.decode("utf-8", "replace")[-1600:])
    config_lines = [
        sanitize_line(x)
        for x in cfg_cp.stdout.decode("utf-8", "surrogateescape").splitlines()
        if x.strip()
    ]

    remotes = [
        sanitize_line(x)
        for x in git_text(repo, "remote", "-v").splitlines()
        if x.strip()
    ]

    fs = filesystem_inventory(repo)
    tracked_set = set(tracked)

    candidate_roots = sorted(
        {
            p.split("/", 1)[0]
            for p in fs["files"]
            if "/" in p and p.split("/", 1)[0] in PRODUCT_ROOT_NAMES
        }
        | {
            p for p in fs["directories"]
            if "/" not in p and p in PRODUCT_ROOT_NAMES
        }
    )
    local_only = sorted(
        p for p in fs["files"]
        if p not in tracked_set
        and p.split("/", 1)[0] in PRODUCT_ROOT_NAMES
    )

    after = capture_state(repo)
    mutation_proof = {
        "branch_unchanged": before["branch"] == after["branch"],
        "head_unchanged": before["head"] == after["head"],
        "tree_unchanged": before["tree"] == after["tree"],
        "status_unchanged": before["status_sha256"] == after["status_sha256"],
        "index_unchanged": before["index_sha256"] == after["index_sha256"],
    }
    mutation_proof["all_readonly_invariants_hold"] = all(mutation_proof.values())
    if not mutation_proof["all_readonly_invariants_hold"]:
        fail("READONLY_INVARIANT_CHANGED::" + json.dumps(mutation_proof, sort_keys=True))

    payload = {
        "schema": "stoixlab.zero_reset.a1.local_main_capture.v5",
        "revision": REVISION,
        "captured_at_utc": datetime.now(timezone.utc).isoformat(),
        "a1_capture_complete": True,
        "repository": {
            "absolute_path": str(repo),
            "branch": after["branch"],
            "head": after["head"],
            "tree": after["tree"],
        },
        "git_state": {
            "status_sha256": after["status_sha256"],
            "status_bytes": after["status_bytes"],
            "index_sha256": after["index_sha256"],
        },
        "git_inventory": {
            "tracked": tracked,
            "untracked": untracked,
            "ignored": ignored,
            "tracked_count": len(tracked),
            "untracked_count": len(untracked),
            "ignored_count": len(ignored),
            "tracked_pathset_sha256": pathset_sha(tracked),
            "untracked_pathset_sha256": pathset_sha(untracked),
            "ignored_pathset_sha256": pathset_sha(ignored),
            "submodule_status_lines": submodules,
            "worktree_porcelain_lines": worktrees,
            "source_resolution_git_config": config_lines,
            "remotes_sanitized": remotes,
        },
        "filesystem_inventory": fs,
        "local_only": {
            "candidate_product_roots": candidate_roots,
            "files_under_candidate_product_roots": local_only,
            "file_count": len(local_only),
            "pathset_sha256": pathset_sha(local_only),
        },
        "two_independent_inventory_paths": {
            "git_derived": True,
            "filesystem_derived": True,
        },
        "mutation_proof": mutation_proof,
        "safety": {
            "source_mutations": 0,
            "git_mutations": 0,
            "aws_calls": 0,
            "aws_mutations": 0,
            "deployment": "NOT_PERFORMED",
            "snapshot": "NOT_CREATED",
        },
    }
    rendered = json.dumps(payload, ensure_ascii=False, sort_keys=True, indent=2) + "\n"
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(rendered, encoding="utf-8", newline="\n")

    print("A1_LOCAL_MAIN_CAPTURE=PASS")
    print(f"REPO={repo}")
    print(f"BRANCH={after['branch']}")
    print(f"HEAD={after['head']}")
    print(f"TREE={after['tree']}")
    print(f"TRACKED={len(tracked)}")
    print(f"UNTRACKED={len(untracked)}")
    print(f"IGNORED={len(ignored)}")
    print(f"FS_FILES={fs['file_count']}")
    print(f"FS_REDIRECTS={fs['redirect_count']}")
    print(f"LOCAL_ONLY_PRODUCT_FILES={len(local_only)}")
    print("READONLY_INVARIANTS=PASS")
    print(f"OUTPUT={output}")
    print(f"OUTPUT_SHA256={sha256_bytes(rendered.encode('utf-8'))}")
    return 0

if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except CaptureError as exc:
        print(f"A1_LOCAL_MAIN_CAPTURE=FAIL::{exc}", file=sys.stderr)
        raise SystemExit(1)
