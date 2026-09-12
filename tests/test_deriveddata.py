#!/usr/bin/python3
"""Run: python3 tests/test_deriveddata.py (temporary files only)."""

from contextlib import redirect_stdout, redirect_stderr
from datetime import datetime, timezone
from importlib.machinery import SourceFileLoader
from importlib.util import module_from_spec, spec_from_loader
from multiprocessing import active_children
import io
import json
import os
from pathlib import Path
import plistlib
import sys
from tempfile import TemporaryDirectory
import time
from unittest.mock import patch


loader = SourceFileLoader("deriveddata", str(Path(__file__).resolve().parents[1] / "deriveddata.py"))
spec = spec_from_loader(loader.name, loader)
dd = module_from_spec(spec)
sys.modules[loader.name] = dd
loader.exec_module(dd)


def check():
    with TemporaryDirectory(prefix="deriveddata-test-") as temporary:
        root = Path(temporary).resolve() / "DerivedData"
        root.mkdir()
        old = time.time() - 60 * 86400
        cutoff = time.time() - 30 * 86400

        def cache(name, accessed=old):
            path = root / name
            (path / "Build/Products").mkdir(parents=True)
            (path / "Build/Products/app").write_bytes(b"x" * 8192)
            (path / "info.plist").write_bytes(plistlib.dumps({
                "WorkspacePath": "/projects/Example.xcodeproj",
                "LastAccessedDate": datetime.fromtimestamp(accessed, timezone.utc).replace(tzinfo=None),
            }))
            age_tree(path)
            return path

        def age_tree(path):
            for child in [*path.rglob("*"), path]:
                os.utime(child, (old, old), follow_symlinks=False)

        # Selection is an allowlist over discovered candidates, never another scan root.
        selected = cache("selected only")
        untouched = cache("unselected keep")
        with patch.object(dd, "ensure_idle"), redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
            assert dd.main(["--root", str(root), "--jobs", "1", "--clean", "--only-path", str(selected)]) == 0
            assert not selected.exists() and untouched.exists()
            assert dd.main(["--root", str(root), "--jobs", "1", "--clean", "--only-path", str(untouched), "--only-path", str(root / "missing")]) == 1
            assert untouched.exists()  # Validate the complete selection before deleting anything.
            os.utime(untouched / "Build/Products/app", None)
            assert dd.main(["--root", str(root), "--jobs", "1", "--clean", "--only-path", str(untouched)]) == 1
            assert untouched.exists()
        import shutil
        shutil.rmtree(untouched)

        stale = cache("오래된 프로젝트 with spaces")
        recent_file = cache("recent file")
        os.utime(recent_file / "Build/Products/app", None)
        recent_access = cache("recent access", time.time())
        within_eight = cache("within eight hours", time.time() - 7 * 3600)
        past_eight = cache("past eight hours", time.time() - 9 * 3600)
        logs_only = root / ("LogsOnly-" + "a" * 28)
        (logs_only / "Logs").mkdir(parents=True)
        age_tree(logs_only)
        shared = root / "ModuleCache.noindex"
        shared.mkdir()
        age_tree(shared)
        unknown = root / "unrelated"
        unknown.mkdir()
        age_tree(unknown)
        outside = Path(temporary) / "outside"
        outside.mkdir()
        (outside / "keep.txt").write_text("keep")
        (root / "linked-project").symlink_to(outside, target_is_directory=True)
        (stale / "external").symlink_to(outside, target_is_directory=True)
        os.utime(stale / "external", (old, old), follow_symlinks=False)
        os.utime(stale, (old, old))

        assert dd.eligible(dd.inspect(stale), cutoff, False)
        assert dd.inspect(stale)["size"] >= 8192
        assert not dd.eligible(dd.inspect(recent_file), cutoff, False)
        assert not dd.eligible(dd.inspect(recent_access), cutoff, False)
        assert dd.eligible(dd.inspect(logs_only), cutoff, False)
        assert not dd.eligible(dd.inspect(shared), cutoff, False)
        assert dd.eligible(dd.inspect(shared), cutoff, True)
        assert not dd.eligible(dd.inspect(unknown), cutoff, True)
        assert not dd.eligible(dd.inspect(root / "linked-project"), cutoff, True)
        assert not dd.eligible(dict(kind="프로젝트", latest=cutoff), cutoff, False)
        original_lstat = Path.lstat

        def disappearing_file(path):
            if path == stale / "Build/Products/app":
                raise FileNotFoundError(path)
            return original_lstat(path)

        with patch.object(Path, "lstat", disappearing_file):
            assert not dd.eligible(dd.inspect(stale), cutoff, False)
        with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
            preview = io.StringIO()
            with redirect_stdout(preview):
                assert dd.main(["--root", str(root)]) == 0
            assert "8시간 기준 정리 후보: 3개" in preview.getvalue()
            serial = io.StringIO()
            with redirect_stdout(serial):
                assert dd.main(["--root", str(root), "--jobs", "1"]) == 0
            assert serial.getvalue() == preview.getvalue()
            machine = io.StringIO()
            with redirect_stdout(machine):
                assert dd.main(["--root", str(root), "--json"]) == 0
            report = json.loads(machine.getvalue())
            assert report["hours"] == 8
            assert sum(item["candidate"] for item in report["items"]) == 3
            assert report["total_bytes"] == sum(item["size"] for item in report["items"])
            assert report["candidate_bytes"] == sum(item["size"] for item in report["items"] if item["candidate"])
            assert any(item["path"] == str(stale) for item in report["items"])
            children_before = {child.pid for child in active_children()}

            class InterruptProgress(io.StringIO):
                def isatty(self):
                    return True

                def write(self, text):
                    if text.startswith("\r"):
                        assert len({child.pid for child in active_children()} - children_before) == 2
                        raise KeyboardInterrupt
                    return super().write(text)

            with redirect_stderr(InterruptProgress()):
                try:
                    dd.main(["--root", str(root), "--jobs", "2"])
                    raise AssertionError("Interrupt was not raised")
                except KeyboardInterrupt:
                    pass
            assert {child.pid for child in active_children()} == children_before
            assert dd.main(["--root", str(stale)]) == 0
            assert stale.exists()
            with patch.object(dd, "ensure_idle", side_effect=OSError("Xcode 실행 중")):
                assert dd.main(["--root", str(root), "--clean"]) == 1
                assert stale.exists()
            with patch.object(dd, "ensure_idle"):
                changed = dd.inspect(recent_file)
                changed["latest"] = old
                dd.clean([changed], cutoff, False)
                assert recent_file.exists()
                assert dd.main(["--root", str(root), "--days", "30", "--clean"]) == 0
                assert not stale.exists() and not logs_only.exists()
                assert recent_file.exists() and recent_access.exists() and shared.exists()
                assert within_eight.exists() and past_eight.exists()
                assert unknown.exists() and (outside / "keep.txt").read_text() == "keep"
                assert (root / "linked-project").is_symlink()
                assert dd.main(["--root", str(root), "--include-shared", "--clean"]) == 0
                assert not shared.exists()
                assert within_eight.exists() and not past_eight.exists()
                assert dd.main(["--root", str(root), "--hours", "6", "--clean"]) == 0
                assert not within_eight.exists()
            assert dd.main(["--root", str(root / "missing")]) == 1
            assert dd.main(["--root", str(root), "--root", str(recent_file)]) == 1
            for invalid in (["--days", "0"], ["--days", "-1"], ["--days", "abc"],
                            ["--hours", "0"], ["--hours", "-1"], ["--hours", "abc"],
                            ["--hours", "8", "--days", "1"],
                            ["--jobs", "0"], ["--jobs", "-1"], ["--jobs", "abc"], ["--json", "--clean"]):
                try:
                    dd.main(["--root", str(root), *invalid])
                    raise AssertionError("Invalid period accepted")
                except SystemExit as exc:
                    assert exc.code == 2
            broken = root / "broken"
            broken.mkdir()
            (broken / "info.plist").write_text("broken plist")
            with patch.object(dd, "ensure_idle"):
                with patch.object(dd, "clean") as cleaner:
                    assert dd.main(["--root", str(root), "--clean"]) == 1
                    cleaner.assert_not_called()
            (broken / "info.plist").write_text('<?xml version="1.0"?><plist><dict>')
            with patch.object(dd, "ensure_idle"):
                assert dd.main(["--root", str(root), "--clean"]) == 1
    print("PASS: selected-only deletion, stale/missing selection blocks all deletion, JSON report, parallel/serial equivalence, worker count, interrupt stops workers, worker error blocks cleanup, default 8 hours, hours/days overrides, preview, cutoff, nested activity, Xcode access, cleanup, shared caches, symlinks, concurrent removal, recheck, invalid input")


if __name__ == "__main__":
    check()
