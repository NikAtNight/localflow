"""Exercise the installer's current-session preflight without touching apps."""
import json
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import patch


class LocalAppIdleTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        script = (Path(__file__).resolve().parents[1] / "scripts/local-app.sh").read_text()
        source = script.split("python3 - <<'PY_CHECK_IDLE'\n", 1)[1].split("\nPY_CHECK_IDLE", 1)[0]
        cls.code = compile(source, "local-app-idle-preflight", "exec")

    @staticmethod
    def event(name, status=None):
        value = {"source": "dictation", "traceID": "fixture", "name": name}
        if status:
            value["status"] = status
        return "time timing " + json.dumps(value)

    def check(self, events, prefix="", running=True):
        log = prefix + "time === LocalFlow session start (pid 123) ===\n" + "\n".join(events)
        process = SimpleNamespace(returncode=0 if running else 1, stdout="123\n")
        with patch("subprocess.run", return_value=process), patch("pathlib.Path.read_text", return_value=log):
            exec(self.code, {})

    def test_recording_and_processing_prevent_restart(self):
        for events in ([self.event("hotkeyPressed")],
                       [self.event("hotkeyPressed"), self.event("hotkeyReleased"), self.event("resultReady", "success")]):
            with self.subTest(events=events), self.assertRaises(SystemExit):
                self.check(events)

    def test_paste_waits_for_clipboard_resolution(self):
        events = [self.event("hotkeyPressed"), self.event("pasteDispatched", "success")]
        with self.assertRaises(SystemExit):
            self.check(events)
        self.check(events + [self.event("clipboardWindowResolved", "changedClipboard")])

    def test_empty_failed_and_silent_results_allow_restart(self):
        for status in ("empty", "failed", "insufficientVoice", "cancelled"):
            with self.subTest(status=status):
                self.check([self.event("hotkeyPressed"), self.event("resultReady", status)])

    def test_cancelled_skipped_and_typed_results_allow_restart(self):
        for name in ("cancellationRequested", "injectionSkipped", "typingDispatched"):
            with self.subTest(name=name):
                self.check([self.event("hotkeyPressed"), self.event(name)])

    def test_stale_previous_launch_does_not_block_restart(self):
        old = "time === LocalFlow session start (pid 99) ===\n" + self.event("hotkeyPressed") + "\n"
        self.check([], prefix=old)

    def test_stopped_app_does_not_require_a_log(self):
        self.check([], running=False)


if __name__ == "__main__":
    unittest.main()
