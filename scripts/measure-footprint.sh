#!/usr/bin/env bash
# 仅在独立 macOS CI 测两行菜单栏和面板迷你走势线；退出时恢复 runner 的 Stox 偏好。
set -euo pipefail
if [[ $(uname -s) != Darwin || ${GITHUB_ACTIONS:-} != true ]]; then
  echo '这项测量会启动 App 并临时修改偏好，只允许在隔离的 macOS CI 运行。' >&2
  exit 1
fi
: "${RUNNER_TEMP:?需要独立测试临时目录}"
app=${1:-"$PWD/dist/Stox.app"}
settle=${SETTLE:-30}
window=${WINDOW:-60}
domain=io.github.whrss9527.stox
if pgrep -x Stox >/dev/null; then
  echo '::error::测量前已有 Stox 进程，不能使用这个环境。' >&2
  exit 1
fi
work=$(mktemp -d "$RUNNER_TEMP/stox-footprint.XXXXXX")
mkdir -p shots "$work/sync"
had_preferences=false
if defaults export "$domain" "$work/preferences.plist" >/dev/null 2>&1; then had_preferences=true; fi
app_pid=''
cleanup() {
  if [[ -n "$app_pid" ]]; then
    kill "$app_pid" 2>/dev/null || true
    wait "$app_pid" 2>/dev/null || true
  fi
  defaults delete "$domain" >/dev/null 2>&1 || true
  if [[ "$had_preferences" == true ]]; then defaults import "$domain" "$work/preferences.plist"; fi
}
trap cleanup EXIT
defaults write "$domain" watchlist.v1 -data "$(printf '%s' '[{"symbol":"sh000001","name":"上证指数","pinned":true},{"symbol":"sh600519","name":"贵州茅台","pinned":true},{"symbol":"hk00700","name":"腾讯控股"}]' | xxd -p | tr -d '\n')"
defaults write "$domain" ticker.layout -string stacked
defaults write "$domain" list.sparklines -bool true
defaults write "$domain" list.flash -bool false
defaults write "$domain" ticker.rotate -bool false
defaults write "$domain" ticker.hidden -bool false
defaults write "$domain" ticker.hideWhenClosed -bool false
defaults write "$domain" ticker.dayProfit -bool false
defaults write "$domain" panel.pinned -bool true
defaults write "$domain" refreshInterval -float 5
defaults write "$domain" slowWhenIdle -bool false
defaults write "$domain" update.autoCheck -bool false
defaults write "$domain" sync.enabled -bool false
defaults write "$domain" alertsEnabled -bool false
defaults write "$domain" tips.dismissed -bool true
log=shots/footprint-app.log
STOX_SYNC_DIR="$work/sync" STOX_TEST_NOTIFICATIONS=denied "$app/Contents/MacOS/Stox" --show-panel > "$log" 2>&1 &
app_pid=$!
# 必须真实显示两行菜单栏、拿到行情和迷你走势线，不能拿空面板的数值当作该场景的基线。
ready() {
  grep -Eq 'ticker_layout=stacked status_image=[1-9][0-9]*x[1-9][0-9]*' "$log" &&
    grep -q 'pinned=true' "$log" &&
    grep -q 'items=3 quotes=3 ' "$log" &&
    grep -Eq 'late flow=[^ ]+ sparklines=[1-9]' "$log"
}
deadline=$((SECONDS + 40))
until ready; do
  if ! kill -0 "$app_pid" 2>/dev/null || ((SECONDS >= deadline)); then
    echo '::error::没有取得有效的两行菜单栏 / 迷你走势线测量场景。'
    cat "$log"
    exit 1
  fi
  sleep 0.25
done
sleep "$settle"
cpu_seconds() { ps -o time= -p "$1" | awk -F: '{s=0; for(i=1;i<=NF;i++)s=s*60+$i; printf "%.3f",s}'; }
wakeups() { top -l 1 -c e -pid "$1" -stats pid,idlew 2>/dev/null | awk -v pid="$1" '$1==pid {gsub(/[^0-9]/,"",$2); print $2}' || true; }
now() { perl -MTime::HiRes=time -e 'printf "%.3f",time'; }
kill -0 "$app_pid"
wake_start=$(wakeups "$app_pid")
start=$(now); cpu_start=$(cpu_seconds "$app_pid")
sleep "$window"
cpu_end=$(cpu_seconds "$app_pid"); end=$(now)
wake_end=$(wakeups "$app_pid"); rss=$(ps -o rss= -p "$app_pid")
kill -0 "$app_pid"
cpu=$(awk -v a="$cpu_start" -v b="$cpu_end" -v s="$start" -v e="$end" 'BEGIN{printf "%.3f",100*(b-a)/(e-s)}')
wake='不可用'
if [[ -n "$wake_start" && -n "$wake_end" ]]; then
  wake=$(awk -v a="$wake_start" -v b="$wake_end" -v s="$start" -v e="$end" 'BEGIN{printf "%.2f",(b-a)/(e-s)}')
fi
rss=$(awk -v k="$rss" 'BEGIN{printf "%.1f",k/1024}')
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
{
  printf '### Stox 常驻绘制测量\n\n版本 %s，提交 %s。两行菜单栏、面板固定打开、迷你走势线开启；每 5 秒取行情，稳定 %s 秒后测量 %s 秒。\n\n' "$version" "${GITHUB_SHA:-unknown}" "$settle" "$window"
  printf '| CPU（单核） | 空闲唤醒 / 秒 | RSS |\n| --- | --- | --- |\n| %s %% | %s | %s MB |\n\n' "$cpu" "$wake" "$rss"
  printf '使用真实行情，网络与后台任务会影响数值；这不是单独的菜单栏绘制耗时。\n'
} | tee shots/footprint.md
python3 - "$version" "$cpu" "$wake" "$rss" "$settle" "$window" <<'PY'
import json, os, sys
from pathlib import Path
version, cpu, wake, rss, settle, window = sys.argv[1:]
Path('shots/footprint.json').write_text(json.dumps({
    'version': version, 'commit': os.environ.get('GITHUB_SHA'),
    'scenario': 'stacked ticker, pinned panel, sparklines, 5-second quote polling',
    'cpu_percent_one_core': float(cpu), 'idle_wakeups_per_second': None if wake == '不可用' else float(wake),
    'rss_mb': float(rss), 'settle_seconds': int(settle), 'sample_seconds': int(window),
}, indent=2) + '\n')
PY
if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then cat shots/footprint.md >> "$GITHUB_STEP_SUMMARY"; fi
