"""The interface must ship all three supported localization tables."""
import contextlib
import importlib.util
import io
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

SCRIPT = Path(__file__).with_name("check-localization.py")
spec = importlib.util.spec_from_file_location("check_localization_tables", SCRIPT)
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)


class LocalizationTableTests(unittest.TestCase):
    def check(self, languages):
        with tempfile.TemporaryDirectory() as temporary:
            resources = Path(temporary)
            for language in languages:
                directory = resources / (language + ".lproj")
                directory.mkdir()
                (directory / "Localizable.strings").write_text('"设置…" = "Settings…";\n')
            with patch.object(checker, "RESOURCES", resources), patch.object(checker, "scan", return_value=({"设置…": "fixture"}, [])):
                with contextlib.redirect_stdout(io.StringIO()) as output:
                    result = checker.main()
            return result, output.getvalue()

    def testAllSupportedTablesPass(self):
        result, _ = self.check(["en", "zh-Hans", "zh-Hant"])
        self.assertEqual(result, 0)

    def testMissingTraditionalTableFailsInsteadOfReducingCoverage(self):
        result, output = self.check(["en", "zh-Hans"])
        self.assertEqual(result, 1)
        self.assertIn("zh-Hant.lproj", output)


if __name__ == "__main__":
    unittest.main()
