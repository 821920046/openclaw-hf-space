#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import shutil
import socket
import sys
import tarfile
import tempfile
from datetime import datetime, timezone
from pathlib import Path

from huggingface_hub import CommitOperationAdd, HfApi, hf_hub_download
from huggingface_hub.errors import EntryNotFoundError, RepositoryNotFoundError


def log(message: str) -> None:
    print(f"[hf-state] {message}", flush=True)


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
    with tarfile.open(archive_path, "w:gz") as tar:
        tar.add(home, arcname=home.name)


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
    log(f"restored {args.home} from {args.repo_type} repo {args.repo_id} ({args.archive_name})")
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
        archive_home(args.home, archive_path)
        digest = compute_sha256(archive_path)
        previous = read_hash(args.hash_cache)
        if digest == previous:
            log("state unchanged; skipping upload")
            return 0

        metadata = build_metadata(args, digest, archive_path)
        metadata_path = tmpdir_path / args.metadata_name
        metadata_path.write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")

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


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Backup and restore OpenClaw state using Hugging Face Hub repos.")
    parser.add_argument("command", choices=["restore", "save"])
    parser.add_argument("--home", type=Path, required=True)
    parser.add_argument("--repo-id", required=True)
    parser.add_argument("--repo-type", default="dataset")
    parser.add_argument("--archive-name", default="openclaw-home.tgz")
    parser.add_argument("--metadata-name", default="openclaw-state.json")
    parser.add_argument("--token", default=os.environ.get("HF_TOKEN", ""))
    parser.add_argument("--hash-cache", type=Path, default=Path("/tmp/openclaw-hf-state.sha256"))
    parser.add_argument("--reason", default="manual")
    parser.add_argument("--private", action="store_true", default=False)
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    if not args.token:
        parser.error("HF_TOKEN is required")
    args.home = args.home.resolve()
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