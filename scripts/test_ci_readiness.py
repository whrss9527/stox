"""Offline regression tests for the launch diagnostic readiness contract."""
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
HELPER = ROOT / "scripts" / "ci-wait-ready.sh"


class ReadinessTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.output = Path(self.directory.name) / "launch.log"
        self.children = []

    def tearDown(self):
        for child in self.children:
            if child.poll() is None:
                child.terminate()
            child.wait(timeout=3)
        self.directory.cleanup()

    def launch(self, script):
        with self.output.open("w") as output:
            child = subprocess.Popen([sys.executable, "-u", "-c", script], stdout=output, stderr=output)
        self.children.append(child)
        return child

    def wait_ready(self, child, timeout="20"):
        return subprocess.run(
            ["bash", "-c", 'source "$1"; wait_for_stox_ready "$2" "$3" "$4"',
             "readiness-test", str(HELPER), str(child.pid), str(self.output), timeout],
            capture_output=True, text=True, timeout=3,
        )

    def testReadySignalReturnsWithoutFixedDelay(self):
        child = self.launch("import time; time.sleep(0.1); print('STOX_DIAG late ready=true'); time.sleep(20)")
        start = time.monotonic()
        result = self.wait_ready(child)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertLess(time.monotonic() - start, 2)
        self.assertIsNone(child.poll())

    def testPartialDiagnosticsDoNotMeanReady(self):
        child = self.launch("import time; print('STOX_DIAG late us_phase=closed'); print('ticker=STOX_DIAG late ready=true'); time.sleep(20)")
        result = self.wait_ready(child, "1")
        self.assertEqual(result.returncode, 1)
        self.assertIn("Timed out", result.stderr)

    def testEarlyExitFailsImmediately(self):
        child = self.launch("raise SystemExit(1)")
        child.wait(timeout=3)
        start = time.monotonic()
        result = self.wait_ready(child)
        self.assertEqual(result.returncode, 1)
        self.assertIn("exited", result.stderr)
        self.assertLess(time.monotonic() - start, 2)

    def testExitedProcessDoesNotPassEvenWithReadyOutput(self):
        child = self.launch("print('STOX_DIAG late ready=true')")
        child.wait(timeout=3)
        result = self.wait_ready(child)
        self.assertEqual(result.returncode, 1)
        self.assertIn("exited", result.stderr)

    def testTimeoutDoesNotRequireDiagnosticsFile(self):
        child = self.launch("import time; time.sleep(20)")
        self.output.unlink()
        result = self.wait_ready(child, "0")
        self.assertEqual(result.returncode, 1)
        self.assertIn("Timed out", result.stderr)

    def testRejectsInvalidTimeout(self):
        child = self.launch("import time; time.sleep(20)")
        for timeout in ("-1", "abc", "0.5"):
            result = self.wait_ready(child, timeout)
            self.assertEqual(result.returncode, 2)


if __name__ == "__main__":
    unittest.main()
