import importlib.util
import json
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location(
    "readiness", Path(__file__).resolve().parents[1] / "scripts/wait-for-local-ready.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def event(name, status=None, trace="current"):
    return "timing " + json.dumps(dict(source="modelLoad", traceID=trace,
                                        name=name, status=status, sinceStartMs=98050))


class ReadinessTests(unittest.TestCase):
    def setUp(self):
        self.reader = module.Readiness()

    def start(self):
        self.reader.consume('timing_environment {"pid":"123"}')
        self.reader.consume(event("modelLoadRequested"))

    def test_old_success_cannot_complete_new_install(self):
        self.assertIsNone(self.reader.consume(event("modelLoadFinished", "success")))
        self.start()
        self.assertIsNone(self.reader.consume(event("modelLoadFinished", "success", "old")))
        self.assertEqual(self.reader.consume(event("modelLoadFinished", "success")),
                         (True, "Speech recognition ready. Model load: 98.05s."))

    def test_attempt_failure_and_stale_request_are_not_final_failure(self):
        self.start()
        self.assertIsNone(self.reader.consume(event("modelAttemptFinished", "failed")))
        self.assertIsNone(self.reader.consume(event("modelLoadFinished", "stale")))
        self.assertTrue(self.reader.consume(event("modelLoadFinished", "success"))[0])

    def test_failure_and_app_deadline_do_not_report_ready(self):
        self.start()
        self.assertFalse(self.reader.consume(event("modelLoadFinished", "failed"))[0])
        self.assertFalse(self.reader.consume("model load failed: deadline reached")[0])

    def test_new_session_requires_its_own_request(self):
        self.start()
        self.reader.consume('timing_environment {"pid":"456"}')
        self.assertIsNone(self.reader.consume(event("modelLoadFinished", "success")))
        self.assertIsNone(self.reader.consume("unrelated diagnostic line"))
        self.assertIsNone(self.reader.consume("timing {broken"))


if __name__ == "__main__":
    unittest.main()
