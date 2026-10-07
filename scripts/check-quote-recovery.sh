#!/usr/bin/env bash
# 只在 CI 上运行打包好的 App，不改真实网络；本地服务模拟主备行情失败后恢复。
set -euo pipefail
cd "$(dirname "$0")/.."
APP="${1:-$PWD/dist/Stox.app}"
DOMAIN="io.github.whrss9527.stox"
WORK=$(mktemp -d "${RUNNER_TEMP:-/tmp}/stox-quote-recovery.XXXXXX")
app_pid=""
server_pid=""
old_interval=$(defaults read "$DOMAIN" refreshInterval 2>/dev/null || true)
old_watchlist=$(defaults read "$DOMAIN" watchlist.v1 2>/dev/null | tr -d '<>[:space:]' || true)
old_idle=$(defaults read "$DOMAIN" slowWhenIdle 2>/dev/null || true)
cleanup() {
  [ -z "$app_pid" ] || { kill "$app_pid" 2>/dev/null || true; wait "$app_pid" 2>/dev/null || true; }
  [ -z "$server_pid" ] || { kill "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true; }
  if [ -n "$old_interval" ]; then defaults write "$DOMAIN" refreshInterval -float "$old_interval"; else defaults delete "$DOMAIN" refreshInterval 2>/dev/null || true; fi
  if [ -n "$old_idle" ]; then defaults write "$DOMAIN" slowWhenIdle -bool "$old_idle"; else defaults delete "$DOMAIN" slowWhenIdle 2>/dev/null || true; fi
  if [ -n "$old_watchlist" ]; then defaults write "$DOMAIN" watchlist.v1 -data "$old_watchlist"; else defaults delete "$DOMAIN" watchlist.v1 2>/dev/null || true; fi
  mkdir -p shots
  cp "$WORK"/*.log "$WORK"/*.jsonl shots/ 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT
python3 scripts/quote-recovery-fixture.py "$WORK" > "$WORK/quote-recovery-server.log" 2>&1 &
server_pid=$!
for _ in $(seq 1 10); do [ ! -f "$WORK/port" ] || break; sleep 1; done
[ -f "$WORK/port" ] || { cat "$WORK/quote-recovery-server.log"; echo '行情恢复测试服务没有启动'; exit 1; }
port=$(cat "$WORK/port")
defaults write "$DOMAIN" watchlist.v1 -data "$(printf '%s' '[{"symbol":"sh600519","name":"Recovery fixture"}]' | xxd -p | tr -d '\n')"
defaults write "$DOMAIN" refreshInterval -float 3
defaults write "$DOMAIN" slowWhenIdle -bool false
STOX_QUOTE_ENDPOINT="http://127.0.0.1:$port/primary?q=" \
STOX_SINA_QUOTE_ENDPOINT="http://127.0.0.1:$port/backup?list=" \
  "$APP/Contents/MacOS/Stox" --show-panel > "$WORK/quote-recovery.log" 2>&1 &
app_pid=$!
for _ in $(seq 1 30); do
  if [ -f "$WORK/requests.jsonl" ] && [ "$(wc -l < "$WORK/requests.jsonl")" -ge 6 ]; then break; fi
  kill -0 "$app_pid" || { echo '行情恢复测试中 App 退出'; exit 1; }
  sleep 1
done
# 打开面板会立即刷新一次；第三轮才测自动轮询，不把这次用户触发的刷新当作定时重试。
python3 - "$WORK/requests.jsonl" <<'PY'
import json, sys
r = [json.loads(line) for line in open(sys.argv[1])]
assert len(r) >= 6 and all(x['status'] == 503 for x in r[:6]), r
assert '/primary' in r[0]['path'] and '/backup' in r[1]['path'], r
assert r[4]['time'] - r[2]['time'] >= 11.5, r
PY
grep -Eq "quote_retry_active=true interval=(6|12|24)" "$WORK/quote-recovery.log" || { cat "$WORK/quote-recovery.log"; echo "面板没有进入退避重试状态"; exit 1; }
touch "$WORK/recover"
for _ in $(seq 1 35); do
  if grep -q '"status": 200' "$WORK/requests.jsonl"; then break; fi
  kill -0 "$app_pid" || { echo '等待行情恢复时 App 退出'; exit 1; }
  sleep 1
done
# 成功以后恢复正常间隔；至少再收到一次成功请求。
for _ in $(seq 1 10); do
  [ "$(grep -c '"status": 200' "$WORK/requests.jsonl" || true)" -lt 2 ] || break
  sleep 1
done
python3 - "$WORK/requests.jsonl" <<'PY'
import json, sys
r = [json.loads(line) for line in open(sys.argv[1])]
ok = [x for x in r if x['status'] == 200]
assert len(ok) >= 2, r
assert 2.5 <= ok[1]['time'] - ok[0]['time'] < 6, r
print('主备均失败后退避，主源恢复后回到正常刷新间隔。')
PY
