#!/usr/bin/env python3
"""Regression checks for premature successful exits from the native test runner."""

import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

from check_swift_test_report import completed_test_count


class SwiftTestReportTests(unittest.TestCase):
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
