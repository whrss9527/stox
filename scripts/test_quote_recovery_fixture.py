import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.error
import urllib.request


class QuoteRecoveryFixtureTests(unittest.TestCase):
    def test_starts_without_reverse_dns_and_recovers(self):
        fixture = Path(__file__).with_name('quote-recovery-fixture.py')
        # A DNS lookup can block macOS CI on a local-network permission dialog.
        code = "import socket,sys,runpy; socket.getfqdn=lambda *_: (_ for _ in ()).throw(RuntimeError('unexpected reverse DNS')); sys.argv=sys.argv[1:]; runpy.run_path(sys.argv[0],run_name='__main__')"
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            process = subprocess.Popen([sys.executable, '-c', code, str(fixture), folder], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                for _ in range(50):
                    if (root / 'port').exists() or process.poll() is not None:
                        break
                    time.sleep(.1)
                self.assertTrue((root / 'port').exists(), 'fixture did not start')
                url = 'http://127.0.0.1:' + (root / 'port').read_text() + '/primary?q=sh600519'
                with self.assertRaises(urllib.error.HTTPError) as failed:
                    urllib.request.urlopen(url, timeout=2)
                self.assertEqual(failed.exception.code, 503)
                failed.exception.close()
                (root / 'recover').touch()
                with urllib.request.urlopen(url, timeout=2) as response:
                    self.assertEqual(response.status, 200)
                    self.assertIn(b'~100.00~', response.read())
                requests = [json.loads(line) for line in (root / 'requests.jsonl').read_text().splitlines()]
                self.assertEqual([r['status'] for r in requests], [503, 200])
            finally:
                process.terminate()
                process.communicate(timeout=5)
