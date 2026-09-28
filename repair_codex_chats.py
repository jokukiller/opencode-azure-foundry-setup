#!/usr/bin/env python3
"""Offline, reversible recovery of Codex invalid_encrypted_content histories.

Python 3.10+, standard library only. Preview by default; --apply writes a new
model-context checkpoint. Original JSONL bytes and SQLite metadata stay intact.
"""

import argparse
import collections
import contextlib
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import shutil
import sqlite3
import sys
import time
import uuid


class RepairError(Exception):
    pass


def require(condition, message):
    if not condition:
        raise RepairError(message)


def encode(value):
    return (json.dumps(value, ensure_ascii=False, separators=(",", ":")) + "\n").encode("utf-8")


def digest(path, limit=None):
    result = hashlib.sha256()
    with path.open("rb") as stream:
        remaining = limit
        while remaining is None or remaining > 0:
            block = stream.read(1024 * 1024 if remaining is None else min(1024 * 1024, remaining))
            if not block:
                require(remaining in (None, 0), "Source shortened during read")
                break
            result.update(block)
            if remaining is not None:
                remaining -= len(block)
    return result.hexdigest()


def stamp(path):
    stat = path.stat()
    return (stat.st_size, stat.st_mtime_ns)


def canonical_path(path):
    value = str(path)
    if os.name == "nt":
        if value.startswith("\\\\?\\UNC\\"):
            value = "\\\\" + value[8:]
        elif value.startswith("\\\\?\\"):
            value = value[4:]
    return Path(value).resolve()


def contains_encrypted(value):
    if isinstance(value, dict):
        return bool(value.get("encrypted_content")) or any(contains_encrypted(v) for v in value.values())
    return isinstance(value, list) and any(contains_encrypted(v) for v in value)


def clean_item(item, counts):
    """Only remove known opaque model state; never rewrite tool data or text."""
    require(isinstance(item, dict), "Non-object model item")
    typ = item.get("type")
    if typ == "reasoning" and item.get("encrypted_content"):
        require(not item.get("content"), "Unknown readable reasoning content; leaving chat unchanged")
        summaries = item.get("summary") or []
        require(all(isinstance(v, dict) and v.get("type") == "summary_text" and isinstance(v.get("text"), str)
                    for v in summaries), "Unknown reasoning summary shape")
        counts["encrypted_reasoning_items"] += 1
        if summaries:
            counts["readable_reasoning_summaries_preserved"] += 1
            return {"type": "message", "role": "assistant", "content": [
                {"type": "output_text", "text": v["text"]} for v in summaries]}
        return None
    if typ in ("message", "agent_message"):
        content = item.get("content")
        require(isinstance(content, list), "Unknown message content shape")
        kept = []
        for block in content:
            if isinstance(block, dict) and block.get("type") == "encrypted_content" and block.get("encrypted_content"):
                counts["encrypted_message_blocks"] += 1
            else:
                require(not contains_encrypted(block), "Unknown encrypted message block")
                kept.append(block)
        if content and not kept:
            counts["encrypted_only_messages"] += 1
            return None
        return dict(item, content=kept)
    # Strings containing 'encrypted_content' (e.g. code/tool output) are data.
    require(not contains_encrypted(item), "Unknown encrypted item type: " + str(typ))
    return item


def clean_history(items, metadata, counts):
    require(len(items) == len(metadata), "History/metadata lengths differ")
    clean, annotations = [], []
    for item, annotation in zip(items, metadata):
        value = clean_item(item, counts)
        if value is not None:
            clean.append(value)
            annotations.append(annotation)
    return clean, annotations


@contextlib.contextmanager
def file_lock(path):
    """Nonblocking kernel lock compatible with Rust File::lock/flock/LockFileEx."""
    path.parent.mkdir(parents=True, exist_ok=True)
    stream = path.open("a+b")
    try:
        stream.seek(0)
        if os.name == "nt":
            import msvcrt
            msvcrt.locking(stream.fileno(), msvcrt.LK_NBLCK, 1)
        else:
            import fcntl
            fcntl.flock(stream.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield stream
    finally:
        stream.close()  # Closing releases the lock on both platforms.


@contextlib.contextmanager
def publication_lock(home, thread_ids):
    """Match Codex's coordination-before-writer publication protocol.

    Keep coordination held through the short publication transaction. Probe
    existing writer files without deleting them or stopping any running chat.
    """
    directory = home / "thread-writer-locks"
    with contextlib.ExitStack() as stack:
        try:
            stack.enter_context(file_lock(directory / ".coordination.lock"))
            for tid in sorted(set(thread_ids)):
                path = directory / (str(uuid.UUID(tid)) + ".lock")
                if path.exists():
                    stack.enter_context(file_lock(path))
        except OSError as exc:
            raise RepairError("Codex writer/coordination lock is busy; close or unload the chat and retry") from exc
        yield


class Store:
    def __init__(self, home):
        self.home = canonical_path(home)
        databases = sorted(home.glob("state_*.sqlite"), key=lambda p: int(p.stem.split("_")[-1]))
        require(bool(databases), "No state_*.sqlite database in Codex home")
        self.database = databases[-1]
        with self.connect() as conn:
            self.rows = {r["id"]: dict(r) for r in conn.execute("SELECT * FROM threads")}
        self.paths = None

    def connect(self):
        conn = sqlite3.connect(self.database.resolve().as_uri() + "?mode=ro", uri=True)
        conn.row_factory = sqlite3.Row
        return contextlib.closing(conn)

    def current(self, tid):
        with self.connect() as conn:
            row = conn.execute("SELECT * FROM threads WHERE id=?", (tid,)).fetchone()
        require(row is not None, "Chat disappeared from state database")
        return dict(row)

    def safe_path(self, path):
        path = canonical_path(path)
        require(any(path.is_relative_to(self.home / name) for name in ("sessions", "archived_sessions")),
                "Rollout path is outside sessions/archived_sessions")
        require(path.suffix == ".jsonl" and path.is_file(), "Missing JSONL rollout")
        return path

    def resolve_segment(self, tid):
        # history_base may identify a segment filename suffix, not a threads row.
        if self.paths is None:
            self.paths = [p.resolve() for name in ("sessions", "archived_sessions")
                          for p in (self.home / name).rglob("*.jsonl")]
        exact = [p for p in self.paths if p.stem.endswith(tid)]
        if len(exact) == 1:
            return self.safe_path(exact[0])
        require(not exact, "Ambiguous inherited segment: " + tid)
        row = self.rows.get(tid)
        require(row is not None, "Missing inherited segment: " + tid)
        return self.safe_path(row["rollout_path"])

    def select(self, days, ids, include_archived, include_subagents):
        if ids:
            require(all(tid in self.rows for tid in ids), "Unknown explicit thread ID")
            return [self.rows[tid] for tid in dict.fromkeys(ids)]
        cutoff = time.time() - days * 86400
        return [r for r in self.rows.values()
                if max(r.get("created_at", 0), r.get("updated_at", 0)) >= cutoff
                and (include_archived or not r.get("archived"))
                and (include_subagents or "subagent" not in r.get("source", ""))]


def read_segment(store, path, limit=None, ordinal_limit=None, seen=None):
    """Replay through exact byte boundaries; only traverse ancestors if needed."""
    seen = set() if seen is None else seen
    key = (str(path), limit)
    require(key not in seen and len(seen) < 100, "Cyclic/excessively deep inherited history")
    seen = seen | {key}
    before = stamp(path)
    require(limit is None or 0 < limit <= before[0], "Inherited byte boundary exceeds segment")
    end = before[0] if limit is None else limit
    suffix, checkpoint, meta, last_ordinal = [], None, None, None
    has_ordinals = False
    with path.open("rb") as stream:
        while stream.tell() < end:
            raw = stream.readline()
            require(raw.endswith(b"\n") and stream.tell() <= end, "Truncated JSONL or inherited boundary splits a record")
            record = json.loads(raw)
            require(isinstance(record, dict) and isinstance(record.get("payload"), dict), "Unknown rollout record")
            ordinal = record.get("ordinal")
            if ordinal is not None:
                require(type(ordinal) is int and (last_ordinal is None or ordinal > last_ordinal), "Invalid ordinal order")
                require(ordinal_limit is None or ordinal < ordinal_limit, "Byte and ordinal history boundaries disagree")
                has_ordinals = True
                last_ordinal = ordinal
            elif has_ordinals:
                raise RepairError("Paginated record is missing its ordinal")
            typ = record.get("type")
            require(typ in {"session_meta", "response_item", "compacted", "event_msg", "turn_context",
                            "world_state", "token_usage_record", "retained_context", "security_risk_score",
                            "realtime_item", "inter_agent_communication", "inter_agent_communication_metadata"},
                    "Unknown rollout record type: " + str(typ))
            if meta is None:
                require(typ == "session_meta", "First rollout record is not session_meta")
                meta = record["payload"]
            if typ == "compacted":
                checkpoint = record["payload"]
                suffix = []
            elif typ in ("response_item", "retained_context", "inter_agent_communication") or (
                    typ == "event_msg" and record["payload"].get("type") == "thread_rolled_back"):
                suffix.append(record)
    require(stamp(path) == before, "Source changed during scan")
    require(meta is not None, "Empty rollout")
    require(meta.get("history_mode") in (None, "legacy", "paginated"), "Unsupported history mode")
    require(meta.get("history_mode") != "paginated" or has_ordinals, "Paginated history has no ordinals")
    dependency = {"path": str(path), "bytes": end, "sha256": digest(path, end), "owner": meta["id"]}
    require(stamp(path) == before, "Source changed during hashing")
    dependencies = [dependency]
    if checkpoint is not None:
        require(isinstance(checkpoint.get("replacement_history"), list), "Legacy summary-only compaction needs manual recovery")
        items = list(checkpoint["replacement_history"])
        metadata = checkpoint.get("replacement_history_metadata")
        metadata = list(metadata) if metadata is not None else [{} for _ in items]
        require(len(items) == len(metadata), "Checkpoint metadata length mismatch")
    elif meta.get("history_base"):
        base = meta["history_base"]
        require(set(base) <= {"thread_id", "end_byte_offset", "end_ordinal_exclusive"}, "Unknown inherited history boundary")
        require(type(base.get("end_byte_offset")) is int and type(base.get("end_ordinal_exclusive")) is int,
                "Inherited history requires byte and ordinal boundaries")
        parent = read_segment(store, store.resolve_segment(base["thread_id"]),
                              base["end_byte_offset"], base["end_ordinal_exclusive"], seen)
        items, metadata, checkpoint = parent["items"], parent["metadata"], parent["checkpoint"]
        dependencies.extend(parent["dependencies"])
    else:
        require(not meta.get("forked_from_id"), "Fork has no explicit history_base; manual recovery required")
        items, metadata = [], []
    for record in suffix:
        require(record["type"] == "response_item",
                "Rollback, retained-context event or legacy agent communication needs manual replay")
        items.append(record["payload"])
        metadata.append(record.get("metadata") or {})
    return dict(items=items, metadata=metadata, checkpoint=checkpoint, dependencies=dependencies,
                last_ordinal=last_ordinal, before=before, meta=meta)


def build_checkpoint(state):
    counts = collections.Counter()
    items, annotations = clean_history(state["items"], state["metadata"], counts)
    prior = state["checkpoint"] or {}
    # A checkpoint without window_number keeps full metadata/world-state replay.
    # It changes model history only; copying old resume_metadata would rewind the
    # model/settings to the previous compaction. Preserve review context exactly.
    payload = {"message": prior.get("message", ""), "replacement_history": items,
               "replacement_history_metadata": annotations}
    for field in ("retained_context", "guardian_history"):
        if prior.get(field) is not None:
            require(not contains_encrypted(prior[field]), "Encrypted review context needs manual recovery")
            payload[field] = prior[field]
    if not counts["encrypted_reasoning_items"] and not counts["encrypted_message_blocks"]:
        return None, dict(counts)
    require(bool(items), "Repair would leave no readable model context")
    record = {"timestamp": dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z"),
              "type": "compacted", "payload": payload}
    if state["last_ordinal"] is not None:
        record["ordinal"] = state["last_ordinal"] + 1
    counts["context_items_before"] = len(state["items"])
    counts["context_items_after"] = len(items)
    return encode(record), dict(counts)


def save_json(path, value):
    temp = path.with_name(path.name + ".tmp")
    with temp.open("xb") as stream:
        stream.write(encode(value))
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temp, path)


def goals_snapshot(home, tid):
    paths = sorted(home.glob("goals_*.sqlite"), key=lambda p: int(p.stem.split("_")[-1]))
    if not paths:
        return None
    with contextlib.closing(sqlite3.connect(paths[-1].as_uri() + "?mode=ro", uri=True)) as conn:
        conn.row_factory = sqlite3.Row
        row = conn.execute("SELECT * FROM thread_goals WHERE thread_id=?", (tid,)).fetchone()
        return dict(row) if row else None


def install(store, row, path, state, checkpoint, counts, backup_root):
    # Preparation does not hold global coordination or block unrelated writers.
    directory = backup_root / (dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + row["id"] + "-" + uuid.uuid4().hex[:8])
    directory.mkdir(parents=True, exist_ok=False)
    require(not directory.resolve().is_relative_to(store.home / "sessions") and
            not directory.resolve().is_relative_to(store.home / "archived_sessions"), "Backup directory must be outside rollout trees")
    original = directory / "original.jsonl"
    shutil.copy2(path, original)
    expected = state["dependencies"][0]["sha256"]
    require(digest(original) == expected and stamp(path) == state["before"], "Source changed before backup")
    (directory / "checkpoint.jsonl").write_bytes(checkpoint)
    prepared = directory / "repaired.jsonl"
    with original.open("rb") as src, prepared.open("xb") as dst:
        shutil.copyfileobj(src, dst)
        dst.write(checkpoint)
        dst.flush()
        os.fsync(dst.fileno())
    require(digest(prepared, original.stat().st_size) == expected, "Original prefix was altered")
    after_sha = digest(prepared)
    manifest = dict(version=1, thread_id=row["id"], codex_home=str(store.home), original_path=str(path),
                    original_sha256=expected, repaired_sha256=after_sha, original_bytes=original.stat().st_size,
                    checkpoint_sha256=hashlib.sha256(checkpoint).hexdigest(), counts=counts,
                    dependencies=state["dependencies"], thread_before=row,
                    goal_before=goals_snapshot(store.home, row["id"]), status="prepared")
    manifest_path = directory / "manifest.json"
    save_json(manifest_path, manifest)
    owners = [d["owner"] for d in state["dependencies"]]
    temp = path.with_name(path.name + ".repair-" + uuid.uuid4().hex + ".tmp")
    try:
        shutil.copy2(prepared, temp)
        require(digest(temp) == after_sha, "Staged file hash mismatch")
        with publication_lock(store.home, owners):
            require(store.current(row["id"]) == row, "Chat metadata changed during preparation")
            for dependency in state["dependencies"]:
                source = store.safe_path(dependency["path"])
                require(digest(source, dependency["bytes"]) == dependency["sha256"], "History dependency changed")
            require(stamp(path) == state["before"] and digest(path) == expected, "Chat changed during preparation")
            os.replace(temp, path)
            require(digest(path) == after_sha, "Installed file hash mismatch; restore from manifest")
            require(store.current(row["id"]) == row, "Chat metadata changed during publication")
            require(goals_snapshot(store.home, row["id"]) == manifest["goal_before"], "Goal metadata changed")
            manifest["status"] = "applied"
            save_json(manifest_path, manifest)
    finally:
        if temp.exists():
            temp.unlink()
    return str(manifest_path)


def restore(store, manifest_path):
    manifest_path = manifest_path.resolve()
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    require(manifest.get("version") == 1, "Unknown manifest version")
    require(Path(manifest["codex_home"]).resolve() == store.home, "Manifest belongs to another Codex home")
    tid = str(uuid.UUID(manifest["thread_id"]))
    row = store.current(tid)
    path = store.safe_path(row["rollout_path"])
    original = manifest_path.parent / "original.jsonl"
    require(digest(original) == manifest["original_sha256"], "Backup hash mismatch")
    temp = path.with_name(path.name + ".restore-" + uuid.uuid4().hex + ".tmp")
    try:
        shutil.copy2(original, temp)
        require(digest(temp) == manifest["original_sha256"], "Restore staging hash mismatch")
        with publication_lock(store.home, [tid]):
            require(store.current(tid) == row, "Chat changed during restore")
            require(digest(path) == manifest["repaired_sha256"], "Chat changed after repair; refusing to discard newer work")
            os.replace(temp, path)
            manifest["status"] = "restored"
            save_json(manifest_path, manifest)
    finally:
        if temp.exists():
            temp.unlink()
    return {"thread_id": tid, "status": "restored"}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--codex-home", type=Path, default=Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex"))))
    parser.add_argument("--days", type=int, default=7, help="Chats created or updated within this many days (default 7)")
    parser.add_argument("--thread", action="append", default=[], help="Exact thread ID; repeatable, overrides date/archive/source filters")
    parser.add_argument("--include-archived", action="store_true")
    parser.add_argument("--include-subagents", action="store_true")
    parser.add_argument("--apply", action="store_true", help="Install checkpoints; otherwise only preview")
    parser.add_argument("--backup-dir", type=Path, help="Private backup location; default CODEX_HOME/chat-repair-backups")
    parser.add_argument("--restore", type=Path, metavar="MANIFEST", help="Restore one repair, only if no newer work exists")
    parser.add_argument("--report", type=Path, help="Save local JSON report (may contain private titles/paths)")
    args = parser.parse_args(argv)
    require(args.days > 0, "--days must be positive")
    store = Store(args.codex_home)
    if args.restore:
        require(not args.apply and not args.thread, "Use --restore separately from --apply/--thread")
        print(json.dumps(restore(store, args.restore)))
        return 0
    started = time.monotonic()
    backup_root = (args.backup_dir or store.home / "chat-repair-backups").resolve()
    rows = store.select(args.days, args.thread, args.include_archived, args.include_subagents)
    results = []
    for row in rows:
        result = {"thread_id": row["id"], "title": row.get("name") or row.get("title")}
        try:
            # Probe kernel ownership, not file existence: a crash can leave a
            # harmless stale lock file. Publication acquires the guards again.
            with publication_lock(store.home, [row["id"]]):
                pass
            path = store.safe_path(row["rollout_path"])
            state = read_segment(store, path)
            require(state["meta"]["id"] == row["id"], "Database/rollout identity mismatch")
            checkpoint, counts = build_checkpoint(state)
            result.update(counts=counts, scanned_bytes=sum(d["bytes"] for d in state["dependencies"]))
            if checkpoint is None:
                result["status"] = "clean"
            elif not args.apply:
                result.update(status="would_repair", checkpoint_bytes=len(checkpoint))
            else:
                result["manifest"] = install(store, row, path, state, checkpoint, counts, backup_root)
                result["status"] = "repaired"
        except (RepairError, OSError, ValueError, sqlite3.Error) as exc:
            result.update(status="skipped", reason=str(exc))
        results.append(result)
        print(json.dumps(result, ensure_ascii=True), flush=True)
    summary = {"mode": "apply" if args.apply else "preview", "days": args.days,
               "counts": dict(collections.Counter(r["status"] for r in results)),
               "elapsed_seconds": round(time.monotonic() - started, 2)}
    print(json.dumps(summary), flush=True)
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        save_json(args.report, dict(summary=summary, results=results))
    return 2 if any(r["status"] == "skipped" for r in results) else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (RepairError, OSError, ValueError, sqlite3.Error) as error:
        print("Repair stopped: " + str(error), file=sys.stderr)
        sys.exit(1)
