#!/usr/bin/env bash
# CI 辅助：把选中的截图（<目录>/<名字>-preview.jpg）以 base64 分段写成检查注释（notice），
# 便于在无法下载构建产物的环境里通过 GitHub API 取回截图。注释的标题是“screenshot <名字> <第几段>/<共几段>”。
# 要哪几张由 <目录>/annotate.txt 决定（空格或换行分隔的名字），没有这个文件时只取 panel。目录默认是 shots。
# GitHub 限制每条注释约 4KB、每个步骤最多 10 条 notice、每个任务最多 50 条，所以所有图片按 4000 字符统一分段编号，
# 第 k 次调用（k 从 1 开始）只输出第 10k-9 到 10k 段。
# 用法: scripts/ci-annotate-image.sh <k> [目录]
set -euo pipefail
slot="$1"
dir="${2:-shots}"
size=4000
first=$(( (slot - 1) * 10 + 1 ))
last=$(( slot * 10 ))
names="$(cat "$dir/annotate.txt" 2>/dev/null || echo panel)"
n=0
for name in $names; do
  file="$dir/$name-preview.jpg"
  [ -f "$file" ] || continue
  b64="$(base64 < "$file" | tr -d '\n')"
  total=$(( (${#b64} + size - 1) / size ))
  for i in $(seq 1 "$total"); do
    n=$(( n + 1 ))
    if [ "$n" -ge "$first" ] && [ "$n" -le "$last" ]; then
      echo "::notice title=screenshot $name $i/$total::${b64:$(( (i - 1) * size )):$size}"
    fi
  done
done
