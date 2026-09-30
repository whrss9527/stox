#!/usr/bin/env bash
# 构建 Stox.app：swift build (release) → 组装 .app → 生成图标 → 签名。
#
#   scripts/build-app.sh                 本机架构
#   UNIVERSAL=1 scripts/build-app.sh     Apple 芯片 + Intel 通用版（需要完整 Xcode）
#   CODESIGN_IDENTITY="Developer ID Application: ..." scripts/build-app.sh   用自己的证书签名
#   ZIP=1 scripts/build-app.sh           另外打成 dist/Stox.zip（发布用）
#
# 产物: dist/Stox.app
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Stox"
DIST="dist"
APP="$DIST/$APP_NAME.app"

VERSION="${VERSION:-}"
if [[ -z "$VERSION" ]]; then
  VERSION="$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)"
fi
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"

# 用普通字符串而不是数组：macOS 自带的 bash 3.2 在 set -u 下展开空数组会报错。
ARCH_FLAGS=""
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  ARCH_FLAGS="--arch arm64 --arch x86_64"
fi

echo "==> 编译 $APP_NAME $VERSION ($BUILD_NUMBER) ${ARCH_FLAGS}"
# shellcheck disable=SC2086
swift build -c release --product "$APP_NAME" $ARCH_FLAGS
# shellcheck disable=SC2086
BIN_DIR="$(swift build -c release --product "$APP_NAME" $ARCH_FLAGS --show-bin-path)"

echo "==> 组装 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$APP/Contents/Info.plist"

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
codesign "${SIGN_ARGS[@]}" "$APP"
codesign --verify --strict --verbose=2 "$APP"

if [[ "${ZIP:-0}" == "1" ]]; then
  (cd "$DIST" && rm -f "$APP_NAME.zip" && ditto -c -k --keepParent "$APP_NAME.app" "$APP_NAME.zip")
  echo "==> 打包: $DIST/$APP_NAME.zip"
fi

echo "==> 完成: $APP"
lipo -info "$APP/Contents/MacOS/$APP_NAME" || true
