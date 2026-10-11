#!/usr/bin/env bash
# 固定 XcodeGen 版本，并核对上游发布附件的 SHA-256。
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=2.44.1
CHECKSUM=a2e905fb68446e9bb4008cdfe2e13e3f176d0cbcca828b71770f8e53fca91b73
TOOLS="$PWD/.build/tools/xcodegen-$VERSION"
GENERATOR="$TOOLS/xcodegen/bin/xcodegen"
if [[ ! -x "$GENERATOR" ]]; then
  WORK=$(mktemp -d)
  trap 'rm -rf "$WORK"' EXIT
  curl --fail --location --retry 2 --output "$WORK/xcodegen.zip" \
    "https://github.com/yonaskolb/XcodeGen/releases/download/$VERSION/xcodegen.zip"
  printf '%s  %s\n' "$CHECKSUM" "$WORK/xcodegen.zip" | shasum -a 256 -c -
  mkdir -p "$TOOLS"
  ditto -x -k "$WORK/xcodegen.zip" "$TOOLS"
fi
[[ "$($GENERATOR --version)" == "Version: $VERSION" ]] || {
  echo "error: XcodeGen 版本不匹配（需要 $VERSION）" >&2
  exit 1
}
"$GENERATOR" generate --spec project.yml
