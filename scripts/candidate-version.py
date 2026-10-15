#!/usr/bin/env python3
"""读取首个候选版本章节，并可核对实际构建包；不回落到旧git标签。"""
import argparse
from pathlib import Path
import plistlib
import re
import sys


def candidate_version(changelog):
    heading = re.search(r"^##[ \t]+(.+?)\s*$", changelog.read_text(), re.M)
    if not heading:
        raise ValueError("CHANGELOG缺少候选版本章节")
    number = r"(?:0|[1-9][0-9]*)"
    match = re.fullmatch(r"(" + number + r"\." + number + r"\." + number + r")(?:[ \t]*[（(][^()（）\r\n]*[）)])?", heading[1])
    if not match:
        raise ValueError("CHANGELOG首个章节不是有效候选版本：" + heading[1])
    return match[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--changelog", type=Path, default=Path(__file__).resolve().parents[1] / "CHANGELOG.md")
    parser.add_argument("--bundle", type=Path)
    args = parser.parse_args()
    version = candidate_version(args.changelog)
    if args.bundle:
        with (args.bundle / "Contents/Info.plist").open("rb") as source:
            actual = plistlib.load(source).get("CFBundleShortVersionString")
        if actual != version:
            raise ValueError(f"构建包与候选版本不一致：{actual!r} != {version}")
    print(version)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError) as error:
        sys.exit(str(error))
