#!/usr/bin/env python3
# coding: utf-8
"""只检查正式探测的关键字段；诊断中的无效代码和候选写法可以返回空值。"""
import argparse
import json
import pathlib
import re


def validate(title, text, json_response=False):
    if not text.strip():
        raise ValueError('返回为空')
    if json_response:
        body = json.loads(text)
        if not isinstance(body, dict):
            raise ValueError('JSON 顶层不是对象')
        if 'data' not in body:
            raise ValueError('JSON 缺少 data 字段')
        if body.get('code', 0) not in (0, '0'):
            raise ValueError(f"接口错误码：{body.get('code')}")
    required = {
        'tencent quote: A shares + indices': ['sh600519', 'sz000001', 'sh000001'],
        'tencent quote: HK': ['hk00700', 'hk09988', 'hkHSI'],
        'tencent quote: US': ['usAAPL', 'usBABA', 'usTSLA'],
        'tencent quote: invalid code mixed in': ['sh600519', 'hk00700'],
        'tencent quote: utf8 path': ['sh600519', 'hk00700'],
    }.get(title, [])
    quotes = dict(re.findall(r'v_([^=]+)="([^"]*)"', text))
    for symbol in required:
        fields = quotes.get(symbol, '').split('~')
        if len(fields) < 32 or not fields[1] or not fields[2]:
            raise ValueError(f'{symbol} 缺少行情关键字段')
        try:
            float(fields[3])
        except ValueError:
            raise ValueError(f'{symbol} 价格字段不是数字') from None
    if title == 'sina quote (fallback)':
        payload = re.search(r'(?:var\s+)?hq_str_sh600519="([^"]*)"', text)
        fields = payload[1].split(',') if payload else []
        if len(fields) < 32 or not fields[0]:
            raise ValueError('新浪 sh600519 缺少行情关键字段')
        try:
            float(fields[3])
        except ValueError:
            raise ValueError('新浪价格字段不是数字') from None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('title')
    parser.add_argument('file')
    parser.add_argument('encoding')
    parser.add_argument('--json', action='store_true')
    args = parser.parse_args()
    validate(args.title, pathlib.Path(args.file).read_bytes().decode(args.encoding), args.json)


if __name__ == '__main__':
    main()
