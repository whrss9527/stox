#!/usr/bin/env bash
# CI 端到端测试：真正启动打包好的 dist/Stox.app，检查面板、设置窗口、iCloud 同步和一键更新，顺便截图。
#
#   scripts/ci-e2e.sh smoke    面板、详情、搜索、设置窗口、右键隐藏行情
#   scripts/ci-e2e.sh sync     假的 iCloud 云盘文件夹：启动时拉取、运行中收到改动、文件被删后写回
#   scripts/ci-e2e.sh update   本地假发布 9.9.9：发现新版本、原地更新、从临时位置运行时装进“应用程序”
#
# 截图（*-full.png）、App 输出（*.log，含 STOX_DIAG 诊断行）都放在 shots/ 下，后面的步骤负责裁剪。
set -euo pipefail
cd "$(dirname "$0")/.."

APP="$PWD/dist/Stox.app"
DOMAIN="io.github.whrss9527.stox"
SUPPORT="$HOME/Library/Application Support/Stox"
LOG="$SUPPORT/stox.log"
WORK="${RUNNER_TEMP:-/tmp}/stox-e2e"
mkdir -p shots "$SUPPORT" "$WORK"

fail() {
  echo "::error::$*"
  echo "===== stox.log ====="
  cat "$LOG" 2>/dev/null || true
  exit 1
}

# 反复检查，最多等 $1 秒。
wait_for() {
  local seconds="$1"
  shift
  for _ in $(seq 1 "$seconds"); do
    if "$@"; then
      return 0
    fi
    sleep 1
  done
  return 1
}

log_has() {
  grep -qF -- "$1" "$LOG" 2>/dev/null
}

# 启动一次（直接运行 .app 里的二进制，环境变量才能传进去），14 秒后记下内存、截屏、退出。
# 用法: [变量=值 ...] run_case 名字 [参数...]
run_case() {
  local name="$1"
  shift
  "$APP/Contents/MacOS/Stox" "$@" > "shots/$name.log" 2>&1 &
  local pid=$!
  sleep 14
  if ! kill -0 "$pid" 2>/dev/null; then
    cat "shots/$name.log"
    ls -t ~/Library/Logs/DiagnosticReports 2>/dev/null | head -5
    fail "Stox exited during launch ($name)"
  fi
  {
    echo "STOX_DIAG rss_kb=$(ps -o rss= -p "$pid" | tr -d ' ')"
    echo "STOX_DIAG $(vmmap -summary "$pid" 2>/dev/null | grep -m1 'Physical footprint:' | tr -s ' ')"
  } > "shots/$name-memory.log"
  grep -h STOX_DIAG "shots/$name.log" "shots/$name-memory.log" || true
  screencapture -x "shots/$name-full.png" || echo "screencapture failed"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

smoke() {
  # CI 里不去 GitHub 检查更新，也就不会弹出通知挡住截图。
  defaults write "$DOMAIN" update.autoCheck -bool false
  run_case panel --show-panel
  run_case detail --show-panel --expand sh600519
  run_case search --show-panel --search 腾讯
  run_case settings-general --show-settings general
  run_case settings-display --show-settings display
  grep -q "panel_frame=" shots/panel.log || fail "面板没有打开"
  grep -q 'image=false color=redUp' shots/panel.log || fail "默认应该在菜单栏显示行情、红涨绿跌"
  grep -q "settings_page=display" shots/settings-display.log || fail "设置窗口没有打开"

  # 右键单击切换的“只显示图标”：菜单栏只剩图标，左键照样能打开面板。
  defaults write "$DOMAIN" ticker.hidden -bool true
  run_case hidden --show-panel
  defaults delete "$DOMAIN" ticker.hidden
  grep -q 'status_title="" image=true' shots/hidden.log || fail "隐藏行情后菜单栏应该只有图标"
  grep -q "panel_frame=" shots/hidden.log || fail "只显示图标时面板没有打开"
}

sync_test() {
  local cloud="$WORK/fake-icloud"
  rm -rf "$cloud"
  mkdir -p "$cloud"
  # 假装另一台 Mac 已经同步上来：3 只自选，涨跌颜色是“不显示红绿”。本机记录着同步已开启。
  cat > "$cloud/sync.json" <<'JSON'
{"format":1,"updatedAt":"2026-09-01T08:00:00Z","device":"另一台 Mac",
 "content":{"watchlist":[{"symbol":"sh600519","name":"贵州茅台","alias":"茅台","pinned":true},
                         {"symbol":"hk00700","name":"腾讯控股","pinned":true},
                         {"symbol":"usAAPL","name":"苹果"}],
            "settings":{"colorScheme":"neutral","refreshInterval":5}}}
JSON
  defaults write "$DOMAIN" update.autoCheck -bool false
  defaults write "$DOMAIN" sync.enabled -bool true
  : > "$LOG"
  STOX_SYNC_DIR="$cloud" "$APP/Contents/MacOS/Stox" --show-panel > shots/sync-panel.log 2>&1 &
  local pid=$!
  wait_for 20 log_has "应用了来自 另一台 Mac 的改动（3 只）" || fail "没有从假 iCloud 拉到自选"
  # 面板在启动 4 秒后打开，等行情回来再截图。
  sleep 10
  screencapture -x shots/sync-panel-full.png || echo "screencapture failed"
  grep -h STOX_DIAG shots/sync-panel.log || true
  grep -q "items=3" shots/sync-panel.log || fail "自选没有换成 iCloud 里的 3 只"
  grep -q "color=neutral" shots/sync-panel.log || fail "涨跌颜色没有同步成“不显示红绿”"
  [ "$(defaults read "$DOMAIN" colorConvention)" = "neutral" ] || fail "同步来的颜色设置没有保存"

  # 运行中另一台 Mac 又改了：iCloud 下载新版本时是整个文件替换。
  cat > "$cloud/.sync.json.tmp" <<'JSON'
{"format":1,"updatedAt":"2026-09-02T08:00:00Z","device":"第三台 Mac",
 "content":{"watchlist":[{"symbol":"sz000001","name":"平安银行","pinned":true},{"symbol":"usTSLA","name":"特斯拉"}],
            "settings":{"colorScheme":"greenUp"}}}
JSON
  mv "$cloud/.sync.json.tmp" "$cloud/sync.json"
  wait_for 45 log_has "应用了来自 第三台 Mac 的改动（2 只）" || fail "运行中没有收到 iCloud 里的改动"
  [ "$(defaults read "$DOMAIN" colorConvention)" = "greenUp" ] || fail "运行中收到的颜色设置没有生效"

  # iCloud 里的文件被删掉了：把本机的写回去。
  rm "$cloud/sync.json"
  wait_for 45 test -s "$cloud/sync.json" || fail "同步文件被删后没有重新写入"
  sleep 1
  cat "$cloud/sync.json"
  grep -q '"sz000001"' "$cloud/sync.json" || fail "重新写入的不是本机的自选"
  if grep -q '第三台 Mac' "$cloud/sync.json"; then
    fail "重新写入的文件应该标着这台 Mac"
  fi
  log_has "已写入本机的自选和设置（2 只）" || fail "日志里没有写入 iCloud 的记录"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true

  STOX_SYNC_DIR="$cloud" run_case settings-sync --show-settings sync
  grep -q "settings_page=sync" shots/settings-sync.log || fail "同步设置页没有打开"
  echo "===== stox.log ====="
  cat "$LOG"
  defaults delete "$DOMAIN" 2>/dev/null || true
}

version_of() {
  /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$1/Contents/Info.plist" 2>/dev/null || true
}

# 程序已经换成 9.9.9，并且新版本已经启动。
updated_to_999() {
  [ "$(version_of "$1")" = "9.9.9" ] && log_has "Stox 已启动，版本 9.9.9"
}

update_test() {
  # 用打包好的程序造一个 9.9.9 版本，放到本地 HTTP 服务器上当作 GitHub 的最新发布。
  local feed="$WORK/feed"
  rm -rf "$feed"
  mkdir -p "$feed"
  ditto "$APP" "$feed/Stox.app"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 9.9.9" "$feed/Stox.app/Contents/Info.plist"
  codesign --force --sign - "$feed/Stox.app"
  (cd "$feed" && ditto -c -k --keepParent Stox.app Stox.zip && rm -rf Stox.app && shasum -a 256 Stox.zip > SHA256SUMS.txt)
  cat "$feed/SHA256SUMS.txt"
  local size
  size=$(stat -f %z "$feed/Stox.zip")
  cat > "$feed/latest.json" <<JSON
{"tag_name":"v9.9.9","html_url":"https://github.com/whrss9527/stox/releases","published_at":"2026-09-01T00:00:00Z",
 "body":"## 9.9.9\n\n- 这是 CI 里用来测试一键更新的假版本。\n- 下载、校验、替换、重新启动都会走一遍。",
 "assets":[{"name":"Stox.zip","size":$size,"browser_download_url":"http://127.0.0.1:8765/Stox.zip"},
           {"name":"SHA256SUMS.txt","size":80,"browser_download_url":"http://127.0.0.1:8765/SHA256SUMS.txt"}]}
JSON
  (cd "$feed" && python3 -m http.server 8765 --bind 127.0.0.1 > "$WORK/http.log" 2>&1 &)
  wait_for 15 curl -sf -o /dev/null http://127.0.0.1:8765/latest.json || fail "本地假发布没有启动"
  export STOX_UPDATE_URL=http://127.0.0.1:8765/latest.json
  defaults write "$DOMAIN" update.autoCheck -bool false

  # 发现新版本：面板底部的更新条和“关于与更新”页。
  : > "$LOG"
  run_case update-banner --check-update --show-panel
  log_has "有新版本 9.9.9" || fail "没有发现假的新版本"
  run_case settings-about --check-update --show-settings about

  # 原地更新：程序放在一个可写的文件夹里。
  local install="$WORK/install"
  rm -rf "$install"
  mkdir -p "$install"
  ditto "$APP" "$install/Stox.app"
  : > "$LOG"
  "$install/Stox.app/Contents/MacOS/Stox" --install-update > shots/update-install.log 2>&1 &
  wait_for 90 updated_to_999 "$install/Stox.app" || fail "程序没有被替换成 9.9.9 并重新启动（现在是 $(version_of "$install/Stox.app")）"
  sleep 2
  echo "===== stox.log（原地更新） ====="
  cat "$LOG"
  log_has "更新包校验通过" || fail "没有校验更新包"
  pgrep -f "$install/Stox.app/Contents/MacOS/Stox" > /dev/null || fail "更新后程序没有在运行"
  codesign --verify --deep --strict "$install/Stox.app"
  if xattr "$install/Stox.app" | grep -q com.apple.quarantine; then
    fail "新程序还带着隔离标记"
  fi
  pkill -f "$install/Stox.app/Contents/MacOS/Stox" || true
  sleep 2

  # 从下载文件夹这类临时位置运行（被系统搬到只读位置）：装进“应用程序”，旧的移到废纸篓，从新位置重新打开。
  local relocate="$WORK/relocate"
  rm -rf "$relocate" /Applications/Stox.app
  mkdir -p "$relocate"
  ditto "$APP" "$relocate/Stox.app"
  : > "$LOG"
  STOX_TEST_TRANSLOCATED=1 "$relocate/Stox.app/Contents/MacOS/Stox" --install-update > shots/update-relocate.log 2>&1 &
  wait_for 90 updated_to_999 /Applications/Stox.app || fail "没有装进“应用程序”（现在是 $(version_of /Applications/Stox.app)）"
  sleep 2
  echo "===== stox.log（从临时位置运行） ====="
  cat "$LOG"
  [ ! -e "$relocate/Stox.app" ] || fail "旧的那份没有移到废纸篓"
  log_has "移到废纸篓" || fail "日志里没有移到废纸篓的记录"
  pgrep -f "/Applications/Stox.app/Contents/MacOS/Stox" > /dev/null || fail "没有从“应用程序”重新打开"
  codesign --verify --deep --strict /Applications/Stox.app
  pkill -f "/Applications/Stox.app/Contents/MacOS/Stox" || true
  sleep 1
  rm -rf /Applications/Stox.app
  defaults delete "$DOMAIN" 2>/dev/null || true
}

case "${1:-}" in
  smoke) smoke ;;
  sync) sync_test ;;
  update) update_test ;;
  *)
    echo "用法: $0 smoke|sync|update" >&2
    exit 2
    ;;
esac
