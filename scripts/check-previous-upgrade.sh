#!/usr/bin/env bash
# 仅在隔离 Actions 账户中验证原签名公开包升级到本轮签名候选，不改签名或版本。
set -euo pipefail
[[ "${GITHUB_ACTIONS:-}" == true ]] || { echo '需要隔离的 Actions 账户' >&2; exit 1; }
[[ "${RUNNER_ENVIRONMENT:-}" == github-hosted ]] || { echo '仅在临时托管 runner 中运行' >&2; exit 1; }
if pgrep -x Stox >/dev/null; then echo '已有非本测试的Stox进程，停止' >&2; exit 1; fi
OLD_ZIP="${1:?旧正式版ZIP}"
NEW_ZIP="${2:?签名候选ZIP}"
OUT="${3:?证据目录}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
WORK="$(mktemp -d -t stox-previous-upgrade)"
DOMAIN=io.github.whrss9527.stox
INSTALL="$WORK/install/Stox.app"
LOG="$HOME/Library/Application Support/Stox/stox.log"
server_pid=''
cleanup() {
  local status=$?
  cp "$LOG" "$OUT/stox.log" 2>/dev/null || true
  defaults export "$DOMAIN" "$OUT/preferences.plist" 2>/dev/null || true
  pkill -f "$WORK/" 2>/dev/null || true
  if [[ -n "$server_pid" ]]; then kill "$server_pid" 2>/dev/null || true; fi
  defaults delete "$DOMAIN" 2>/dev/null || true
  rm -rf "$WORK"
  exit "$status"
}
trap cleanup EXIT
mkdir -p "$WORK/install" "$WORK/new" "$WORK/feed"
ditto -x -k "$OLD_ZIP" "$WORK/install"
ditto -x -k "$NEW_ZIP" "$WORK/new"
codesign --verify --deep --strict "$INSTALL"
codesign --verify --deep --strict "$WORK/new/Stox.app"
codesign -dv --verbose=2 "$INSTALL" 2> "$OUT/old-signature.txt"
codesign -dv --verbose=2 "$WORK/new/Stox.app" 2> "$OUT/new-signature.txt"
cmp <(grep '^TeamIdentifier=' "$OUT/old-signature.txt") <(grep '^TeamIdentifier=' "$OUT/new-signature.txt")
grep -Eq '^TeamIdentifier=[A-Z0-9]{10}$' "$OUT/old-signature.txt"
old_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INSTALL/Contents/Info.plist")
new_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$WORK/new/Stox.app/Contents/Info.plist")
[[ "$old_version" != "$new_version" ]]
cp "$NEW_ZIP" "$WORK/feed/Stox.zip"
python3 - "$WORK/feed" "$new_version" <<'PYFEED' > "$OUT/server.log" 2>&1 &
import functools, hashlib, http.server, json, pathlib, socketserver, sys
root, version = pathlib.Path(sys.argv[1]), sys.argv[2]
class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True
with Server(('127.0.0.1', 0), functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(root))) as server:
    base = 'http://127.0.0.1:' + str(server.server_address[1])
    archive = root / 'Stox.zip'
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    release = {'tag_name': 'v' + version, 'html_url': 'https://github.com/whrss9527/stox/releases', 'assets': [
        {'name': 'Stox.zip', 'size': archive.stat().st_size, 'digest': 'sha256:' + digest, 'browser_download_url': base + '/Stox.zip'}]}
    (root / 'latest.json').write_text(json.dumps(release))
    (root / 'endpoint').write_text(base + '/latest.json')
    server.serve_forever()
PYFEED
server_pid=$!
for _ in $(seq 1 30); do [[ ! -f "$WORK/feed/endpoint" ]] || break; sleep 0.2; done
[[ -f "$WORK/feed/endpoint" ]]
defaults write "$DOMAIN" AppleLanguages -array zh-Hans
defaults write "$DOMAIN" update.autoCheck -bool false
defaults write "$DOMAIN" tips.dismissed -bool true
defaults write "$DOMAIN" appearance -string dark
defaults write "$DOMAIN" ticker.layout -string stacked
defaults write "$DOMAIN" watchlist.v1 -data "$(printf '%s' '[{"symbol":"sh600519","name":"贵州茅台","note":"migration-survives","holding":{"shares":100,"cost":1200}}]' | xxd -p | tr -d '\n')"
mkdir -p "$(dirname "$LOG")"
: > "$LOG"
STOX_UPDATE_URL="$(cat "$WORK/feed/endpoint")" STOX_SYNC_DIR="$WORK/cloud" "$INSTALL/Contents/MacOS/Stox" --install-update > "$OUT/stdout.log" 2>&1 &
for _ in $(seq 1 180); do
  actual=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INSTALL/Contents/Info.plist" 2>/dev/null || true)
  if [[ "$actual" == "$new_version" ]] && grep -q "Stox 已启动，版本 $new_version" "$LOG"; then break; fi
  sleep 0.5
done
[[ "$actual" == "$new_version" ]]
grep -q "Stox 已启动，版本 $new_version" "$LOG"
pgrep -f "$INSTALL/Contents/MacOS/Stox" > "$OUT/running-pids.txt"
codesign --verify --deep --strict "$INSTALL"
[[ "$(defaults read "$DOMAIN" appearance)" == dark ]]
[[ "$(defaults read "$DOMAIN" ticker.layout)" == stacked ]]
defaults export "$DOMAIN" "$OUT/preferences.plist"
python3 - "$OUT/preferences.plist" "$OUT/result.json" "$old_version" "$new_version" <<'PYRESULT'
import json, plistlib, sys
with open(sys.argv[1], 'rb') as file:
    prefs = plistlib.load(file)
items = json.loads(prefs['watchlist.v1'])
assert any(i.get('note') == 'migration-survives' and i.get('holding', {}).get('shares') == 100 and i['holding'].get('cost') == 1200 for i in items)
with open(sys.argv[2], 'w') as file:
    json.dump({'old_version': sys.argv[3], 'new_version': sys.argv[4], 'signature_and_restart': True, 'preferences_preserved': True}, file, indent=2)
PYRESULT
echo "已验收：原签名 ${old_version} → ${new_version}，进程重启、签名与自选/持仓/偏好保留"
