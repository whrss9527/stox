# coding: utf-8
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('datasources', ROOT/'scripts/validate-datasource.py')
validator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(validator)


def quotes():
    lines = []
    for symbol in ['sh600519', 'sz000001', 'sh000001']:
        fields = [''] * 32
        fields[1:4] = ['Stock', symbol, '12.34']
        lines.append(f'v_{symbol}="' + '~'.join(fields) + '";')
    return '\n'.join(lines)


class DatasourceTests(unittest.TestCase):
    def test_required_quote_fields_and_expected_invalid_symbols(self):
        validator.validate('tencent quote: A shares + indices', quotes())
        for body in ['', 'v_sh600519="";', quotes().replace('12.34', 'price')]:
            with self.assertRaises(ValueError):
                validator.validate('tencent quote: A shares + indices', body)
        validator.validate('tencent quote: US index usIXIC', 'v_usIXIC="";')

    def test_json_contract_rejects_bad_or_missing_data(self):
        validator.validate('minute', '{"code":0,"data":{}}', True)
        for body in ['<html>failure</html>', '[]', '{}', '{"code":-1,"data":{}}']:
            with self.assertRaises(ValueError):
                validator.validate('minute', body, True)

    def run_probe(self, body, curl_status=0, only=r'^tencent quote: A shares'):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            curl = root/'curl'
            curl.write_text('''#!/usr/bin/env python3
import os, pathlib, sys
args=sys.argv[1:]
pathlib.Path(args[args.index('-D')+1]).write_text('HTTP/1.1 200 OK\\nContent-Type: text/plain\\n')
if os.environ['FAKE_CURL_STATUS'] != '0':
    sys.stderr.write('request failed\\n')
    sys.exit(int(os.environ['FAKE_CURL_STATUS']))
pathlib.Path(args[args.index('-o')+1]).write_text(os.environ['FAKE_CURL_BODY'])
''')
            curl.chmod(0o755)
            report = root/'failures.md'
            env = dict(os.environ, PATH=f'{root}:'+os.environ['PATH'], ONLY=only,
                       FAKE_CURL_BODY=body, FAKE_CURL_STATUS=str(curl_status), STOX_DATASOURCE_REPORT=str(report))
            result = subprocess.run(['bash', str(ROOT/'scripts/check-datasources.sh')], env=env, capture_output=True, text=True)
            return result.returncode, report.read_text(), result.stdout+result.stderr

    def test_request_failure_returns_nonzero_and_reports_the_endpoint(self):
        code, report, output = self.run_probe('', 22)
        self.assertNotEqual(code, 0, output)
        self.assertIn('qt.gtimg.cn/q=', report)
        self.assertIn('request failed', report)
        self.assertIn('::error::', output)

    def test_missing_fields_returns_nonzero_and_preserves_response_excerpt(self):
        code, report, output = self.run_probe('v_sh600519="changed";')
        self.assertNotEqual(code, 0, output)
        self.assertIn('changed', report)
        self.assertIn('关键字段', report)

    def test_all_download_paths_report_request_failures(self):
        for title in ['tencent minute: sh600519', 'tencent quote fields: US',
                      'tencent usfqkline pandata: usAAPL.OQ', 'tencent 5-day: sh600519',
                      'tencent hkfqkline: hk00700']:
            with self.subTest(title=title):
                code, report, output = self.run_probe('', 22, '^' + title + '$')
                self.assertNotEqual(code, 0, output)
                self.assertIn(title, report)

    def test_malformed_json_is_a_probe_failure(self):
        code, report, output = self.run_probe('<html>broken</html>', only='^tencent minute: sh600519$')
        self.assertNotEqual(code, 0, output)
        self.assertIn('broken', report)

    def test_valid_probe_succeeds_without_failure_report(self):
        code, report, output = self.run_probe(quotes())
        self.assertEqual(code, 0, output)
        self.assertEqual(report, '')
