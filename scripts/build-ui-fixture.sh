#!/usr/bin/env bash
# Build only. Never launches the app or changes the installed Stox / user preferences.
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/generate-project.sh
derived="$PWD/.build/xcode/ui-fixture"
output="$PWD/.build/ui-fixture/Stox UI Fixture.app"
version="$(python3 scripts/candidate-version.py)"
mkdir -p "$PWD/.build/ui-fixture"
python3 - "$PWD/Resources/Info.plist" "$PWD/.build/ui-fixture/Info.plist" "$PWD/.build/ui-fixture/fixture.entitlements" "$version" <<'PY'
import plistlib
from pathlib import Path
import sys
info = plistlib.loads(Path(sys.argv[1]).read_bytes())
info.update(CFBundleIdentifier='io.github.whrss9527.stox.uifixture20261107',
            CFBundleDisplayName='Stox UI Fixture', CFBundleName='Stox UI Fixture',
            StoxUIFixture=True, CFBundleShortVersionString=sys.argv[4])
info.pop('CFBundleURLTypes', None)
Path(sys.argv[2]).write_bytes(plistlib.dumps(info))
# No network client/server or iCloud entitlement. The kernel denies real networking.
Path(sys.argv[3]).write_bytes(plistlib.dumps({'com.apple.security.app-sandbox': True}))
PY
xcodebuild build -project Stox.xcodeproj -scheme Stox -configuration Debug \
  -derivedDataPath "$derived" -jobs 2 CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ENABLE_DEBUG_DYLIB=NO \
  "INFOPLIST_FILE=$PWD/.build/ui-fixture/Info.plist" \
  PRODUCT_BUNDLE_IDENTIFIER=io.github.whrss9527.stox.uifixture20261107 \
  'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) STOX_UI_FIXTURE'
rm -rf "$output"
ditto "$derived/Build/Products/Debug/Stox.app" "$output"
if [[ -e "$output/Contents/MacOS/Stox.debug.dylib" || -e "$output/Contents/MacOS/__preview.dylib" ]]; then
  echo "error: fixture must link directly without unsigned Debug/preview dylibs" >&2
  exit 1
fi
codesign --force --sign - --options runtime --entitlements "$PWD/.build/ui-fixture/fixture.entitlements" "$output"
codesign --verify --deep --strict "$output"
printf 'Built (not launched): %s\n' "$output"
