import contextlib
import io
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest
import uuid

import repair_codex_chats as repair


class RecoveryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        (self.home / "sessions").mkdir()
        with contextlib.closing(sqlite3.connect(self.home / "state_5.sqlite")) as conn:
            conn.execute("CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT, created_at INTEGER, updated_at INTEGER, source TEXT, archived INTEGER, name TEXT, model TEXT, is_pinned INTEGER)")
            conn.commit()

    def thread(self, items, *, base=None, tid=None, recent=True, source="vscode", archived=0):
        tid = tid or str(uuid.uuid4())
        meta = {"id": tid, "history_mode": "paginated"}
        if base:
            meta["history_base"] = base
            meta["forked_from_id"] = base["thread_id"]
        records = [{"type": "session_meta", "payload": meta, "ordinal": 0}]
        for index, item in enumerate(items, 1):
            if "payload" in item:
                record = dict(item)
            else:
                record = {"type": "response_item", "payload": item, "metadata": {"client_authored": True}}
            record["ordinal"] = index
            records.append(record)
        path = self.home / "sessions" / ("rollout-" + tid + ".jsonl")
        path.write_bytes(b"".join(repair.encode(r) for r in records))
        timestamp = int(time.time()) - (0 if recent else 9 * 86400)
        with contextlib.closing(sqlite3.connect(self.home / "state_5.sqlite")) as conn:
            conn.execute("INSERT INTO threads VALUES (?,?,?,?,?,?,?,?,?)", (tid, str(path), timestamp, timestamp, source, archived, "Synthetic", "unchanged-model", 1))
            conn.commit()
        return tid, path

    def message(self, text="hello"):
        return {"type": "message", "role": "user", "content": [{"type": "input_text", "text": text}]}

    def opaque(self, summary=False):
        return {"type": "reasoning", "encrypted_content": "synthetic-ciphertext", "summary":
                [{"type": "summary_text", "text": "readable summary"}] if summary else []}

    def run_cli(self, *args):
        with contextlib.redirect_stdout(io.StringIO()) as output:
            code = repair.main(["--codex-home", str(self.home), *args])
        return code, [json.loads(line) for line in output.getvalue().splitlines()]

    def test_apply_preserves_prefix_tools_metadata_and_is_idempotent(self):
        tool = {"type": "function_call_output", "call_id": "c", "output": '{"encrypted_content":"example text"}'}
        tid, path = self.thread([self.message(), self.opaque(), tool, self.opaque(True)])
        before = path.read_bytes()
        row = repair.Store(self.home).current(tid)
        code, preview = self.run_cli()
        self.assertEqual(code, 0)
        self.assertEqual(preview[0]["status"], "would_repair")
        self.assertEqual(before, path.read_bytes())
        code, result = self.run_cli("--apply")
        self.assertEqual(code, 0)
        self.assertEqual(result[0]["status"], "repaired")
        self.assertTrue(path.read_bytes().startswith(before))
        checkpoint = json.loads(path.read_bytes()[len(before):])
        history = checkpoint["payload"]["replacement_history"]
        self.assertEqual(history[1], tool)
        self.assertEqual(history[2]["content"][0]["text"], "readable summary")
        self.assertEqual(checkpoint["ordinal"], 5)
        self.assertEqual(len(history), len(checkpoint["payload"]["replacement_history_metadata"]))
        self.assertNotIn("window_number", checkpoint["payload"])
        self.assertNotIn("resume_metadata", checkpoint["payload"])
        self.assertEqual(row, repair.Store(self.home).current(tid))
        after = path.read_bytes()
        self.assertEqual(self.run_cli("--apply")[1][0]["status"], "clean")
        self.assertEqual(after, path.read_bytes())
        self.run_cli("--restore", result[0]["manifest"])
        self.assertEqual(before, path.read_bytes())

    def test_fork_reads_archived_parent_only_through_boundary(self):
        parent, path = self.thread([self.message("inherited"), self.opaque()])
        limit = path.stat().st_size
        with path.open("ab") as stream:
            stream.write(repair.encode({"type": "response_item", "ordinal": 3, "payload": self.message("after fork")}))
        (self.home / "archived_sessions").mkdir()
        moved = self.home / "archived_sessions" / path.name
        path.rename(moved)
        tid, child = self.thread([self.message("child")], base={"thread_id": parent, "end_byte_offset": limit, "end_ordinal_exclusive": 3})
        before = moved.read_bytes()
        code, result = self.run_cli("--thread", tid, "--apply")
        self.assertEqual(code, 0, result)
        self.assertEqual(before, moved.read_bytes())
        history = json.loads(child.read_bytes().splitlines()[-1])["payload"]["replacement_history"]
        self.assertEqual([x["content"][0]["text"] for x in history], ["inherited", "child"])

    def test_bad_boundary_unknown_ciphertext_and_rollback_are_rejected(self):
        parent, path = self.thread([self.message(), self.opaque()])
        tid, child = self.thread([], base={"thread_id": parent, "end_byte_offset": path.stat().st_size - 1, "end_ordinal_exclusive": 3})
        self.assertEqual(self.run_cli("--thread", tid)[0], 2)
        tid, path = self.thread([self.message(), {"type": "compaction", "encrypted_content": "synthetic"}])
        self.assertEqual(self.run_cli("--thread", tid)[0], 2)
        tid, path = self.thread([self.message(), self.opaque(), {"type": "event_msg", "payload": {"type": "thread_rolled_back", "num_turns": 1}}])
        before = path.read_bytes()
        self.assertEqual(self.run_cli("--thread", tid, "--apply")[0], 2)
        self.assertEqual(before, path.read_bytes())

    def test_newest_checkpoint_discards_old_opaque_state_and_keeps_review_context(self):
        prior = {"message": "summary", "replacement_history": [self.message("retained")],
                 "retained_context": {"verified_answers": [], "incomplete": False},
                 "resume_metadata": {"previous_turn_settings": {"model": "old-model"}}, "window_number": 12}
        tid, path = self.thread([self.opaque(), {"type": "compacted", "payload": prior}, self.opaque(), self.message("latest")])
        self.assertEqual(self.run_cli("--apply")[0], 0)
        payload = json.loads(path.read_bytes().splitlines()[-1])["payload"]
        self.assertEqual(payload["retained_context"], prior["retained_context"])
        self.assertEqual([x["content"][0]["text"] for x in payload["replacement_history"]], ["retained", "latest"])

    def test_encrypted_message_blocks_preserve_readable_blocks(self):
        item = self.message("keep")
        item["content"].append({"type": "encrypted_content", "encrypted_content": "synthetic"})
        tid, path = self.thread([item, {"type": "message", "role": "assistant", "content": [{"type": "encrypted_content", "encrypted_content": "synthetic"}]}])
        self.assertEqual(self.run_cli("--apply")[0], 0)
        history = json.loads(path.read_bytes().splitlines()[-1])["payload"]["replacement_history"]
        self.assertEqual(history, [self.message("keep")])

    def test_agent_message_preserves_routing_and_readable_text(self):
        item = {"type": "agent_message", "author": "/root/helper", "recipient": "/root",
                "content": [{"type": "input_text", "text": "keep"}, {"type": "encrypted_content", "encrypted_content": "synthetic"}]}
        tid, path = self.thread([self.message(), item])
        self.assertEqual(self.run_cli("--apply")[0], 0)
        clean = json.loads(path.read_bytes().splitlines()[-1])["payload"]["replacement_history"][1]
        self.assertEqual(clean, dict(item, content=item["content"][:1]))

    def test_restore_refuses_to_discard_new_turns(self):
        tid, path = self.thread([self.message(), self.opaque()])
        _, result = self.run_cli("--apply")
        with path.open("ab") as stream:
            stream.write(repair.encode({"type": "response_item", "ordinal": 4, "payload": self.message("new work")}))
        before = path.read_bytes()
        with self.assertRaisesRegex(repair.RepairError, "discard newer work"):
            self.run_cli("--restore", result[0]["manifest"])
        self.assertEqual(before, path.read_bytes())

    def test_loaded_and_concurrent_writer_guards(self):
        tid, path = self.thread([self.message(), self.opaque()])
        lock = self.home / "thread-writer-locks" / (tid + ".lock")
        before = path.read_bytes()
        with repair.file_lock(lock):
            self.assertEqual(self.run_cli("--apply")[0], 2)
            # A second process proves the lock is kernel-enforced, not a Python flag.
            command = [sys.executable, "-c", "import pathlib,repair_codex_chats as r;\nwith r.publication_lock(pathlib.Path(__import__('sys').argv[1]), [__import__('sys').argv[2]]): pass", str(self.home), tid]
            child = subprocess.run(command, cwd=Path(repair.__file__).parent, capture_output=True)
            self.assertNotEqual(child.returncode, 0)
        self.assertEqual(before, path.read_bytes())

    def test_changed_source_rejected_between_scan_and_install(self):
        tid, path = self.thread([self.message(), self.opaque()])
        store = repair.Store(self.home)
        row = store.current(tid)
        state = repair.read_segment(store, path)
        checkpoint, counts = repair.build_checkpoint(state)
        with path.open("ab") as stream:
            stream.write(repair.encode({"type": "response_item", "ordinal": 3, "payload": self.message("new") }))
        before = path.read_bytes()
        with self.assertRaisesRegex(repair.RepairError, "Source changed"):
            repair.install(store, row, path, state, checkpoint, counts, self.home / "backups")
        self.assertEqual(before, path.read_bytes())

    def test_recent_filter_and_explicit_override(self):
        recent, _ = self.thread([self.message()])
        old, _ = self.thread([self.message()], recent=False)
        archived, _ = self.thread([self.message()], archived=1)
        agent, _ = self.thread([self.message()], source='{"subagent":{}}')
        store = repair.Store(self.home)
        self.assertEqual([r["id"] for r in store.select(7, [], False, False)], [recent])
        self.assertEqual([r["id"] for r in store.select(7, [old], False, False)], [old])
        self.assertEqual(len(store.select(7, [], True, True)), 3)

    @unittest.skipUnless(os.name == "nt", "Windows extended path spelling")
    def test_windows_extended_path_resolves_inside_home(self):
        tid, path = self.thread([self.message()])
        self.assertEqual(repair.Store(self.home).safe_path("\\\\?\\" + str(path)), path.resolve())

    def test_malformed_jsonl_and_missing_ordinal_fail_without_mutation(self):
        tid, path = self.thread([self.message(), self.opaque()])
        with path.open("ab") as stream:
            stream.write(b'{"partial":')
        before = path.read_bytes()
        self.assertEqual(self.run_cli("--apply")[0], 2)

        self.assertEqual(before, path.read_bytes())
        path.write_bytes(before[:before.index(b'{"partial":')] + repair.encode({"type": "event_msg", "payload": {"type": "task_complete"}}))
        self.assertEqual(self.run_cli("--apply")[0], 2)

    def test_stale_lock_is_safe_and_unknown_record_is_skipped(self):
        tid, path = self.thread([self.message(), self.opaque()])
        lock = self.home / "thread-writer-locks" / (tid + ".lock")
        lock.parent.mkdir()
        lock.touch()
        self.assertEqual(self.run_cli("--thread", tid, "--apply")[0], 0)
        tid, path = self.thread([self.message(), {"type": "future_history_event", "payload": {"content": "keep"}}])
        before = path.read_bytes()
        self.assertEqual(self.run_cli("--thread", tid, "--apply")[0], 2)
        self.assertEqual(before, path.read_bytes())


if __name__ == "__main__":
    unittest.main()
