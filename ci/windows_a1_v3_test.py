from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

EXPECTED_RUNNER_SHA256 = "F9009BD2984C5C77A23FD24E2F1E95D75B1C95A01A7EFC9C2856DBAA4813652A"
RUNNER = Path(__file__).with_name("A1_CAPTURE_LOCAL_MAIN_READONLY_V3.py")


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest().upper()


def run(args: list[str], cwd: Path | None = None, check: bool = True) -> subprocess.CompletedProcess[str]:
    cp = subprocess.run(args, cwd=str(cwd) if cwd else None, text=True, capture_output=True)
    if check and cp.returncode != 0:
        raise RuntimeError(
            f"COMMAND_FAILED rc={cp.returncode} cwd={cwd} args={args}\n"
            f"STDOUT:\n{cp.stdout}\nSTDERR:\n{cp.stderr}"
        )
    return cp


def must(name: str, condition: bool) -> None:
    print(f"{name}={'PASS' if condition else 'FAIL'}")
    if not condition:
        raise RuntimeError(name)


def main() -> int:
    print("A1_V3_WINDOWS_TEST_BEGIN")
    must("WINDOWS_OS", os.name == "nt")
    must("WINDOWS_PLATFORM", sys.platform == "win32")
    must("RUNNER_EXISTS", RUNNER.is_file())
    actual_runner_sha = sha256_file(RUNNER)
    print("RUNNER_SHA256=" + actual_runner_sha)
    must("RUNNER_SHA_MATCH", actual_runner_sha == EXPECTED_RUNNER_SHA256)

    downloads = Path.home() / "Downloads"
    downloads.mkdir(parents=True, exist_ok=True)
    default_output = downloads / "LOCAL_MAIN_CAPTURE_MANIFEST.json"
    if default_output.exists():
        default_output.unlink()

    with tempfile.TemporaryDirectory(prefix="a1 v3 windows fixture ") as td_raw:
        td = Path(td_raw)
        repo = td / "repo with space"
        subrepo = td / "submodule source"
        worktree = td / "linked worktree"
        repo.mkdir()
        subrepo.mkdir()

        run(["git", "init"], cwd=subrepo)
        run(["git", "config", "user.email", "sub@example.com"], cwd=subrepo)
        run(["git", "config", "user.name", "Sub"], cwd=subrepo)
        (subrepo / "sub.txt").write_text("submodule\n", encoding="utf-8")
        run(["git", "add", "."], cwd=subrepo)
        run(["git", "commit", "-m", "sub"], cwd=subrepo)

        run(["git", "init"], cwd=repo)
        run(["git", "config", "user.email", "main@example.com"], cwd=repo)
        run(["git", "config", "user.name", "Main"], cwd=repo)
        run(["git", "config", "core.autocrlf", "false"], cwd=repo)
        run(["git", "config", "core.longpaths", "true"], cwd=repo)
        run(["git", "remote", "add", "origin", "https://fake-token@example.invalid/owner/repo.git"], cwd=repo)

        for d in ["Bunker", "deployment", "stoix_platform", "tests", "validation"]:
            (repo / d).mkdir()

        (repo / "Bunker" / "tracked.py").write_text("print('tracked')\n", encoding="utf-8")
        (repo / "deployment" / "template.yaml").write_text("Resources: {}\n", encoding="utf-8")
        (repo / "validation" / "contract.txt").write_text("contract\n", encoding="utf-8")
        (repo / ".gitignore").write_text("*.secret\nignored_dir/\n", encoding="utf-8")

        deep = repo / "stoix_platform" / ("a" * 80) / ("b" * 80) / ("c" * 80)
        deep.mkdir(parents=True)
        (deep / "long_tracked.py").write_text("x=1\n", encoding="utf-8")
        print("LONG_PATH_CHARS=" + str(len(str(deep / "long_tracked.py"))))

        run(
            ["git", "-c", "protocol.file.allow=always", "submodule", "add", str(subrepo), "vendor/sub"],
            cwd=repo,
        )
        run(["git", "add", "."], cwd=repo)
        run(["git", "commit", "-m", "baseline"], cwd=repo)
        run(["git", "worktree", "add", "-b", "test-extra", str(worktree), "HEAD"], cwd=repo)

        (repo / "Bunker" / "tracked.py").write_text("print('modified')\n", encoding="utf-8")
        (repo / "Bunker" / "new_local.py").write_text("LOCAL=1\n", encoding="utf-8")
        (repo / "Bunker" / "credential.secret").write_text("dummy\n", encoding="utf-8")
        (repo / "ignored_dir").mkdir()
        (repo / "ignored_dir" / "ignored.txt").write_text("ignored\n", encoding="utf-8")
        (repo / "build").mkdir()
        (repo / "build" / "untracked_build_input.txt").write_text("build-only\n", encoding="utf-8")

        junction = repo / "deployment_junction"
        cp_junction = run(
            ["cmd", "/c", "mklink", "/J", str(junction), str(repo / "deployment")],
            cwd=repo,
            check=False,
        )
        print("MKLINK_RC=" + str(cp_junction.returncode))
        print(cp_junction.stdout.strip())
        print(cp_junction.stderr.strip())
        must("WINDOWS_JUNCTION_CREATED", cp_junction.returncode == 0 and junction.exists())

        status_before = subprocess.run(
            ["git", "-c", "core.quotepath=false", "status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all"],
            cwd=str(repo), capture_output=True, check=True
        ).stdout
        index_before = hashlib.sha256((repo / ".git" / "index").read_bytes()).hexdigest()

        cp = run([sys.executable, str(RUNNER), "--repo", str(repo)], check=False)
        print("RUNNER_RC=" + str(cp.returncode))
        print(cp.stdout)
        print(cp.stderr)
        must("RUNNER_RC_ZERO", cp.returncode == 0)
        must("DEFAULT_OUTPUT_EXISTS", default_output.is_file())

        data = json.loads(default_output.read_text(encoding="utf-8"))
        must("CAPTURE_COMPLETE", data["a1_capture_complete"] is True)
        must("READONLY_INVARIANTS", data["mutation_proof"]["all_readonly_invariants_hold"] is True)
        must("TARGET_OS_RECORDED", data["environment"]["os_name"] == "nt")
        must("TARGET_PLATFORM_RECORDED", data["environment"]["sys_platform"] == "win32")
        must("IGNORED_CAPTURED", "Bunker/credential.secret" in data["git_inventory"]["ignored"])
        must("UNTRACKED_CAPTURED", "Bunker/new_local.py" in data["git_inventory"]["untracked"])
        must("SUBMODULE_CAPTURED", any("vendor/sub" in x for x in data["git_inventory"]["submodule_status_lines"]))
        norm_wt = str(worktree).replace("\\", "/").lower()
        must(
            "WORKTREE_CAPTURED",
            any(norm_wt in x.replace("\\", "/").lower() for x in data["git_inventory"]["worktree_porcelain_lines"]),
        )
        must(
            "SOURCE_CONFIG_CAPTURED",
            any("core.longpaths" in x.lower() for x in data["git_inventory"]["source_resolution_git_config"]),
        )
        must(
            "CONFIG_URL_REDACTED",
            any("<REDACTED_USERINFO>@" in x for x in data["git_inventory"]["source_resolution_git_config"]),
        )
        must(
            "REMOTE_URL_REDACTED",
            any("<REDACTED_USERINFO>@" in x for x in data["git_inventory"]["remotes_sanitized"]),
        )
        redirects = {x["path"]: x for x in data["filesystem_inventory"]["redirects"]}
        must("JUNCTION_CAPTURED", "deployment_junction" in redirects)
        must(
            "JUNCTION_CLASSIFIED_REPARSE",
            redirects["deployment_junction"]["kind"] == "JUNCTION_OR_REPARSE_POINT",
        )
        must("FILESYSTEM_ERRORS_ZERO", data["filesystem_inventory"]["error_count"] == 0)
        must(
            "LONG_PATH_CAPTURED",
            any(p.endswith("long_tracked.py") for p in data["filesystem_inventory"]["files"]),
        )
        must("BUILD_ROOT_DETECTED", "build" in data["local_only"]["candidate_product_roots"])
        must(
            "LOCAL_ONLY_BUILD_CAPTURED",
            "build/untracked_build_input.txt" in data["local_only"]["files_under_candidate_product_roots"],
        )

        status_after = subprocess.run(
            ["git", "-c", "core.quotepath=false", "status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all"],
            cwd=str(repo), capture_output=True, check=True
        ).stdout
        index_after = hashlib.sha256((repo / ".git" / "index").read_bytes()).hexdigest()
        must("STATUS_BYTE_IDENTITY", status_before == status_after)
        must("INDEX_SHA_IDENTITY", index_before == index_after)

        bad = run(
            [sys.executable, str(RUNNER), "--repo", str(repo), "--output", str(repo / "BAD_OUTPUT.json")],
            check=False,
        )
        print("NEGATIVE_RC=" + str(bad.returncode))
        print(bad.stderr)
        must("OUTPUT_INSIDE_REPO_FAIL_CLOSED", bad.returncode == 1 and "output path is inside repository" in bad.stderr)

        run(["git", "worktree", "remove", "--force", str(worktree)], cwd=repo, check=False)

    if default_output.exists():
        default_output.unlink()

    print("A1_V3_WINDOWS_TEST=PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

# trigger self-contained workflow revision 1
