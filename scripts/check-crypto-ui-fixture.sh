#!/usr/bin/env bash
# CI-only: real production views with fake, network-denied data. Never run on a personal desktop.
set -euo pipefail
if [[ "${GITHUB_ACTIONS:-}" != true || "${CI:-}" != true ]]; then
  echo "error: crypto fixture capture is restricted to GitHub Actions CI" >&2
  exit 2
fi
if [[ "$(uname -s)" != Darwin ]]; then
  echo "error: crypto fixture capture requires a macOS CI runner" >&2
  exit 2
fi
cd "$(dirname "$0")/.."
source scripts/ci-wait-ready.sh
output="$PWD/shots/crypto-fixture"
mkdir -p "$output"
work=$(mktemp -d "${RUNNER_TEMP:-/tmp}/stox-crypto-fixture.XXXXXX")
active_pid=''
stop_own_process() {
  if [[ -n "$active_pid" ]]; then
    kill "$active_pid" 2>/dev/null || true
    for _ in {1..25}; do
      kill -0 "$active_pid" 2>/dev/null || break
      sleep 0.2
    done
    if kill -0 "$active_pid" 2>/dev/null; then kill -KILL "$active_pid" 2>/dev/null || true; fi
    wait "$active_pid" 2>/dev/null || true
    active_pid=''
  fi
}
cleanup() { stop_own_process; rm -rf "$work"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# One compile, original bundle/path allowlist and sandbox with neither networking nor iCloud.
bash scripts/build-ui-fixture.sh > "$output/build.log" 2>&1
app="$PWD/.build/ui-fixture/Stox UI Fixture.app"
executable="$app/Contents/MacOS/Stox"
codesign --verify --deep --strict "$app"
codesign -d --entitlements - "$app" > "$output/entitlements.plist" 2> "$output/signature.log"
python3 - "$app/Contents/Info.plist" "$output/entitlements.plist" <<'PY'
import plistlib, sys
info = plistlib.load(open(sys.argv[1], 'rb'))
entitlements = plistlib.load(open(sys.argv[2], 'rb'))
assert info['CFBundleIdentifier'] == 'io.github.whrss9527.stox.uifixture20261107'
assert info['StoxUIFixture'] is True
assert entitlements == {'com.apple.security.app-sandbox': True}, entitlements
PY
{
  echo "github_sha=${GITHUB_SHA:-unknown}"
  echo "source_sha=$(git rev-parse HEAD)"
  echo "fixture_executable_sha256=$(shasum -a 256 "$executable" | cut -d ' ' -f1)"
  git status --short
  xcodebuild -version
  echo 'Views: production PanelView, QuoteRow, QuoteChart; adapters: UIFixtureProvider/UIFixtureDefaults; network: sandbox denied'
  echo 'Frame/data assertions and own-process AX are automated; human review of the captured images is still required.'
} > "$output/source.txt"
swiftc -O scripts/ci-screenshot.swift -o "$work/crop"

run_case() {
  local name="$1" language="$2" symbol="$3" compact="$4" dark="$5" chart="$6"
  local log="$output/$name.log" ax_path
  local flags=(--fixture-language "$language" --fixture-crypto-only --export-own-ax
               --show-panel --expand "$symbol" --chart "$chart")
  [[ "$compact" == false ]] || flags+=(--fixture-compact)
  [[ "$dark" == false ]] || flags+=(--fixture-dark)
  "$executable" "${flags[@]}" > "$log" 2>&1 &
  active_pid=$!
  if ! wait_for_stox_ready "$active_pid" "$log"; then
    if kill -0 "$active_pid" 2>/dev/null; then
      sample "$active_pid" 3 -file "$output/$name-timeout-sample.txt" > "$output/$name-timeout-sample.log" 2>&1 || true
    fi
    cat "$log"
    return 1
  fi
  # Actual NSPanel and NSHostingView diagnostics, not a mirror of SwiftUI layout formulas.
  python3 - "$log" "$language" "$symbol" "$compact" "$dark" "$chart" <<'PY'
import re, sys
from pathlib import Path
log, language, symbol, compact, dark, chart = sys.argv[1:]
text = Path(log).read_text()
assert 'STOX_DIAG late ready=true' in text
assert 'STOX_FIXTURE snapshot_ready=true' in text, text
appearance = 'dark' if dark == 'true' else 'light'
assert f'STOX_FIXTURE language={language} english={str(language == "en").lower()} compact={compact} appearance={appearance} items=3 quotes=3' in text, text
assert f'expanded={symbol}' in text and f'chart={chart}' in text, text
assert 'symbol=ccDOGEUSDT pair=DOGE/USDT price=0.087654 decimals=6 stale=false' in text, text
assert 'symbol=ccETHUSDT pair=ETH/USDT price=2456.789 decimals=2 stale=true quote_time=11-06 05:50:00 UTC' in text, text
frames = re.findall(r'panel_frame=(-?\d+) (-?\d+) (\d+) (\d+) content=(\d+)x(\d+) fitting=(\d+) list_max=\d+ available=(-?\d+)', text)
assert frames, text
x, y, width, height, cw, ch, fitting, available = map(int, frames[-1])
assert 0 < width <= 800 and 0 < cw <= width + 1, frames[-1]
assert 0 < height <= available + 1 and 0 < fitting <= available + 1, frames[-1]
print(f'Actual panel/frame fits: {width}x{height}; content {cw}x{ch}; fitting {fitting}; available {available}')
PY
  ax_path=$(sed -n 's/^STOX_FIXTURE ax_path=//p' "$log" | tail -1)
  [[ -n "$ax_path" && -s "$ax_path" ]] || { echo "error: missing own-process AX export ($name)" >&2; return 1; }
  cp "$ax_path" "$output/$name.ax.txt"
  # Full screen lives only in this script's private CI temp directory; upload the actual cropped panel.
  screencapture -x "$work/$name-full.png"
  python3 - "$log" > "$work/frame.txt" <<'PY'
import re, sys
from pathlib import Path
frames = re.findall(r'capture_frame=(-?\d+) (-?\d+) (\d+) (\d+)', Path(sys.argv[1]).read_text())
assert frames, 'missing actual capture frame'
print(' '.join(frames[-1]))
PY
  local frame=()
  read -r -a frame < "$work/frame.txt"
  "$work/crop" "$work/$name-full.png" "$output/$name.jpg" "${frame[@]}" 900 0.9
  [[ -s "$output/$name.jpg" ]] || return 1
  stop_own_process
}

run_case en-btc en ccBTCUSDT false false intraday
run_case en-doge-compact en ccDOGEUSDT true false intraday
run_case en-eth-stale-dark en ccETHUSDT false true intraday
run_case zh-btc zh-Hans ccBTCUSDT false false intraday
run_case zh-doge-compact zh-Hans ccDOGEUSDT true false intraday
run_case hant-eth-stale zh-Hant ccETHUSDT false false intraday
run_case en-btc-day en ccBTCUSDT false false day
echo 'Crypto UI fixture: 7 real-window captures produced; visual acceptance remains a human review.'
