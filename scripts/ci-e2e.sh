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

# 直接写本机保存的自选列表（JSON），模拟用户在界面里改过。
write_watchlist() {
  defaults write "$DOMAIN" watchlist.v1 -data "$(printf '%s' "$1" | xxd -p | tr -d '\n')"
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
  # CI 里不去 GitHub 检查更新，也就不会弹出通知挡住截图；使用提示单独截一张，其他截图里不显示。
  defaults write "$DOMAIN" update.autoCheck -bool false
  defaults write "$DOMAIN" tips.dismissed -bool true
  run_case panel --show-panel
  run_case detail --show-panel --expand sh600519
  run_case search --show-panel --search 腾讯
  run_case settings-general --show-settings general
  run_case settings-display --show-settings display
  grep -q "panel_frame=" shots/panel.log || fail "面板没有打开"
  grep -q 'image=false color=redUp' shots/panel.log || fail "默认应该在菜单栏显示行情、红涨绿跌"
  # 分时图的数据来自另一个接口，偶尔取不到不算失败，只提醒一下。
  grep -q "intraday=[1-9]" shots/detail.log || echo "::warning::展开详情时没有取到分时数据"
  grep -q "settings_page=display" shots/settings-display.log || fail "设置窗口没有打开"

  # K 线：A 股日 K，美股月 K（美股个股要带交易所后缀才取得到完整的 K 线）。
  run_case kline --show-panel --expand sh600519 --chart day
  run_case kline-us --show-panel --expand usAAPL --chart month
  defaults delete "$DOMAIN" chart.period
  grep -q "chart=day" shots/kline.log || fail "没有切到日 K"
  grep -Eq "kline=([2-9][0-9])" shots/kline.log || echo "::warning::日 K 没有取到数据"
  grep -Eq "kline=([2-9][0-9])" shots/kline-us.log || echo "::warning::美股月 K 没有取到足够的数据"
  # 多取了 20 根历史，取到了的话图上 60 根都有 MA20。
  grep -Eq "ma20=60 " shots/kline.log || echo "::warning::日 K 上的均线没有从最左边开始"

  # 五日分时：美股要带交易所后缀才取得到。
  run_case fiveday --show-panel --expand usAAPL --chart fiveDay
  defaults delete "$DOMAIN" chart.period
  grep -q "chart=fiveDay" shots/fiveday.log || fail "没有切到五日"
  grep -Eq "fiveday=[1-9]" shots/fiveday.log || echo "::warning::五日分时没有取到数据"

  # 键盘：搜索结果里按 ↓ 选下一条；列表里 ↓ ↓ 回车展开第二只，再按 → 切到五日。
  run_case keys-search --show-panel --search 腾讯 --keys down
  run_case keys-list --show-panel --keys down,down,enter,right
  defaults delete "$DOMAIN" chart.period 2>/dev/null || true
  grep -Eq 'highlight=[a-z]' shots/keys-search.log || fail "方向键没有选中搜索结果"
  grep -q 'highlight=sz399001 expanded=sz399001' shots/keys-list.log || fail "方向键和回车没有展开第二只"
  grep -q 'chart=fiveDay' shots/keys-list.log || fail "右方向键没有切到五日"

  # 腾讯的行情接口不可用（指向一个连不上的地址）：自动改用新浪的行情，列表照常显示。
  STOX_QUOTE_ENDPOINT="http://127.0.0.1:9/q=" run_case failover --show-panel
  grep -q "source=backup" shots/failover.log || fail "腾讯行情不可用时没有改用新浪"
  grep -Eq "items=8 quotes=[1-9]" shots/failover.log || fail "改用新浪后没有行情"
  grep -q "items=8 quotes=8 " shots/failover.log || echo "::warning::新浪没有返回全部 8 只的行情"

  # 休市时只显示图标：菜单栏上的市场（默认是上证）休市时只剩图标，交易中照常显示行情。CI 什么时候跑都能判断。
  defaults write "$DOMAIN" ticker.hideWhenClosed -bool true
  run_case when-closed --show-panel
  defaults delete "$DOMAIN" ticker.hideWhenClosed
  grep -q "ticker_hidden=" shots/when-closed.log || fail "没有打印菜单栏的状态"
  if grep -q "ticker_live=false" shots/when-closed.log; then
    grep -q 'status_title="" image=true' shots/when-closed.log || fail "休市时菜单栏应该只剩图标"
  else
    grep -q 'status_title="上证' shots/when-closed.log || fail "交易中菜单栏应该照常显示行情"
  fi

  # 右键单击切换的“只显示图标”：菜单栏只剩图标，左键照样能打开面板。
  defaults write "$DOMAIN" ticker.hidden -bool true
  run_case hidden --show-panel
  defaults delete "$DOMAIN" ticker.hidden
  grep -q 'status_title="" image=true' shots/hidden.log || fail "隐藏行情后菜单栏应该只有图标"
  grep -q "panel_frame=" shots/hidden.log || fail "只显示图标时面板没有打开"

  # 第一次使用的提示，以及从旧版本更新上来后的“已更新到 x.y.z”。
  defaults delete "$DOMAIN" tips.dismissed
  defaults write "$DOMAIN" app.lastVersion -string 0.1.0
  run_case tips --show-panel
  defaults write "$DOMAIN" tips.dismissed -bool true
  defaults delete "$DOMAIN" update.whatsNew 2>/dev/null || true

  # 按涨幅排序，右边的色块显示总市值（指数没有市值）。
  defaults write "$DOMAIN" list.sort -string gainers
  defaults write "$DOMAIN" list.pill -string marketCap
  run_case sorted --show-panel
  defaults delete "$DOMAIN" list.sort
  defaults delete "$DOMAIN" list.pill
  grep -q "pill=marketCap" shots/sorted.log || fail "色块没有切到总市值"

  # 只看港股：列表上方选了“港股”，默认自选里有两只。
  defaults write "$DOMAIN" list.filter -string hk
  run_case filtered --show-panel
  defaults delete "$DOMAIN" list.filter
  grep -q "filter=hk visible=2" shots/filtered.log || fail "筛选港股后应该只剩两只"

  # 粘贴多个代码：列出认出的代码，等回车全部添加；认不出的单独列出来。
  run_case batch --show-panel --search "601318 09988 TSLA 茅台"
  grep -q "items=8 " shots/batch.log || fail "批量添加在确认前不应该改动自选"

  # 持仓：列表上方按币种合计，展开后显示持仓盈亏。
  write_watchlist '[{"symbol":"sh000001","name":"上证指数","alias":"上证","pinned":true},
    {"symbol":"sh600519","name":"贵州茅台","holding":{"shares":100,"cost":1200},"note":"等回调到 1200 附近再加仓","alert":{"profitAbove":1}},
    {"symbol":"sz000001","name":"平安银行","holding":{"shares":2000,"cost":12.5}},
    {"symbol":"hk00700","name":"腾讯控股","holding":{"shares":200,"cost":380}},
    {"symbol":"usAAPL","name":"苹果","holding":{"shares":10,"cost":300}}]'
  defaults write "$DOMAIN" ticker.dayProfit -bool true
  defaults write "$DOMAIN" alerts.closeSummary -bool true
  run_case holdings --show-panel --expand sh600519
  defaults delete "$DOMAIN" ticker.dayProfit
  defaults delete "$DOMAIN" alerts.closeSummary
  # 编辑页：持仓、记一笔买卖、止盈止损。
  run_case editor --show-panel --edit sh600519
  grep -q "panel_frame=" shots/editor.log || fail "编辑页没有打开"
  grep -Eq "items=5 quotes=[0-9]+ holdings=4" shots/holdings.log || fail "持仓没有读出来"
  # 茅台按 1200 的成本已经赚了 1% 以上，止盈提醒应该发出来。
  grep -Eq "alerts=[1-9]" shots/holdings.log || fail "持仓盈利达到阈值时没有提醒"
  # 打开了收盘小结：收盘不到 16 小时的市场各发一条。CI 运行的时间不固定，发没发取决于这时哪个市场刚收盘，只提示不判失败。
  grep -Eq "summaries=[1-9]" shots/holdings.log || echo "::warning::这次没有发收盘小结（可能没有刚收盘的市场）"
  grep -q 'status_title="上证 .* 今日 ' shots/holdings.log || fail "菜单栏没有显示今日盈亏"
  # 人民币、港币、美元都有持仓：取汇率折成人民币，列表上方多一行合计，菜单栏只显示一个数。
  if grep -q "rates=USDCNY:" shots/holdings.log; then
    grep -Eq 'status_title="[^"]* 今日 [+-]?¥[0-9.万亿]+"' shots/holdings.log || fail "有汇率时菜单栏的今日盈亏应该折成一个人民币数"
  else
    echo "::warning::没有取到汇率"
  fi

  # 钉住的面板放回上次拖到的位置（左上角 x=100，离屏幕底边 600）。
  defaults write "$DOMAIN" panel.pinned -bool true
  defaults write "$DOMAIN" panel.pinnedX -float 100
  defaults write "$DOMAIN" panel.pinnedY -float 600
  run_case pinned --show-panel
  defaults delete "$DOMAIN" panel.pinned
  defaults delete "$DOMAIN" panel.pinnedX
  defaults delete "$DOMAIN" panel.pinnedY
  grep -q "pinned=true" shots/pinned.log || fail "没有读到钉住的设置"
  grep -q "panel_frame=100 " shots/pinned.log || fail "钉住的面板没有放回上次的位置"

  # 外观选深色：面板和设置窗口用深色，菜单栏不受影响。
  defaults write "$DOMAIN" appearance -string dark
  run_case panel-dark --show-panel --expand sh600519
  run_case settings-dark --show-settings display
  defaults delete "$DOMAIN" appearance
  grep -q "panel_frame=" shots/panel-dark.log || fail "深色模式下面板没有打开"

  # 自选删空了：空列表里有“添加常用指数”。
  write_watchlist '[]'
  run_case empty --show-panel
  grep -q "items=0 " shots/empty.log || fail "自选应该是空的"
  defaults delete "$DOMAIN" watchlist.v1

  # 美股盘前盘后价：常规交易时段里不取也不显示；其他时候默认自选里的苹果应该取得到，取不到只提醒一下。
  late=$(grep -m1 "STOX_DIAG late us_phase=" shots/panel.log || true)
  [[ -n "$late" ]] || fail "没有打印美股的时段和盘前盘后价"
  if [[ "$late" == *"us_phase=trading "* ]]; then
    [[ "$late" == *" extended=0 "* ]] || fail "美股常规交易时段里不应该有盘前盘后价：$late"
  elif [[ "$late" == *" extended=0 "* ]]; then
    echo "::warning::美股不在常规交易时段，但没有取到盘前盘后价：$late"
  fi

  # 设置里关掉盘前盘后价以后不去取；K 线不画均线。
  defaults write "$DOMAIN" list.extendedHours -bool false
  defaults write "$DOMAIN" chart.movingAverages -bool false
  run_case plain --show-panel --expand usAAPL --chart day
  defaults delete "$DOMAIN" list.extendedHours
  defaults delete "$DOMAIN" chart.movingAverages
  defaults delete "$DOMAIN" chart.period
  grep -q "STOX_DIAG late us_phase=[a-zA-Z]* extended=0 " shots/plain.log || fail "关掉盘前盘后价以后不应该再取"
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

  # 本机改了但没来得及写上去就退出了（比如改完马上退出）：下次启动时应该把本机的写上去，
  # 而不是被 iCloud 里的旧内容覆盖。
  write_watchlist '[{"symbol":"sz000001","name":"平安银行","pinned":true},{"symbol":"usTSLA","name":"特斯拉"},{"symbol":"hk09988","name":"阿里巴巴"}]'
  : > "$LOG"
  STOX_SYNC_DIR="$cloud" "$APP/Contents/MacOS/Stox" > shots/sync-offline.log 2>&1 &
  pid=$!
  wait_for 20 log_has "已写入本机的自选和设置（3 只）" || fail "启动时没有把本机没写上去的改动写到 iCloud"
  grep -q '"hk09988"' "$cloud/sync.json" || fail "iCloud 里没有本机新加的自选"
  if log_has "应用了来自"; then
    fail "不应该用 iCloud 里的旧内容覆盖本机的改动"
  fi
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  log_has "Stox 已退出" || fail "收到 kill 后没有正常退出"
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
  # 不用 python3 -m http.server：它启动时会反查主机名，macOS 15 因此弹出“本地网络”授权框，挡住后面的截图。
  FEED="$feed" python3 - > "$WORK/http.log" 2>&1 <<'PY' &
import functools, http.server, os, socketserver

class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=os.environ["FEED"])
Server(("127.0.0.1", 8765), handler).serve_forever()
PY
  wait_for 15 curl -sf -o /dev/null http://127.0.0.1:8765/latest.json || fail "本地假发布没有启动"
  export STOX_UPDATE_URL=http://127.0.0.1:8765/latest.json
  defaults write "$DOMAIN" update.autoCheck -bool false
  defaults write "$DOMAIN" tips.dismissed -bool true

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
