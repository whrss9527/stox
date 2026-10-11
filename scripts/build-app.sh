#!/usr/bin/env bash
# 构建 Stox.app：xcodebuild (Release) → 组装 .app → 生成图标 → 签名。
#
#   scripts/build-app.sh                 本机架构
#   UNIVERSAL=1 scripts/build-app.sh     Apple 芯片 + Intel 通用版（需要完整 Xcode）
#   CODESIGN_IDENTITY="Developer ID Application: ..." scripts/build-app.sh   用自己的证书签名
#   ZIP=1 scripts/build-app.sh           另外打成 dist/Stox.zip（发布用）
#   STOX_FLAVOR=appstore scripts/build-app.sh   App Store 版（-D APP_STORE：没有一键更新，沙盒运行），
#                                        产物放在 dist/appstore/Stox.app；签名和打包见 scripts/build-app-store.sh
#   CODESIGN_ENTITLEMENTS=文件            签名时带上这些 entitlement（App Store 版必须有沙盒）
#   PROVISIONING_PROFILE=文件             签名前放进 Contents/embedded.provisionprofile（App Store 版上传时必须有）
#
# 产物: dist/Stox.app
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Stox"
FLAVOR="${STOX_FLAVOR:-github}"
# 两个版本用不同的编译目录，互相不会冲掉对方的编译缓存。
SCHEME="Stox"
DERIVED_DATA=".build/xcode/github"
case "$FLAVOR" in
  github)
    DIST="dist"
    ;;
  appstore)
    DIST="dist/appstore"
    SCHEME="StoxAppStore"
    DERIVED_DATA=".build/xcode/appstore"
    ;;
  *)
    echo "error: STOX_FLAVOR 只能是 github 或 appstore（现在是 ${FLAVOR}）" >&2
    exit 2
    ;;
esac
APP="$DIST/$APP_NAME.app"

VERSION="${VERSION:-}"
if [[ -z "$VERSION" ]]; then
  VERSION="$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)"
fi
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"

ARCH_FLAGS=(ONLY_ACTIVE_ARCH=YES)
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  ARCH_FLAGS=("ARCHS=arm64 x86_64" ONLY_ACTIVE_ARCH=NO)
fi

scripts/generate-project.sh
echo "==> 编译 $APP_NAME $VERSION ($BUILD_NUMBER) $FLAVOR"
xcodebuild build -project Stox.xcodeproj -scheme "$SCHEME" -configuration Release \
  -derivedDataPath "$DERIVED_DATA" CODE_SIGNING_ALLOWED=NO \
  "MARKETING_VERSION=$VERSION" "CURRENT_PROJECT_VERSION=$BUILD_NUMBER" "${ARCH_FLAGS[@]}"
echo "==> 组装 $APP"
rm -rf "$APP"
mkdir -p "$DIST"
ditto "$DERIVED_DATA/Build/Products/Release/$APP_NAME.app" "$APP"
cp Resources/Info.plist "$APP/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$APP/Contents/Info.plist"
# 界面文字的翻译：英文和简体中文，按系统语言选（见 Sources/StoxCore/AppLanguage.swift）。
for lproj in Resources/*.lproj; do
  cp -R "$lproj" "$APP/Contents/Resources/"
done
if [[ "$FLAVOR" == "appstore" ]]; then
  # 只用 HTTPS（系统自带的加密），出口合规可以豁免；声明了以后每次上传不用再在 App Store Connect 里回答。
  plutil -replace ITSAppUsesNonExemptEncryption -bool NO "$APP/Contents/Info.plist"
fi
if [[ -n "${PROVISIONING_PROFILE:-}" ]]; then
  cp "$PROVISIONING_PROFILE" "$APP/Contents/embedded.provisionprofile"
fi

echo "==> 生成图标"
ICON_TMP="$(mktemp -d)"
if swift scripts/make-icon.swift "$ICON_TMP/AppIcon.iconset" \
  && iconutil -c icns "$ICON_TMP/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"; then
  :
else
  echo "warning: 图标生成失败，继续使用系统默认图标" >&2
fi
rm -rf "$ICON_TMP"

echo "==> 签名"
# 都开 hardened runtime（公证要求；ad-hoc 的构建也开，CI 里测到的就是发布出去的运行方式）。
# 有开发者证书时带安全时间戳（公证要求），ad-hoc 签名不能带时间戳。
# 发布时由 Frit 的发布流程导入证书，设好 CODESIGN_IDENTITY 和 CODESIGN_KEYCHAIN。
IDENTITY="${CODESIGN_IDENTITY:--}"
# 证书名字里有空格，用数组（数组一开始就不空，bash 3.2 在 set -u 下展开也没问题）。
SIGN_ARGS=(--force --options runtime --sign "$IDENTITY")
if [[ "$IDENTITY" != "-" ]]; then
  SIGN_ARGS+=(--timestamp)
fi
if [[ -n "${CODESIGN_KEYCHAIN:-}" ]]; then
  SIGN_ARGS+=(--keychain "$CODESIGN_KEYCHAIN")
fi
if [[ -n "${CODESIGN_ENTITLEMENTS:-}" ]]; then
  SIGN_ARGS+=(--entitlements "$CODESIGN_ENTITLEMENTS")
elif [[ "$FLAVOR" == "appstore" ]]; then
  echo "error: App Store 版必须带沙盒的 entitlement 签名，请用 scripts/build-app-store.sh" >&2
  exit 2
fi
codesign "${SIGN_ARGS[@]}" "$APP"
codesign --verify --strict --verbose=2 "$APP"

if [[ "${ZIP:-0}" == "1" ]]; then
  (cd "$DIST" && rm -f "$APP_NAME.zip" && ditto -c -k --keepParent "$APP_NAME.app" "$APP_NAME.zip")
  echo "==> 打包: $DIST/$APP_NAME.zip"
fi

echo "==> 完成: $APP"
lipo -info "$APP/Contents/MacOS/$APP_NAME" || true
