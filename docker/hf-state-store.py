#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import re
import shutil
import socket
import sys
import tarfile
import tempfile
from datetime import datetime, timezone
from pathlib import Path

from huggingface_hub import CommitOperationAdd, HfApi, hf_hub_download
from huggingface_hub.errors import EntryNotFoundError, RepositoryNotFoundError

# 备份时排除的路径（匹配 tar 成员相对路径）。只排除"可保证再生"的产物，
# 用户内容（node_modules、.git 等）一律保留——配合 hash 去重，未变化的内容
# 不会重复上传，无需用丢弃用户数据的方式换体积。
EXCLUDE_PATTERNS = [
    r"(^|/)__pycache__/",   # Python 字节码缓存（import 时自动再生）
    r"\.pyc$",              # Python 字节码文件
    r"(^|/)\.cache/",       # 工具缓存（如飞书插件，启动时按需重新下载）
    r"\.log$",              # 日志文件（仅排查用，非状态）
    r"\.hf-state\.sha256$", # 本脚本的去重哈希缓存（自引用会导致去重失效）
]
# 注意：*.db-wal / *.db-shm 不排除——SQLite WAL 模式下已提交事务在 checkpoint
# 前只存在于 WAL，排除它会丢最近写入；改为归档前 checkpoint(TRUNCATE) 合入主库。


def log(message: str) -> None:
    print(f"[hf-state] {message}", flush=True)


def is_excluded(rel_path: str) -> bool:
    return any(re.search(pattern, rel_path) for pattern in EXCLUDE_PATTERNS)


def checkpoint_sqlite_dbs(home: Path) -> None:
    """归档前对 home 下的 SQLite 库做 TRUNCATE checkpoint（尽力而为）：
    把 WAL 中已提交事务合入主库，保证恢复不丢最近写入，同时让 WAL 归零、
    备份体积最小。库被网关占用时 checkpoint 可能部分完成，无副作用。"""
    import sqlite3

    for db_path in sorted(home.rglob("*.db")):
        try:
            conn = sqlite3.connect(str(db_path), timeout=2)
            try:
                conn.execute("PRAGMA busy_timeout=2000")
                conn.execute("PRAGMA wal_checkpoint(TRUNCATE)")
            finally:
                conn.close()
        except Exception as exc:
            log(f"checkpoint skipped for {db_path.name}: {exc}")


def compute_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def safe_extract(tar: tarfile.TarFile, destination: Path) -> None:
    destination = destination.resolve()
    for member in tar.getmembers():
        target = (destination / member.name).resolve()
        if not str(target).startswith(str(destination)):
            raise RuntimeError(f"refusing to extract unsafe path: {member.name}")
    tar.extractall(destination)


def archive_home(home: Path, archive_path: Path) -> None:
    if not home.exists():
        raise FileNotFoundError(f"home path does not exist: {home}")
    excluded = 0
    with tarfile.open(archive_path, "w:gz") as tar:
        # 逐项添加（recursive=False），跳过可再生产物；与原 tar.add(home) 的
        # 成员路径保持一致（arcname 为 home.name，如 .openclaw/...）
        for path in sorted(home.rglob("*")):
            # as_posix() 统一为正斜杠，保证排除规则在任意平台行为一致
            rel = path.relative_to(home.parent).as_posix()
            if is_excluded(rel):
                excluded += 1
                continue
            tar.add(path, arcname=rel, recursive=False)
    if excluded:
        log(f"excluded {excluded} junk paths from archive (__pycache__/*.pyc/.cache/*.log/.hf-state.sha256)")


def restore_home(home: Path, archive_path: Path) -> None:
    parent = home.parent
    parent.mkdir(parents=True, exist_ok=True)
    if home.exists():
        shutil.rmtree(home)
    with tarfile.open(archive_path, "r:gz") as tar:
        safe_extract(tar, parent)
    restored = parent / home.name
    if not restored.exists():
        raise RuntimeError(f"archive did not restore expected path: {restored}")


def write_hash(cache_path: Path, digest: str) -> None:
    cache_path.parent.mkdir(parents=True, exist_ok=True)
    cache_path.write_text(digest + "\n", encoding="utf-8")


def read_hash(cache_path: Path) -> str:
    if not cache_path.exists():
        return ""
    return cache_path.read_text(encoding="utf-8").strip()


def build_metadata(args: argparse.Namespace, digest: str, archive_path: Path) -> dict:
    return {
        "updatedAt": datetime.now(timezone.utc).isoformat(),
        "reason": args.reason,
        "archiveName": args.archive_name,
        "archiveSha256": digest,
        "archiveBytes": archive_path.stat().st_size,
        "repoId": args.repo_id,
        "repoType": args.repo_type,
        "spaceHost": os.environ.get("SPACE_HOST", ""),
        "openclawRef": os.environ.get("OPENCLAW_INSTALLED_REF", ""),
        "openclawCommit": os.environ.get("OPENCLAW_INSTALLED_COMMIT", ""),
        "hostname": socket.gethostname(),
    }


def command_restore(args: argparse.Namespace) -> int:
    api = HfApi(token=args.token)
    try:
        archive_path = Path(
            hf_hub_download(
                repo_id=args.repo_id,
                repo_type=args.repo_type,
                filename=args.archive_name,
                token=args.token,
            )
        )
    except (EntryNotFoundError, RepositoryNotFoundError):
        log(f"no saved state found in {args.repo_type} repo {args.repo_id}")
        return 0

    restore_home(args.home, archive_path)
    digest = compute_sha256(archive_path)
    write_hash(args.hash_cache, digest)

    # 完整性校验：确认关键文件存在
    critical_paths = [args.home]
    missing = [str(p) for p in critical_paths if not p.exists()]
    if missing:
        log(f"WARNING: restore integrity check failed, missing: {missing}")
        return 1

    restored_files = sum(1 for _ in args.home.rglob("*") if _.is_file())
    log(f"restored {args.home} from {args.repo_type} repo {args.repo_id} ({args.archive_name}, {restored_files} files)")
    return 0


def command_save(args: argparse.Namespace) -> int:
    api = HfApi(token=args.token)
    api.create_repo(
        repo_id=args.repo_id,
        repo_type=args.repo_type,
        private=args.private,
        exist_ok=True,
        token=args.token,
    )

    with tempfile.TemporaryDirectory(prefix="openclaw-state-") as tmpdir:
        tmpdir_path = Path(tmpdir)
        archive_path = tmpdir_path / args.archive_name
        checkpoint_sqlite_dbs(args.home)
        archive_home(args.home, archive_path)
        digest = compute_sha256(archive_path)
        previous = read_hash(args.hash_cache)
        if digest == previous:
            log("state unchanged; skipping upload")
            return 0

        metadata = build_metadata(args, digest, archive_path)
        metadata_path = tmpdir_path / args.metadata_name
        metadata_path.write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")

        # 带重试的上传（指数退避，最多 3 次）
        max_retries = 3
        for attempt in range(1, max_retries + 1):
            try:
                api.create_commit(
                    repo_id=args.repo_id,
                    repo_type=args.repo_type,
                    token=args.token,
                    commit_message=f"Backup OpenClaw state ({args.reason})",
                    operations=[
                        CommitOperationAdd(path_in_repo=args.archive_name, path_or_fileobj=str(archive_path)),
                        CommitOperationAdd(path_in_repo=args.metadata_name, path_or_fileobj=str(metadata_path)),
                    ],
                )
                write_hash(args.hash_cache, digest)
                log(f"uploaded state backup to {args.repo_type} repo {args.repo_id} ({args.archive_name})")
                return 0
            except Exception as exc:
                if attempt < max_retries:
                    wait = 2 ** attempt
                    log(f"upload attempt {attempt}/{max_retries} failed: {exc}. Retrying in {wait}s...")
                    import time
                    time.sleep(wait)
                else:
                    log(f"upload failed after {max_retries} attempts: {exc}")
                    raise
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Backup and restore OpenClaw state using Hugging Face Hub repos.")
    parser.add_argument("command", choices=["restore", "save"])
    parser.add_argument("--home", type=Path, required=True)
    parser.add_argument("--repo-id", required=True)
    parser.add_argument("--repo-type", default="dataset")
    parser.add_argument("--archive-name", default="openclaw-home.tgz")
    parser.add_argument("--metadata-name", default="openclaw-state.json")
    parser.add_argument("--token", default=os.environ.get("HF_TOKEN", ""))
    parser.add_argument("--hash-cache", type=Path, default=None)
    parser.add_argument("--reason", default="manual")
    parser.add_argument("--private", action="store_true", default=False)
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    if not args.token:
        parser.error("HF_TOKEN is required")
    args.home = args.home.resolve()
    if not args.hash_cache:
        # 默认放在 home 内：容器无持久盘，/tmp 会在下次启动被 start.sh 清空，
        # 放在 /tmp 会导致跨重启去重失效、每次重启都重传全量备份。
        # 该文件已被 EXCLUDE_PATTERNS 排除，不会进入归档、不会自引用。
        args.hash_cache = args.home / ".hf-state.sha256"
    args.hash_cache = args.hash_cache.resolve()

    if args.command == "restore":
        return command_restore(args)
    if args.command == "save":
        return command_save(args)
    parser.error(f"unsupported command: {args.command}")
    return 2


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        log(f"error: {exc}")
        raise