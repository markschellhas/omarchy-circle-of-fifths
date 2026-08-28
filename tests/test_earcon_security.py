#!/usr/bin/env python3
"""Security checks for notification earcon file handling and watch coalescing."""

import importlib.util
import os
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("play_triad", ROOT / "play-triad.py")
play_triad = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(play_triad)


class NotificationNameTests(unittest.TestCase):
    def test_accepts_plain_json_basename(self):
        self.assertTrue(play_triad.notification_name_ok("abc123.json"))

    def test_rejects_path_separators_and_dotdot(self):
        for name in ("../x.json", "a/b.json", "..json", "x.json/../y.json", ""):
            self.assertFalse(play_triad.notification_name_ok(name), name)


class SecureOpenTests(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmpdir.name)

    def tearDown(self):
        self.tmpdir.cleanup()

    def test_reads_small_regular_object(self):
        path = self.dir / "note.json"
        path.write_text('{"urgency": 2, "summary": "hi"}', encoding="utf-8")
        data = play_triad.read_notification_json(str(path))
        self.assertEqual(data["urgency"], 2)

    def test_rejects_symlink(self):
        target = self.dir / "real.json"
        target.write_text('{"urgency": 1}', encoding="utf-8")
        link = self.dir / "note.json"
        link.symlink_to(target)
        with self.assertRaises(OSError):
            play_triad.read_notification_json(str(link))
        self.assertIsNone(play_triad.notification_urgency(str(link)))

    def test_rejects_directory(self):
        path = self.dir / "note.json"
        path.mkdir()
        with self.assertRaises(OSError):
            play_triad.read_notification_json(str(path))

    def test_rejects_oversized_file(self):
        path = self.dir / "note.json"
        payload = b'{"urgency": 1, "pad": "' + (b"x" * play_triad.MAX_NOTIFICATION_BYTES) + b'"}'
        path.write_bytes(payload)
        self.assertGreater(path.stat().st_size, play_triad.MAX_NOTIFICATION_BYTES)
        with self.assertRaises(OSError):
            play_triad.read_notification_json(str(path))
        self.assertIsNone(play_triad.notification_urgency(str(path)))

    def test_rejects_json_array(self):
        path = self.dir / "note.json"
        path.write_text("[1, 2, 3]", encoding="utf-8")
        with self.assertRaises(ValueError):
            play_triad.read_notification_json(str(path))

    def test_open_fd_is_regular(self):
        path = self.dir / "note.json"
        path.write_text("{}", encoding="utf-8")
        fd = play_triad.open_notification_fd(str(path))
        try:
            self.assertTrue(stat.S_ISREG(os.fstat(fd).st_mode))
        finally:
            os.close(fd)


class CoalesceTests(unittest.TestCase):
    def test_burst_collapses_to_latest_line(self):
        read_fd, write_fd = os.pipe()
        try:
            for i in range(50):
                os.write(write_fd, ("n%02d.json\n" % i).encode("utf-8"))
            os.close(write_fd)
            write_fd = -1
            with os.fdopen(read_fd, "rb", buffering=0) as reader:
                read_fd = -1
                lines = list(play_triad.coalesced_lines(reader, debounce=0.05))
            self.assertEqual(lines, [b"n49.json\n"])
        finally:
            if read_fd >= 0:
                os.close(read_fd)
            if write_fd >= 0:
                os.close(write_fd)


class WatchWorkerTests(unittest.TestCase):
    def test_one_shot_earcon_skips_unsafe_file(self):
        played = []
        original = play_triad.play_freqs
        play_triad.play_freqs = lambda *args, **kwargs: played.append(args)
        try:
            with tempfile.TemporaryDirectory() as tmp:
                huge = Path(tmp) / "flood.json"
                huge.write_bytes(b"{" + (b"x" * (play_triad.MAX_NOTIFICATION_BYTES + 8)))
                play_triad.play_earcon("0", str(huge))
                self.assertEqual(played, [])
        finally:
            play_triad.play_freqs = original

    def test_watch_coalesces_flood_to_one_play(self):
        played = []
        original_play = play_triad.play_earcon
        original_popen = play_triad.subprocess.Popen
        play_triad.play_earcon = lambda tonic, path: played.append((tonic, os.path.basename(path)))

        class FakeProc:
            def __init__(self, names):
                read_fd, write_fd = os.pipe()
                for name in names:
                    os.write(write_fd, (name + "\n").encode("utf-8"))
                os.close(write_fd)
                self.stdout = os.fdopen(read_fd, "rb", buffering=0)

            def poll(self):
                return 0

            def terminate(self):
                return None

            def wait(self, timeout=None):
                return 0

            def kill(self):
                return None

        play_triad.subprocess.Popen = lambda *args, **kwargs: FakeProc(
            ["n%02d.json" % i for i in range(80)]
        )
        try:
            with tempfile.TemporaryDirectory() as tmp:
                started = time.monotonic()
                play_triad.watch_main(["3", tmp])
                elapsed = time.monotonic() - started
            self.assertEqual(played, [("3", "n79.json")])
            self.assertLess(elapsed, 1.5)
        finally:
            play_triad.play_earcon = original_play
            play_triad.subprocess.Popen = original_popen


class BarWidgetGuardTests(unittest.TestCase):
    def test_single_supervised_watch_worker(self):
        text = (ROOT / "BarWidget.qml").read_text(encoding="utf-8")
        self.assertNotIn("execDetached", text)
        self.assertNotIn("handlePopupFile", text)
        self.assertIn("--watch", text)
        self.assertEqual(text.count("Process {"), 1)


class LiveWatchTests(unittest.TestCase):
    def test_live_flood_stays_on_one_python_worker(self):
        if not shutil_which("inotifywait"):
            self.skipTest("inotifywait not installed")

        fakebin = tempfile.TemporaryDirectory()
        notify = tempfile.TemporaryDirectory()
        play_log = os.path.join(fakebin.name, "plays.log")
        Path(fakebin.name, "pw-play").write_text(
            "#!/bin/sh\nprintf 'play\\n' >> %s\n" % json_quote_path(play_log),
            encoding="utf-8",
        )
        os.chmod(os.path.join(fakebin.name, "pw-play"), 0o755)
        env = os.environ.copy()
        env["PATH"] = fakebin.name + os.pathsep + env.get("PATH", "")
        proc = subprocess.Popen(
            [sys.executable, str(ROOT / "play-triad.py"), "--watch", "0", notify.name],
            env=env,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        try:
            time.sleep(0.35)
            self.assertIsNone(proc.poll(), "watch worker exited early")
            for i in range(200):
                path = os.path.join(notify.name, "n%03d.json" % i)
                with open(path, "w", encoding="utf-8") as handle:
                    handle.write('{"urgency":1,"n":%d}' % i)
                extras = extra_play_triad_workers(proc.pid)
                self.assertEqual(extras, [], extras)
            time.sleep(1.0)
            extras = extra_play_triad_workers(proc.pid)
            self.assertEqual(extras, [], extras)
            self.assertIsNone(proc.poll())
            plays = play_count(play_log)
            self.assertGreaterEqual(plays, 1)
            self.assertLessEqual(plays, 8)

            before = plays
            huge = os.path.join(notify.name, "huge.json")
            with open(huge, "wb") as handle:
                handle.write(b'{"urgency":1,"pad":"' + b"x" * 20000 + b'"}')
            time.sleep(0.7)
            self.assertEqual(play_count(play_log), before)

            with open(os.path.join(notify.name, "ok.json"), "w", encoding="utf-8") as handle:
                handle.write('{"urgency":2}')
            deadline = time.time() + 2.0
            while time.time() < deadline and play_count(play_log) < before + 1:
                time.sleep(0.05)
            self.assertEqual(play_count(play_log), before + 1)
        finally:
            if proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    proc.kill()
            fakebin.cleanup()
            notify.cleanup()


def shutil_which(name):
    return shutil.which(name)


def json_quote_path(path):
    return shlex.quote(path)


def play_count(path):
    try:
        with open(path, encoding="utf-8") as handle:
            return sum(1 for line in handle if line.strip())
    except FileNotFoundError:
        return 0


def extra_play_triad_workers(watch_pid):
    try:
        out = subprocess.check_output(["ps", "-eo", "pid=,args="], text=True)
    except (subprocess.CalledProcessError, FileNotFoundError):
        return []
    extras = []
    for line in out.splitlines():
        line = line.strip()
        if "play-triad.py" not in line:
            continue
        pid_s, args = line.split(None, 1)
        pid = int(pid_s)
        if pid == watch_pid:
            continue
        if "--watch" in args or "--earcon" in args:
            extras.append((pid, args))
    return extras


class UsageTests(unittest.TestCase):
    def test_watch_usage_exits_2(self):
        proc = subprocess.run(
            ["python3", str(ROOT / "play-triad.py"), "--watch"],
            capture_output=True,
            text=True,
        )
        self.assertEqual(proc.returncode, 2)
        self.assertIn("usage:", proc.stderr)


if __name__ == "__main__":
    unittest.main()
