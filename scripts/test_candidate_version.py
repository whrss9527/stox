from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("candidate-version.py")


class CandidateVersionTests(unittest.TestCase):
    def invoke(self, root, text, bundle=None):
        changelog = root / "CHANGELOG.md"
        changelog.write_text(text)
        command = [sys.executable, str(SCRIPT), "--changelog", str(changelog)]
        if bundle:
            command += ["--bundle", str(bundle)]
        return subprocess.run(command, cwd=root, capture_output=True, text=True, timeout=5)

    def testOldGitTagCannotOverrideNewCandidate(self):
        with tempfile.TemporaryDirectory(prefix="stox candidate ' ") as temporary:
            root = Path(temporary)
            subprocess.run(["git", "init", "--quiet", str(root)], check=True)
            subprocess.run(["git", "-C", str(root), "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                            "commit", "--quiet", "--allow-empty", "-m", "Old release"], check=True)
            subprocess.run(["git", "-C", str(root), "tag", "v1.5.0"], check=True)
            result = self.invoke(root, "# 更新日志\n\n## 1.6.0（未发布）\n\n## 1.5.0\n")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), "1.6.0")
            self.assertEqual(subprocess.check_output(["git", "-C", str(root), "describe", "--tags", "--abbrev=0"], text=True).strip(), "v1.5.0")

    def testMalformedFirstHeadingNeverFallsBackToAnOlderVersion(self):
        for heading in ("未发布", "1.06.0", "1.6.0broken", "1.6.0（未闭合"):
            with self.subTest(heading=heading), tempfile.TemporaryDirectory() as temporary:
                result = self.invoke(Path(temporary), "# 更新日志\n\n## " + heading + "\n\n## 1.5.0\n")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("首个章节", result.stderr)

    def testDatesAndMissingHeading(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.assertEqual(self.invoke(root, "## 1.6.0 (2026-10-16)\n").stdout.strip(), "1.6.0")
            self.assertNotEqual(self.invoke(root, "# 更新日志\n没有版本\n").returncode, 0)

    def testActualBinaryPlistVersionMustMatchCandidate(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            bundle = root / "Stox.app"
            info = bundle / "Contents/Info.plist"
            info.parent.mkdir(parents=True)
            for actual, status in (("1.5.0", 1), ("1.6.0", 0)):
                info.write_bytes(plistlib.dumps({"CFBundleShortVersionString": actual}, fmt=plistlib.FMT_BINARY))
                result = self.invoke(root, "## 1.6.0（未发布）\n", bundle)
                self.assertEqual(result.returncode, status, result.stderr)
                if status:
                    self.assertIn("版本不一致", result.stderr)


if __name__ == "__main__":
    unittest.main()
