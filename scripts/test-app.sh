#!/usr/bin/env bash
# 主 App 测试使用 Xcode 宿主，Core 测试继续由 SwiftPM 运行。
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/generate-project.sh
xcodebuild test -project Stox.xcodeproj -scheme Stox \
  -destination 'platform=macOS' -derivedDataPath .build/xcode/tests \
  CODE_SIGNING_ALLOWED=NO
