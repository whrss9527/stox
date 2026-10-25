"""Exercise the real smoke predicate against diagnostic-count boundaries."""
import shlex
import subprocess
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("ci-e2e.sh")


class CalendarCountTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        lines = [line.strip() for line in SCRIPT.read_text().splitlines()
                 if line.strip().startswith("grep -Eq ") and 'shots/calendar.log' in line]
        if len(lines) != 1:
            raise AssertionError("expected one calendar day-count smoke predicate")
        # Execute the production grep command with stdin fixtures, not a copy of its pattern.
        cls.command = shlex.split(lines[0])[:3]

    def matches(self, text):
        result = subprocess.run(self.command, input=text, text=True, capture_output=True, timeout=2)
        self.assertIn(result.returncode, (0, 1), result.stderr)
        return result.returncode == 0

    def test_accepts_at_least_two_recorded_days(self):
        for count in (2, 9, 10, 14, 19, 20, 31, 100):
            with self.subTest(count=count):
                self.assertTrue(self.matches(f"STOX_DIAG route=calendar calendar={count} calendar_months=5\n"))

    def test_rejects_missing_insufficient_and_non_integer_fields(self):
        for field in ("calendar=0", "calendar=1", "calendar=", "calendar=-2", "calendar=2.5",
                      "calendar=14x", "calendar=2x", "calendar=NaN", "calendar_months=14", "mycalendar=2", ""):
            with self.subTest(field=field):
                self.assertFalse(self.matches(f"STOX_DIAG route=calendar {field}\n"))

    def test_accepts_field_at_line_boundaries(self):
        self.assertTrue(self.matches("calendar=14\n"))
        self.assertTrue(self.matches("STOX_DIAG calendar=2\n"))


if __name__ == "__main__":
    unittest.main()
