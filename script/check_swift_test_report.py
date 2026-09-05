#!/usr/bin/env python3
"""Reject Swift Testing runs that exited before writing a complete result."""

import argparse
from pathlib import Path
import sys
import xml.etree.ElementTree as ET


def completed_test_count(path):
    # Swift Testing's JUnitXMLRecorder writes cases and closing XML only on
    # runEnded; an early exit leaves the runStarted preamble unclosed.
    root = ET.parse(path).getroot()
    if any(int(suite.get(key, "0")) != 0 for suite in root.iter("testsuite")
           for key in ("failures", "errors")):
        raise ValueError("report contains suite failures or errors")
    cases = list(root.iter("testcase"))
    if not cases:
        raise ValueError("report contains no tests")
    if any(case.find("failure") is not None or case.find("error") is not None for case in cases):
        raise ValueError("report contains failed tests")
    completed = sum(case.find("skipped") is None for case in cases)
    if not completed:
        raise ValueError("report contains only skipped tests")
    return completed


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("report", type=Path)
    parser.add_argument("--swiftpm-output", action="store_true",
                        help="resolve SwiftPM's Swift Testing report beside the requested xUnit path")
    arguments = parser.parse_args()
    report = arguments.report
    if arguments.swiftpm_output:
        report = report.with_stem(report.stem + "-swift-testing")
    try:
        count = completed_test_count(report)
    except (OSError, ET.ParseError, ValueError) as error:
        sys.exit(f"Incomplete or unsuccessful Swift Testing run: {error}")
    print(f"Verified complete Swift Testing report: {count} test cases.")
