#!/usr/bin/env bash
# 生成 GitHub 发布说明：先放 CHANGELOG.md 里这个版本的一节（“更新内容”），再放安装步骤。
# 用法: scripts/release-notes.sh v0.13.0 > notes.md
# 发布流程公证过时（环境变量 NOTARIZED=1）用 .github/release-notes-notarized.md 里的安装步骤，否则用 .github/release-notes.md。
set -euo pipefail
cd "$(dirname "$0")/.."

version="${1#v}"
section=$(awk -v heading="## ${version}" '
  $0 == heading { found = 1; next }
  found && /^## / { exit }
  found { print }
' CHANGELOG.md | sed -e '/./,$!d')

if [[ -n "${section//[[:space:]]/}" ]]; then
  printf '## 更新内容\n\n%s\n\n' "$section"
else
  echo "::warning::CHANGELOG.md 里没有 ${version} 这一节" >&2
fi
if [[ "${NOTARIZED:-}" == "1" ]]; then
  cat .github/release-notes-notarized.md
else
  cat .github/release-notes.md
fi
