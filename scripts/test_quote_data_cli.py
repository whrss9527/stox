import os
import json
import sys
from pathlib import Path
import socketserver
import http.server
import subprocess
import tempfile
import threading
import unittest

ROOT = Path(__file__).resolve().parents[1]
CLI = Path(os.environ.get('STOX_CLI', ROOT / '.build/debug/stox-cli'))
SNAPSHOTS = ROOT / 'Sources/StoxCore/DatasourceSnapshots'


class QuoteDataCLITests(unittest.TestCase):
    def setUp(self):
        if not CLI.is_file():
            if os.environ.get('STOX_REQUIRE_CLI') == '1':
                self.fail('build stox-cli before replay tests')
            self.skipTest('CLI replay checks run after the Swift build')

    def run_cli(self, *args, env=None):
        return subprocess.run([str(CLI), 'check', *args], cwd=ROOT, env=env,
                              capture_output=True, text=True, timeout=10)

    def test_reviewed_raw_responses_pass(self):
        for source, ext in [('tencent', 'txt'), ('sina', 'bin')]:
            result = self.run_cli('--source', source, '--raw', str(SNAPSHOTS / f'{source}.{ext}'), '--at', '2026-10-07T10:00:00Z')
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_field_drift_and_bad_arguments_fail(self):
        with tempfile.TemporaryDirectory() as folder:
            file = Path(folder) / 'raw.txt'
            original = (SNAPSHOTS / 'tencent.txt').read_text()
            file.write_text(original.replace('~', '~inserted~', 1))
            result = self.run_cli('--raw', str(file), '--at', '2026-10-07T10:00:00Z')
            self.assertEqual(result.returncode, 1)
            self.assertIn('fields=89, snapshot=88', result.stdout)
        self.assertEqual(self.run_cli('--source', 'unknown').returncode, 2)

    def test_wrapper_selects_markets_and_appends_all_failures(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            fake = root / 'fake-cli'
            capture = root / 'calls.jsonl'
            report = root / 'failures.md'
            report.write_text('Existing transport failure\n')
            fake.write_text('#!' + sys.executable + '\nimport os,sys,json\nwith open(os.environ["STOX_CLI_CAPTURE"], "a") as f: f.write(json.dumps(sys.argv[1:]) + "\\n")\nprint("field drift fixture")\nsys.exit(1)\n')
            fake.chmod(0o755)
            env = {**os.environ, 'STOX_CLI': str(fake), 'STOX_CLI_CAPTURE': str(capture),
                   'STOX_DATASOURCE_REPORT': str(report), 'STOX_DATASOURCE_RAW_DIR': str(root / 'raw'), 'ONLY': 'US'}
            result = subprocess.run(['/bin/bash', str(ROOT / 'scripts/check-quote-invariants.sh')], env=env,
                                    capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            calls = [json.loads(line) for line in capture.read_text().splitlines()]
            self.assertEqual(len(calls), 2)
            for call in calls:
                self.assertEqual(call[-1], 'usAAPL')
                self.assertNotIn('sh600519', call)
            text = report.read_text()
            self.assertIn('Existing transport failure', text)
            self.assertIn('tencent quote invariant differences', text)
            self.assertIn('sina quote invariant differences', text)
            self.assertEqual(text.count('field drift fixture'), 2)

    def test_failed_http_response_is_saved_before_nonzero_exit(self):
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(503)
                self.end_headers()
                self.wfile.write(b'upstream fixture unavailable')
            def log_message(self, *_):
                pass
        server = socketserver.TCPServer(('127.0.0.1', 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            with tempfile.TemporaryDirectory() as folder:
                raw = Path(folder) / 'response.bin'
                env = {**os.environ, 'STOX_QUOTE_ENDPOINT': f'http://127.0.0.1:{server.server_address[1]}/q='}
                result = self.run_cli('--save-raw', str(raw), env=env)
                self.assertEqual(result.returncode, 1)
                self.assertIn('HTTP status 503', result.stdout)
                self.assertEqual(raw.read_bytes(), b'upstream fixture unavailable')
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)
