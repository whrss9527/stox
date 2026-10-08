#!/usr/bin/env bash
# 逐个数据源运行 CLI 断言，失败追加到已有巡检报告，原始字节另存附件。
set -euo pipefail
cd "$(dirname "$0")/.."
CLI="${STOX_CLI:-$PWD/.build/debug/stox-cli}"
REPORT="${STOX_DATASOURCE_REPORT:?set STOX_DATASOURCE_REPORT}"
RAW="${STOX_DATASOURCE_RAW_DIR:?set STOX_DATASOURCE_RAW_DIR}"
mkdir -p "$RAW"
touch "$REPORT"
failures=0
for source in tencent sina; do
  symbols=()
  for pair in 'sh600519|A shares + indices' 'sz000001|A shares + indices' 'sh000001|A shares + indices' 'hk00700|HK' 'usAAPL|US'; do
    symbol=${pair%%|*}
    title="$source quote: ${pair#*|}"
    if [[ -z "${ONLY:-}" || "$title" =~ $ONLY ]]; then symbols+=("$symbol"); fi
  done
  [[ ${#symbols[@]} -gt 0 ]] || continue
  options=(--source "$source")
  [[ -z "${STOX_QUOTE_MAX_AGE_DAYS:-}" ]] || options+=(--max-age-days "$STOX_QUOTE_MAX_AGE_DAYS")
  result=0
  "$CLI" check --save-raw "$RAW/$source-invariants.bin" "${options[@]}" "${symbols[@]}" > "$RAW/$source-invariants.log" 2>&1 || result=$?
  cat "$RAW/$source-invariants.log"
  if [[ "$result" != 0 ]]; then
    failures=$((failures+1))
    {
      printf '### %s quote invariant differences (exit %s)\n\n```text\n' "$source" "$result"
      sed 's/```/~~~/g' "$RAW/$source-invariants.log"
      printf '\n```\n\n'
    } >> "$REPORT"
  fi
done
[[ "$failures" = 0 ]]
