# coding: utf-8
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent


class ReleaseNotesScriptTests(unittest.TestCase):
    def render(self, heading, version, notarized=False):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root/'scripts').mkdir()
            (root/'.github').mkdir()
            shutil.copy(ROOT/'scripts/release-notes.sh', root/'scripts/release-notes.sh')
            for filename in ['release-notes.md', 'release-notes-notarized.md']:
                shutil.copy(ROOT/'.github'/filename, root/'.github'/filename)
            (root/'CHANGELOG.md').write_text(f'# Changes\n\n{heading}\n\n### 中文\n- 选中改动\n\n### English\n- Selected change\n\n## 9.9.99\n- Wrong version\n')
            result = subprocess.run(['bash', str(root/'scripts/release-notes.sh'), version],
                                    env=dict(os.environ, NOTARIZED='1' if notarized else '0'), capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            return result.stdout

    def test_dated_and_undated_headings_keep_only_the_selected_version(self):
        for heading in ['## 9.9.9', '## 9.9.9（2026-10-06）', '## 9.9.9 (2026-10-06)']:
            with self.subTest(heading=heading):
                notes = self.render(heading, 'v9.9.9')
                self.assertIn('选中改动', notes)
                self.assertIn('Selected change', notes)
                self.assertNotIn('Wrong version', notes)
                self.assertIn('## 安装', notes)
                self.assertIn('## Installation', notes)

    def test_notarized_and_adhoc_instructions_are_bilingual(self):
        notarized = self.render('## 9.9.9', '9.9.9', True)
        self.assertIn('苹果公证', notarized)
        self.assertIn('notarized by Apple', notarized)
        self.assertNotIn('xattr -dr', notarized)
        adhoc = self.render('## 9.9.9', '9.9.9')
        self.assertIn('ad-hoc signing', adhoc)
        self.assertIn('xattr -dr', adhoc)
