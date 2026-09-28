#!/usr/bin/env bash
# 探测行情数据源是否可用，并打印解码后的原始返回，方便排查接口格式变化。
# 用法: ./scripts/check-datasources.sh
set -uo pipefail

UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

fetch() {
  local title="$1" url="$2" enc="${3:-GB18030}" referer="${4:-}"
  echo "=================================================================="
  echo "## ${title}"
  echo "## ${url}"
  local args=(-sS -m 15 -A "$UA" -D /tmp/stox-headers.txt)
  [[ -n "$referer" ]] && args+=(-H "Referer: ${referer}")
  if curl "${args[@]}" "$url" -o /tmp/stox-body.bin; then
    grep -i -E "^(HTTP|content-type)" /tmp/stox-headers.txt
    if [[ "$enc" == "UTF-8" ]]; then cat /tmp/stox-body.bin; else iconv -f "$enc" -t UTF-8 /tmp/stox-body.bin; fi
    echo
  else
    echo "!! request failed"
  fi
}

Q="https://qt.gtimg.cn/q="
fetch "tencent quote: A shares + indices" "${Q}sh600519,sz000001,sh000001,sz399001,sz399006,sh000688,sh510300,sz159915,sh688981,sz300750"
fetch "tencent quote: HK" "${Q}hk00700,hk09988,hkHSI,hkHSTECH,hkHSCEI"
fetch "tencent quote: US" "${Q}usAAPL,usBABA,usTSLA,usBRK.B"
for c in usIXIC us.IXIC usDJI us.DJI usINX us.INX usNDX us.NDX; do fetch "tencent quote: US index ${c}" "${Q}${c}"; done
fetch "tencent quote: BJ" "${Q}bj830799,bj920819,bj899050"
fetch "tencent quote: invalid code mixed in" "${Q}sh600519,sh999999,hk00700"
fetch "tencent quote: utf8 path" "https://qt.gtimg.cn/utf8/q=sh600519,hk00700" "UTF-8"

S="https://smartbox.gtimg.cn/s3/?v=2&t=all&c=1&q="
for q in gzmt 600519 00700 aapl tsla nasdaq hsi "%E8%85%BE%E8%AE%AF" "%E7%BA%B3%E6%96%AF%E8%BE%BE%E5%85%8B" "%E8%8C%85%E5%8F%B0" zzzzqqq; do
  fetch "tencent smartbox: ${q}" "${S}${q}" "UTF-8"
done

fetch "sina quote (fallback candidate)" "https://hq.sinajs.cn/list=sh600519,hk00700,gb_aapl" "GB18030" "https://finance.sina.com.cn/"
