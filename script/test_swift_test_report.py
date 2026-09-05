#!/usr/bin/env python3
"""Regression checks for premature successful exits from the native test runner."""

import tempfile
import subprocess
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

from check_swift_test_report import completed_test_count


class SwiftTestReportTests(unittest.TestCase):
    def test_output_path_is_required_before_help_or_version(self):
        script = Path(__file__).with_name('test.sh').resolve()
        for arguments in [[], ['--version'], ['--help'], ['--list-tests'], ['']]:
            with self.subTest(arguments=arguments):
                result = subprocess.run(
                    [str(script), 'sidebar', '--xunit-output', *arguments],
                    capture_output=True, text=True, timeout=10,
                )
                self.assertEqual(result.returncode, 2)
                self.assertIn('--xunit-output requires a path.', result.stderr)

    def test_report_completion(self):
        fixtures = [
            ('<testsuites><testsuite><testcase name="one"/></testsuite></testsuites>', 1),
            ('<testsuites><testsuite><testcase/><testcase><skipped/></testcase></testsuite></testsuites>', 1),
            ('<testsuites>', ET.ParseError),
            ('<testsuites><testsuite/></testsuites>', ValueError),
            ('<testsuites><testsuite failures="1"><testcase/></testsuite></testsuites>', ValueError),
            ('<testsuites><testcase><failure/></testcase></testsuites>', ValueError),
            ('<testsuites><testcase><error/></testcase></testsuites>', ValueError),
            ('<testsuites><testcase><skipped/></testcase></testsuites>', ValueError),
        ]
        with tempfile.TemporaryDirectory() as directory:
            report = Path(directory) / 'result.xml'
            for xml, expected in fixtures:
                with self.subTest(xml=xml):
                    report.write_text(xml)
                    if isinstance(expected, int):
                        self.assertEqual(completed_test_count(report), expected)
                    else:
                        with self.assertRaises(expected):
                            completed_test_count(report)
            report.unlink()
            with self.assertRaises(FileNotFoundError):
                completed_test_count(report)


if __name__ == '__main__':
    unittest.main()
