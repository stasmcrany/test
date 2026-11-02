#!/usr/bin/env python3
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import re
import subprocess
import sys
import stat
from pathlib import Path
from typing import Any

SCHEMA_VERSION = "stoixlab.zero_reset.a1.local_main_capture.v2"
DEFAULT_REPO = r"E:\Projects\stoixdome_recovery"
PRODUCT_ROOT_HINTS = {
    "Bunker", "applied", "composition", "core", "deployment",
    "product_domains", "runtimes", "skins", "stoix_platform", "ui", "tests",
    "validation", "build",
}
SAFE_CONFIG_RE = (
    r"^(core\.(autocrlf|eol|filemode|symlinks|ignorecase|protectNTFS|longpaths|worktree|bare|"
    r"sparseCheckout|sparseCheckoutCone|attributesFile|excludesFile|hooksPath)"
    r"|extensions\..*"
    r"|branch\..*\.(remote|merge|rebase)"
    r"|remote\..*\.(url|pushurl|fetch|mirror|promisor|partialclonefilter)"
    r"|submodule\..*\.(path|url|active|branch|update)"
    r"|include\.path|includeIf\..*\.path"
    r"|url\..*\.(insteadOf|pushInsteadOf)"
    r"|protocol\..*\.allow|fetch\.recurseSubmodules|worktree\.guessRemote|safe\.directory)$"
)

class CaptureError(RuntimeError):
    pass


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest().upper()


def sha256_file(path: Path) -> str | None:
    if not path.is_file():
        return None
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest().upper()


def pathset_sha256(paths: list[str]) -> str:
    return sha256_bytes(("\n".join(sorted(paths)) + "\n").encode("utf-8", "surrogateescape"))


def decode(data: bytes) -> str:
    return data.decode("utf-8", "surrogateescape")


def split_nul(data: bytes) -> list[str]:
    if not data:
        return []
    return [decode(x) for x in data.split(b"\0") if x]


def sanitize_config_line(s: str) -> str:
    # Redact password/token-like userinfo in URL values without destroying source-resolution topology.
    return re.sub(r"([A-Za-z][A-Za-z0-9+.-]*://)[^/@\s]+@", r"\1<REDACTED_USERINFO>@", s)


def git(repo: Path, *args: str, allow_rc: set[int] | None = None) -> subprocess.CompletedProcess[bytes]:
    env = os.environ.copy()
    env["GIT_OPTIONAL_LOCKS"] = "0"
    env["GIT_TERMINAL_PROMPT"] = "0"
    env["LC_ALL"] = "C"
    cp = subprocess.run(
        ["git", *args],
        cwd=str(repo),
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    allowed = {0} if allow_rc is None else allow_rc
    if cp.returncode not in allowed:
        raise CaptureError(
            f"git {' '.join(args)} failed rc={cp.returncode}: {decode(cp.stderr).strip()}"
        )
    return cp


def resolve_git_dir(repo: Path) -> Path:
    raw = decode(git(repo, "rev-parse", "--git-dir").stdout).strip()
    p = Path(raw)
    if not p.is_absolute():
        p = repo / p
    return p.resolve()


def repo_state(repo: Path, git_dir: Path) -> dict[str, Any]:
    head = decode(git(repo, "rev-parse", "HEAD").stdout).strip()
    tree = decode(git(repo, "rev-parse", "HEAD^{tree}").stdout).strip()
    branch_cp = git(repo, "symbolic-ref", "--quiet", "--short", "HEAD", allow_rc={0, 1})
    branch = decode(branch_cp.stdout).strip() if branch_cp.returncode == 0 else "DETACHED"
    status_raw = git(
        repo, "-c", "core.quotepath=false", "status", "--porcelain=v2", "-z",
        "--branch", "--untracked-files=all",
    ).stdout
    index = git_dir / "index"
    return {
        "head": head,
        "tree": tree,
        "branch": branch,
        "status_raw_sha256": sha256_bytes(status_raw),
        "status_records": split_nul(status_raw),
        "index_exists": index.is_file(),
        "index_sha256": sha256_file(index),
        "index_size": index.stat().st_size if index.is_file() else None,
    }


def git_inventory(repo: Path) -> dict[str, Any]:
    tracked = sorted(split_nul(git(repo, "-c", "core.quotepath=false", "ls-files", "-z").stdout))
    untracked = sorted(split_nul(git(
        repo, "-c", "core.quotepath=false", "ls-files", "--others", "--exclude-standard", "-z"
    ).stdout))
    ignored = sorted(split_nul(git(
        repo, "-c", "core.quotepath=false", "ls-files", "--others", "-i", "--exclude-standard", "-z"
    ).stdout))
    staged = split_nul(git(
        repo, "-c", "core.quotepath=false", "diff", "--cached", "--name-status", "-z"
    ).stdout)
    unstaged = split_nul(git(
        repo, "-c", "core.quotepath=false", "diff", "--name-status", "-z"
    ).stdout)
    worktrees = decode(git(repo, "worktree", "list", "--porcelain").stdout).splitlines()
    submodules_cp = git(repo, "submodule", "status", "--recursive", allow_rc={0, 1})
    submodules = decode(submodules_cp.stdout).splitlines()
    cfg_cp = git(repo, "config", "--show-origin", "--get-regexp", SAFE_CONFIG_RE, allow_rc={0, 1})
    config = [sanitize_config_line(x) for x in decode(cfg_cp.stdout).splitlines() if x.strip()]
    remote_cp = git(repo, "remote", "-v", allow_rc={0})
    remotes = [sanitize_config_line(x) for x in decode(remote_cp.stdout).splitlines() if x.strip()]
    return {
        "tracked": tracked,
        "untracked": untracked,
        "ignored": ignored,
        "staged_name_status_tokens": staged,
        "unstaged_name_status_tokens": unstaged,
        "worktree_porcelain_lines": worktrees,
        "submodule_status_lines": submodules,
        "source_resolution_git_config": config,
        "remotes_sanitized": remotes,
        "tracked_count": len(tracked),
        "untracked_count": len(untracked),
        "ignored_count": len(ignored),
        "tracked_path_set_sha256": pathset_sha256(tracked),
        "untracked_path_set_sha256": pathset_sha256(untracked),
        "ignored_path_set_sha256": pathset_sha256(ignored),
    }


def same_path(a: str, b: str) -> bool:
    return os.path.normcase(os.path.normpath(a)) == os.path.normcase(os.path.normpath(b))


def filesystem_inventory(repo: Path) -> dict[str, Any]:
    files: list[str] = []
    dirs: list[str] = []
    redirects: list[dict[str, str]] = []
    errors: list[dict[str, str]] = []

    stack = [repo]
    repo_abs = os.path.abspath(str(repo))

    while stack:
        current = stack.pop()
        try:
            with os.scandir(current) as it:
                entries = list(it)
        except OSError as e:
            rel = Path(current).relative_to(repo).as_posix() if Path(current) != repo else "."
            errors.append({"path": rel, "error": f"{type(e).__name__}: {e}"})
            continue

        for entry in entries:
            if Path(current) == repo and entry.name == ".git":
                continue
            p = Path(entry.path)
            try:
                rel = p.relative_to(repo).as_posix()
            except ValueError:
                errors.append({"path": str(p), "error": "PATH_ESCAPED_REPO_DURING_SCAN"})
                continue

            try:
                abs_p = os.path.abspath(entry.path)
                real_p = os.path.realpath(entry.path)
                is_symlink = entry.is_symlink()
                st = entry.stat(follow_symlinks=False)
                attrs = getattr(st, "st_file_attributes", 0)
                is_reparse = bool(attrs & stat.FILE_ATTRIBUTE_REPARSE_POINT)
                is_redirect = is_symlink or is_reparse or not same_path(abs_p, real_p)
                if is_redirect:
                    redirects.append({
                        "path": rel,
                        "kind": "SYMLINK" if is_symlink else (
                            "JUNCTION_OR_REPARSE_POINT" if is_reparse else "REDIRECT"
                        ),
                        "resolved_target": real_p,
                    })
                    continue
                if entry.is_dir(follow_symlinks=False):
                    dirs.append(rel)
                    stack.append(p)
                    continue
                if entry.is_file(follow_symlinks=False):
                    files.append(rel)
                    continue
                errors.append({"path": rel, "error": "UNCLASSIFIED_FILESYSTEM_ENTRY"})
            except OSError as e:
                errors.append({"path": rel, "error": f"{type(e).__name__}: {e}"})

    files.sort()
    dirs.sort()
    redirects.sort(key=lambda x: x["path"])
    errors.sort(key=lambda x: x["path"])
    return {
        "files": files,
        "directories": dirs,
        "redirects": redirects,
        "errors": errors,
        "file_count": len(files),
        "directory_count": len(dirs),
        "redirect_count": len(redirects),
        "error_count": len(errors),
        "file_path_set_sha256": pathset_sha256(files),
        "directory_path_set_sha256": pathset_sha256(dirs),
    }


def is_under(path: str, roots: set[str]) -> bool:
    top = path.split("/", 1)[0]
    return top in roots


def main() -> int:
    ap = argparse.ArgumentParser(description="Read-only A1 capture of actual local main")
    ap.add_argument("--repo", default=os.environ.get("STOIX_REPO", DEFAULT_REPO))
    ap.add_argument("--output", default=None)
    args = ap.parse_args()

    repo_input = Path(args.repo).expanduser()
    if not repo_input.is_dir():
        raise CaptureError(f"repository directory does not exist: {repo_input}")

    repo = Path(decode(git(repo_input, "rev-parse", "--show-toplevel").stdout).strip()).resolve()
    git_dir = resolve_git_dir(repo)

    default_output = Path.home() / "Downloads" / "LOCAL_MAIN_CAPTURE_MANIFEST.json"
    output = Path(args.output).expanduser().resolve() if args.output else default_output.resolve()
    try:
        output.relative_to(repo)
        raise CaptureError("output path is inside repository; refusing to write into source tree")
    except ValueError:
        pass

    before = repo_state(repo, git_dir)
    gi = git_inventory(repo)
    fi = filesystem_inventory(repo)
    after = repo_state(repo, git_dir)

    tracked = set(gi["tracked"])
    untracked = set(gi["untracked"])
    ignored = set(gi["ignored"])
    fs_files = set(fi["files"])
    fs_redirects = {x["path"] for x in fi["redirects"]}
    fs_entries = fs_files | fs_redirects
    classified = tracked | untracked | ignored

    product_roots = sorted(
        root for root in PRODUCT_ROOT_HINTS
        if os.path.lexists(str(repo / root))
    )
    local_only_files = sorted(
        p for p in (fs_files - tracked)
        if is_under(p, set(product_roots))
    )
    local_only_redirects = sorted(
        p for p in (fs_redirects - tracked)
        if is_under(p, set(product_roots))
    )
    local_only_entries = sorted(set(local_only_files) | set(local_only_redirects))

    mutation_proof = {
        "head_unchanged": before["head"] == after["head"],
        "tree_unchanged": before["tree"] == after["tree"],
        "branch_unchanged": before["branch"] == after["branch"],
        "status_unchanged": before["status_raw_sha256"] == after["status_raw_sha256"],
        "index_sha256_unchanged": before["index_sha256"] == after["index_sha256"],
    }
    mutation_proof["all_readonly_invariants_hold"] = all(mutation_proof.values())

    manifest = {
        "schema_version": SCHEMA_VERSION,
        "captured_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
        "capture_mode": "READ_ONLY",
        "repository": {
            "absolute_path": str(repo),
            "git_dir": str(git_dir),
            "branch": after["branch"],
            "head": after["head"],
            "tree": after["tree"],
        },
        "git_state_before": before,
        "git_state_after": after,
        "git_inventory": gi,
        "filesystem_inventory": fi,
        "environment": {
            "os_name": os.name,
            "sys_platform": sys.platform,
            "python_version": sys.version,
        },
        "crosscheck": {
            "git_classified_entry_count": len(classified),
            "git_classified_missing_from_filesystem": sorted(classified - fs_entries),
            "filesystem_entries_not_classified_by_git": sorted(fs_entries - classified),
            "git_classified_missing_from_filesystem_count": len(classified - fs_entries),
            "filesystem_entries_not_classified_by_git_count": len(fs_entries - classified),
        },
        "local_only": {
            "candidate_product_roots": product_roots,
            "files_under_candidate_product_roots": local_only_files,
            "redirects_under_candidate_product_roots": local_only_redirects,
            "entries_under_candidate_product_roots": local_only_entries,
            "count": len(local_only_entries),
            "path_set_sha256": pathset_sha256(local_only_entries),
        },
        "mutation_proof": mutation_proof,
        "source_mutations": 0 if mutation_proof["all_readonly_invariants_hold"] else "UNPROVEN",
        "git_mutations": 0 if mutation_proof["all_readonly_invariants_hold"] else "UNPROVEN",
        "aws_calls": 0,
        "aws_mutations": 0,
        "snapshot_created": False,
        "deployment_performed": False,
        "a1_capture_complete": bool(
            mutation_proof["all_readonly_invariants_hold"]
            and fi["error_count"] == 0
        ),
    }

    output.parent.mkdir(parents=True, exist_ok=True)
    rendered = json.dumps(manifest, indent=2, sort_keys=True, ensure_ascii=True) + "\n"
    output.write_text(rendered, encoding="utf-8", newline="\n")

    print("A1_LOCAL_MAIN_CAPTURE=" + ("PASS" if manifest["a1_capture_complete"] else "FAIL_CLOSED"))
    print("REPO=" + str(repo))
    print("BRANCH=" + after["branch"])
    print("HEAD=" + after["head"])
    print("TREE=" + after["tree"])
    print(f"TRACKED={gi['tracked_count']}")
    print(f"UNTRACKED={gi['untracked_count']}")
    print(f"IGNORED={gi['ignored_count']}")
    print(f"FS_FILES={fi['file_count']}")
    print(f"FS_REDIRECTS={fi['redirect_count']}")
    print(f"FS_ERRORS={fi['error_count']}")
    print(f"LOCAL_ONLY_PRODUCT_ENTRIES={len(local_only_entries)}")
    print("READONLY_INVARIANTS=" + ("PASS" if mutation_proof["all_readonly_invariants_hold"] else "FAIL"))
    print("OUTPUT=" + str(output))
    print("OUTPUT_SHA256=" + sha256_file(output))
    return 0 if manifest["a1_capture_complete"] else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except CaptureError as e:
        print(f"A1_LOCAL_MAIN_CAPTURE=FAIL_CLOSED::{e}", file=sys.stderr)
        raise SystemExit(1)
