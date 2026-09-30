#!/usr/bin/env bash
# 构建 Mac App Store 版：编译 App Store 版（-D APP_STORE）→ 放进描述文件 → 用 Apple Distribution 证书带沙盒签名
# → productbuild 打成上传用的 dist/Stox-AppStore.pkg（用 Mac Installer Distribution 证书签名）。
#
#   正式构建（需要证书和描述文件，见 docs/app-store.md）：
#     APPSTORE_PROFILE=Stox_Mac_App_Store.provisionprofile \
#     APP_SIGN_IDENTITY="Apple Distribution: 名字 (TEAMID)" \
#     INSTALLER_SIGN_IDENTITY="3rd Party Mac Developer Installer: 名字 (TEAMID)" \
#     scripts/build-app-store.sh
#
#   CI 里没有证书时（ADHOC=1）：ad-hoc 签名，只带沙盒、联网和用户选择的文件这三项 entitlement
#   （iCloud 那几项要有描述文件才能启动），打一个不签名的 pkg，检查打包流程走得通。这样的 pkg 不能上传。
#
# 其他变量：
#   UNIVERSAL=0         只编译本机架构（默认 1：Apple 芯片 + Intel 通用版，上传要求）
#   CODESIGN_KEYCHAIN   证书所在的钥匙串（CI 里导入到临时钥匙串）
#   VERSION / BUILD_NUMBER  版本号和构建号，和 scripts/build-app.sh 一样；每次上传的构建号都要比上次大
#
# 产物: dist/appstore/Stox.app，dist/Stox-AppStore.pkg
set -euo pipefail
cd "$(dirname "$0")/.."

APP="dist/appstore/Stox.app"
PKG="dist/Stox-AppStore.pkg"
BUNDLE_ID="io.github.whrss9527.stox"
CONTAINER="iCloud.io.github.whrss9527.stox"
TEMPLATE="Resources/Stox-AppStore.entitlements"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ENTITLEMENTS="$WORK/Stox.entitlements"

fail() {
  echo "error: $*" >&2
  exit 1
}

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null || true
}

if [[ "${ADHOC:-0}" == "1" ]]; then
  echo "==> ad-hoc 构建：去掉需要描述文件的 entitlement"
  cp "$TEMPLATE" "$ENTITLEMENTS"
  for key in com.apple.application-identifier com.apple.developer.team-identifier \
    com.apple.developer.icloud-container-identifiers com.apple.developer.ubiquity-container-identifiers \
    com.apple.developer.icloud-services com.apple.developer.icloud-container-environment; do
    plutil -remove "$key" "$ENTITLEMENTS"
  done
  IDENTITY="-"
  PROFILE=""
  INSTALLER=""
else
  PROFILE="${APPSTORE_PROFILE:-}"
  IDENTITY="${APP_SIGN_IDENTITY:-}"
  INSTALLER="${INSTALLER_SIGN_IDENTITY:-}"
  [[ -n "$PROFILE" && -f "$PROFILE" ]] || fail "APPSTORE_PROFILE 要指向 Mac App Store 的描述文件（.provisionprofile）"
  [[ -n "$IDENTITY" ]] || fail "APP_SIGN_IDENTITY 没有设置（钥匙串里 Apple Distribution 证书的名字）"
  [[ -n "$INSTALLER" ]] || fail "INSTALLER_SIGN_IDENTITY 没有设置（钥匙串里 Mac Installer Distribution 证书的名字）"

  echo "==> 检查描述文件"
  security cms -D -i "$PROFILE" > "$WORK/profile.plist" || fail "读不了描述文件 $PROFILE"
  TEAM_ID="$(plist_value "$WORK/profile.plist" TeamIdentifier:0)"
  APP_ID="$(plist_value "$WORK/profile.plist" Entitlements:com.apple.application-identifier)"
  echo "    名称: $(plist_value "$WORK/profile.plist" Name)"
  echo "    团队: $TEAM_ID，App ID: $APP_ID，到期: $(plist_value "$WORK/profile.plist" ExpirationDate)"
  [[ -n "$TEAM_ID" ]] || fail "描述文件里没有团队 ID"
  [[ "$APP_ID" == "$TEAM_ID.$BUNDLE_ID" ]] || fail "描述文件的 App ID 是 $APP_ID，应该是 $TEAM_ID.$BUNDLE_ID"
  # 开发用的描述文件列着测试设备；App Store 的没有。
  if /usr/libexec/PlistBuddy -c "Print :ProvisionedDevices" "$WORK/profile.plist" > /dev/null 2>&1; then
    fail "这是开发用的描述文件（列着测试设备），上传要用“Mac App Store Connect”类型的描述文件"
  fi
  plist_value "$WORK/profile.plist" Entitlements:com.apple.developer.icloud-container-identifiers | grep -q "$CONTAINER" \
    || fail "描述文件里没有 iCloud 容器 $CONTAINER：在开发者网站给 App ID 打开 iCloud 并添加这个容器，再重新生成描述文件"

  sed "s/__TEAM_ID__/$TEAM_ID/g" "$TEMPLATE" > "$ENTITLEMENTS"
fi
plutil -lint "$ENTITLEMENTS"

echo "==> 构建 App Store 版"
STOX_FLAVOR=appstore UNIVERSAL="${UNIVERSAL:-1}" CODESIGN_IDENTITY="$IDENTITY" CODESIGN_ENTITLEMENTS="$ENTITLEMENTS" \
  PROVISIONING_PROFILE="$PROFILE" scripts/build-app.sh

echo "==> 检查签名"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -d --entitlements - --xml "$APP" 2>/dev/null > "$WORK/signed.plist" || codesign -d --entitlements :- "$APP" > "$WORK/signed.plist"
plutil -p "$WORK/signed.plist"
[[ "$(plist_value "$WORK/signed.plist" com.apple.security.app-sandbox)" == "true" ]] || fail "签名里没有沙盒"
[[ "$(plist_value "$WORK/signed.plist" com.apple.security.network.client)" == "true" ]] || fail "签名里没有联网权限"
if [[ "${ADHOC:-0}" != "1" ]]; then
  [[ -f "$APP/Contents/embedded.provisionprofile" ]] || fail "App 里没有描述文件"
fi
[[ "$(plist_value "$APP/Contents/Info.plist" ITSAppUsesNonExemptEncryption)" == "false" ]] || fail "Info.plist 里没有 ITSAppUsesNonExemptEncryption = NO"

echo "==> 打包 $PKG"
rm -f "$PKG"
PKG_ARGS=(--component "$APP" /Applications)
if [[ -n "$INSTALLER" ]]; then
  PKG_ARGS+=(--sign "$INSTALLER")
  if [[ -n "${CODESIGN_KEYCHAIN:-}" ]]; then
    PKG_ARGS+=(--keychain "$CODESIGN_KEYCHAIN")
  fi
fi
productbuild "${PKG_ARGS[@]}" "$PKG"
if [[ -n "$INSTALLER" ]]; then
  pkgutil --check-signature "$PKG"
fi
ls -la "$PKG"
echo "==> 完成: $PKG（$(plist_value "$APP/Contents/Info.plist" CFBundleShortVersionString) 构建 $(plist_value "$APP/Contents/Info.plist" CFBundleVersion)）"
