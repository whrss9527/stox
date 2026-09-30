#!/usr/bin/env python3
"""检查界面文字的翻译是否齐全。

代码里显示给用户的中文都写成 L("中文原文", 参数…)，原文就是 Localizable.strings 里的键。这个脚本检查：

1. Sources/Stox 和 Sources/StoxCore 里每个 L("…") 的键，在每种语言的 Resources/<语言>.lproj/Localizable.strings 里都有；
2. 各种语言的键完全一样，没有多出来的（代码里已经不用的）键；
3. 译文里的占位（%@、%1$@）和键里的一样多；
4. 代码里没有漏掉 L(...) 的中文字符串。日志（Log.info / Log.error）、诊断输出（print）、
   以及行尾带 `// l10n-ignore` 的数据（比如默认自选的名称、发布说明的标题）不算。

用法: scripts/check-localization.py [--print-keys]
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCES = [ROOT / "Sources" / "Stox", ROOT / "Sources" / "StoxCore"]
RESOURCES = ROOT / "Resources"
# 中文（汉字和全角标点）。
CHINESE = re.compile(r"[\u3000-\u303f\u4e00-\u9fff\uff00-\uffef“”‘’…]")
# 这些行不是界面文字。
IGNORED_LINE = re.compile(r"Log\.(info|error|warn|debug)\(|print\(|STOX_DIAG|l10n-ignore|debugDescription:")
# 整个文件都是数据：期货外汇的品种表（名称和搜索用的别名）。
IGNORED_FILES = {"GlobalMarkets.swift"}
PLACEHOLDER = re.compile(r"%(?:\d+\$)?@")


def literal_end(line, start):
    """line[start] 是开头的引号，返回结尾引号后面的位置（跳过 \\( … ) 里嵌套的字符串）。"""
    i = start + 1
    while i < len(line):
        c = line[i]
        if c == "\\":
            if line.startswith("\\(", i):
                depth, i = 1, i + 2
                while i < len(line) and depth:
                    if line[i] == '"':
                        i = literal_end(line, i)
                        continue
                    depth += {"(": 1, ")": -1}.get(line[i], 0)
                    i += 1
                continue
            i += 2
            continue
        if c == '"':
            return i + 1
        i += 1
    return len(line)


def literals(line):
    """一行代码里（去掉 // 注释）的字符串字面量：(开始位置, 内容)。"""
    i = 0
    while i < len(line):
        if line.startswith("//", i):
            return
        if line[i] == '"':
            end = literal_end(line, i)
            yield i, line[i + 1:end - 1]
            i = end
            continue
        i += 1


def scan():
    keys, unwrapped = {}, []
    for folder in SOURCES:
        for path in sorted(folder.glob("*.swift")):
            if path.name in IGNORED_FILES:
                continue
            for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
                if line.strip().startswith("//"):
                    continue
                where = f"{path.relative_to(ROOT)}:{number}"
                for start, text in literals(line):
                    wrapped = re.search(r"(?<![A-Za-z0-9_])L\(\s*$", line[:start]) is not None
                    if wrapped:
                        if "\\(" in text:
                            unwrapped.append(f"{where}: L() 的键里不能有插值，用 %@ 占位：\"{text}\"")
                        keys.setdefault(unescape(text), where)
                    elif CHINESE.search(re.sub(r"\\\(.*?\)", "", text)) and not IGNORED_LINE.search(line):
                        unwrapped.append(f"{where}: 中文没有经过 L()：\"{text}\"")
    return keys, unwrapped


def unescape(text):
    return text.replace('\\"', '"').replace("\\n", "\n").replace("\\t", "\t").replace("\\\\", "\\")


def parse_strings(path):
    table = {}
    pattern = re.compile(r'^\s*"((?:[^"\\\n]|\\.)*)"\s*=\s*"((?:[^"\\\n]|\\.)*)"\s*;\s*$', re.M)
    for m in pattern.finditer(path.read_text(encoding="utf-8")):
        key = unescape(m.group(1))
        if key in table:
            print(f"{path.relative_to(ROOT)}: 键重复：\"{m.group(1)}\"")
            table["\0duplicate"] = ""
        table[key] = unescape(m.group(2))
    return table


def main():
    keys, unwrapped = scan()
    if "--print-keys" in sys.argv:
        for key in sorted(keys):
            print(key.replace("\n", "\\n").replace("\t", "\\t"))
        return 0
    status = 0
    for problem in unwrapped:
        print(problem)
        status = 1
    tables = {p.parent.name: parse_strings(p) for p in sorted(RESOURCES.glob("*.lproj/Localizable.strings"))}
    if not tables:
        print("Resources 里没有 Localizable.strings")
        return 1
    for lang, table in tables.items():
        if "\0duplicate" in table:
            status = 1
            del table["\0duplicate"]
        missing = sorted(k for k in keys if k not in table)
        unused = sorted(k for k in table if k not in keys)
        for key in missing:
            print(f"{lang}: 缺少 \"{key}\"（{keys[key]}）")
        for key in unused:
            print(f"{lang}: 代码里没有用到 \"{key}\"")
        mismatched = [k for k in keys if k in table and len(PLACEHOLDER.findall(k)) != len(PLACEHOLDER.findall(table[k]))]
        for key in mismatched:
            print(f"{lang}: 占位数量不对 \"{key}\" = \"{table[key]}\"")
        if missing or unused or mismatched:
            status = 1
        print(f"{lang}: {len(table)} 条，缺 {len(missing)} 条，多 {len(unused)} 条，占位不对 {len(mismatched)} 条")
    print(f"代码里的键 {len(keys)} 个，漏掉 L() 的中文 {len(unwrapped)} 处")
    return status


if __name__ == "__main__":
    sys.exit(main())
