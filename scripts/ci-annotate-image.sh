#!/usr/bin/env bash
# CI 辅助：把图片以 base64 分段写成检查注释（notice），便于在无法下载构建产物的环境里通过 API 取回。
# GitHub 限制每条注释约 4KB、每个步骤最多 10 条 notice，所以按 4000 字符分段，每次调用最多输出 10 段。
# 用法: scripts/ci-annotate-image.sh <名称> <图片> <起始段号，从 1 开始>
set -euo pipefail
name="$1"
file="$2"
first="$3"
[ -f "$file" ] || exit 0
b64="$(base64 -i "$file" | tr -d '\n')"
size=4000
total=$(( (${#b64} + size - 1) / size ))
last=$(( first + 9 < total ? first + 9 : total ))
for i in $(seq "$first" "$last"); do
  echo "::notice title=screenshot $name $i/$total::${b64:$(( (i - 1) * size )):$size}"
done
