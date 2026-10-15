import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


class AppIntentsMetadataTests(unittest.TestCase):
    def invoke(self, change=None):
        with tempfile.TemporaryDirectory(prefix="Stox intents ' ") as temporary:
            app = Path(temporary) / "Stox.app"
            metadata = app / "Contents/Resources/Metadata.appintents"
            metadata.mkdir(parents=True)
            data = {"actions": {"QueryStockPriceIntent": {"parameters": [{"name": "code", "isOptional": False}]},
                                "OpenStoxPanelIntent": {"openAppWhenRun": True}},
                    "autoShortcuts": [{"actionIdentifier": name, "phraseTemplates": [{"key": "phrase"}]}
                                      for name in ("QueryStockPriceIntent", "OpenStoxPanelIntent")]}
            if change:
                change(data)
            (metadata / "extract.actionsdata").write_text(json.dumps(data))
            (metadata / "version.json").write_text('{"version":"3.0"}')
            return subprocess.run([sys.executable, str(Path(__file__).with_name("check-app-intents.py")), str(app)],
                                  capture_output=True, text=True, timeout=5)

    def testBothActionsAndShortcutsAreRequired(self):
        self.assertEqual(self.invoke().returncode, 0)
        for change in (lambda data: data["actions"].pop("QueryStockPriceIntent"),
                       lambda data: data["actions"]["OpenStoxPanelIntent"].update(openAppWhenRun=False),
                       lambda data: data["actions"]["QueryStockPriceIntent"].update(parameters=[]),
                       lambda data: data.update(autoShortcuts=[])):
            with self.subTest(change=change):
                result = self.invoke(change)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("元数据验证失败", result.stderr)
