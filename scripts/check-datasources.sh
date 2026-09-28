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

# 分时数据（面板里的分时图用）：返回很长，只打印条数、日期和首尾几条。
minute() {
  local title="$1" url="$2"
  echo "=================================================================="
  echo "## ${title}"
  echo "## ${url}"
  if curl -sS -m 15 -A "$UA" "$url" -o /tmp/stox-body.bin; then
    python3 - /tmp/stox-body.bin <<'PY'
import json, sys
try:
    body = json.load(open(sys.argv[1]))
except Exception as error:
    print("not json:", error, open(sys.argv[1], "rb").read()[:300])
    sys.exit(0)
for key, value in (body.get("data") or {}).items():
    series = (value.get("data") or {}) if isinstance(value, dict) else {}
    points = series.get("data") or []
    print(f"key={key} date={series.get('date')!r} points={len(points)}")
    print("  first:", points[:3])
    print("  last:", points[-3:])
    quote = (value.get("qt") or {}).get(key) or []
    print("  qt fields:", len(quote), quote[:4])
PY
  else
    echo "!! request failed"
  fi
}

M="https://web.ifzq.gtimg.cn/appstock/app/minute/query?code="
for c in sh600519 sz000001 bj920819 sh000001 hk00700 hkHSI; do
  minute "tencent minute: ${c}" "${M}${c}"
done
U="https://web.ifzq.gtimg.cn/appstock/app/UsMinute/query?code="
for c in usAAPL.OQ usBRK.B.N us.IXIC us.DJI us.INX usAAPL; do
  minute "tencent US minute: ${c}" "${U}${c}"
done

# 美股盘前盘后：逐个字段打印美股行情，找盘前盘后价格在哪几位；再看 K 线接口里的 pandata。
fields() {
  local title="$1" url="$2"
  echo "=================================================================="
  echo "## ${title}"
  echo "## ${url}"
  if curl -sS -m 15 -A "$UA" "$url" -o /tmp/stox-body.bin; then
    python3 - /tmp/stox-body.bin <<'PY'
import re, sys
text = open(sys.argv[1], "rb").read().decode("utf-8", "replace")
for key, payload in re.findall(r'v_([^=]+)="([^"]*)"', text):
    parts = payload.split("~")
    print(f"{key}: {len(parts)} fields")
    print("  " + "  ".join(f"[{i}]{v}" for i, v in enumerate(parts) if v not in ("", "0", "0.00", "0.000")))
if "v_" not in text:
    print(text[:500])
PY
  else
    echo "!! request failed"
  fi
}
fields "tencent quote fields: US" "https://qt.gtimg.cn/utf8/q=usAAPL,usTSLA,usNVDA"
fields "tencent quote fields: FX guesses" "https://qt.gtimg.cn/utf8/q=whUSDCNY,whHKDCNY,whUSDHKD,fxUSDCNY,USDCNY"
fetch "tencent smartbox: usdcny" "https://smartbox.gtimg.cn/s3/?v=2&t=all&c=1&q=usdcny" "UTF-8"
fetch "tencent smartbox: hkdcny" "https://smartbox.gtimg.cn/s3/?v=2&t=all&c=1&q=hkdcny" "UTF-8"
pandata() {
  local title="$1" url="$2"
  echo "=================================================================="
  echo "## ${title}"
  echo "## ${url}"
  if curl -sS -m 15 -A "$UA" "$url" -o /tmp/stox-body.bin; then
    python3 - /tmp/stox-body.bin <<'PY'
import json, sys
raw = open(sys.argv[1], "rb").read()
try:
    body = json.loads(raw)
except Exception as error:
    print("not json:", error, raw[:300]); sys.exit(0)
for key, value in (body.get("data") or {}).items():
    if not isinstance(value, dict):
        continue
    print(f"key={key} fields={sorted(value.keys())}")
    for name in ("pandata", "prec", "mx_price", "version"):
        if name in value:
            print(f"  {name}: {json.dumps(value[name], ensure_ascii=False)[:600]}")
    data = value.get("data")
    if isinstance(data, dict):
        print("  data fields:", sorted(data.keys()))
PY
  else
    echo "!! request failed"
  fi
}
pandata "tencent usfqkline pandata: usAAPL.OQ" "https://web.ifzq.gtimg.cn/appstock/app/usfqkline/get?param=usAAPL.OQ,day,,,2,qfq"
pandata "tencent US minute keys: usAAPL" "https://web.ifzq.gtimg.cn/appstock/app/UsMinute/query?code=usAAPL"
fetch "sina fx (fallback candidate)" "https://hq.sinajs.cn/list=fx_susdcny,fx_shkdcny,fx_susdhkd" "GB18030" "https://finance.sina.com.cn/"

# 五日分时：打印返回的结构（各层的键、列表长度），找每天的分时在哪里。
shape() {
  local title="$1" url="$2"
  echo "=================================================================="
  echo "## ${title}"
  echo "## ${url}"
  if curl -sS -m 15 -A "$UA" "$url" -o /tmp/stox-body.bin; then
    python3 - /tmp/stox-body.bin <<'PY'
import json, sys
raw = open(sys.argv[1], "rb").read()
try:
    body = json.loads(raw)
except Exception as error:
    print("not json:", error, raw[:300]); sys.exit(0)
def walk(value, path, depth):
    if depth > 5:
        return
    if isinstance(value, dict):
        for key, item in list(value.items())[:12]:
            walk(item, f"{path}.{key}", depth + 1)
    elif isinstance(value, list):
        sample = value[0] if value else None
        print(f"{path}: list[{len(value)}] first={json.dumps(sample, ensure_ascii=False)[:160]}")
        if isinstance(sample, (dict, list)):
            walk(sample, f"{path}[0]", depth + 1)
    else:
        print(f"{path} = {json.dumps(value, ensure_ascii=False)[:120]}")
walk(body, "$", 0)
PY
  else
    echo "!! request failed"
  fi
}
shape "tencent 5-day: sh600519" "https://web.ifzq.gtimg.cn/appstock/app/day/query?code=sh600519"
shape "tencent 5-day: hk00700" "https://web.ifzq.gtimg.cn/appstock/app/day/query?code=hk00700"
shape "tencent 5-day: usAAPL (dayus)" "https://web.ifzq.gtimg.cn/appstock/app/dayus/query?code=usAAPL.OQ"
shape "tencent 5-day: usAAPL (UsDay)" "https://web.ifzq.gtimg.cn/appstock/app/UsDay/query?code=usAAPL"

# 新浪行情（腾讯不可用时的备用）：A 股、ETF、北交所、指数、港股、美股个股和美股指数的写法。
fetch "sina quote (fallback)" 'https://hq.sinajs.cn/list=sh600519,sz000001,sh000001,sz399006,sh510300,bj920819,hk00700,hkHSI,gb_aapl,gb_brk.b,gb_brk$b,gb_ixic,gb_$ixic,gb_dji,gb_$dji,gb_inx,gb_$inx,sh999999' "GB18030" "https://finance.sina.com.cn/"
fetch "sina quote without referer" "https://hq.sinajs.cn/list=sh600519" "GB18030"

# K 线（面板里的日 K、周 K、月 K 用）：只打印每个序列的条数和首尾几条，并检查字段顺序。
kline() {
  local title="$1" url="$2"
  echo "=================================================================="
  echo "## ${title}"
  echo "## ${url}"
  if curl -sS -m 15 -A "$UA" "$url" -o /tmp/stox-body.bin; then
    python3 - /tmp/stox-body.bin <<'PY'
import json, sys
raw = open(sys.argv[1], "rb").read()
try:
    body = json.loads(raw)
except Exception as error:
    print("not json:", error, raw[:300])
    sys.exit(0)
print("code:", body.get("code"), "msg:", body.get("msg"))
data = body.get("data")
if not isinstance(data, dict):
    print("data:", str(data)[:300])
    sys.exit(0)
for key, value in data.items():
    if not isinstance(value, dict):
        print(f"key={key} value={str(value)[:200]}")
        continue
    print(f"key={key} fields={sorted(value.keys())}")
    for name, rows in value.items():
        if not isinstance(rows, list) or not rows or not isinstance(rows[0], list):
            continue
        print(f"  {name}: {len(rows)} rows, widths={sorted(set(len(r) for r in rows))}")
        print("    first:", rows[:2])
        print("    last:", rows[-2:])
        # 猜字段顺序：[日期, 开, 收, 高, 低, 量] 时每行的高 >= 开收、低 <= 开收。
        ok_occl = ok_ohlc = 0
        for r in rows:
            try:
                a, b, c, d = (float(x) for x in r[1:5])
            except Exception:
                continue
            if c >= max(a, b) and d <= min(a, b): ok_occl += 1
            if b >= max(a, d) and c <= min(a, d): ok_ohlc += 1
        print(f"    order check: open-close-high-low {ok_occl}/{len(rows)}, open-high-low-close {ok_ohlc}/{len(rows)}")
    qt = value.get("qt")
    if isinstance(qt, dict):
        print("  qt keys:", list(qt.keys())[:6])
PY
  else
    echo "!! request failed"
  fi
}

K="https://web.ifzq.gtimg.cn/appstock/app/fqkline/get?param="
for p in sh600519,day,,,5,qfq sz000001,day,,,5,qfq sh000001,day,,,5,qfq bj920819,day,,,5,qfq sh510300,day,,,5,qfq \
         sh600519,week,,,3,qfq sh600519,month,,,3,qfq sh600519,day,,,320,qfq \
         hk00700,day,,,5,qfq hkHSI,day,,,5,qfq \
         usAAPL,day,,,5,qfq usAAPL.OQ,day,,,5,qfq us.IXIC,day,,,5,qfq usBRK.B,day,,,5,qfq; do
  kline "tencent fqkline: ${p}" "${K}${p}"
done
kline "tencent hkfqkline: hk00700" "https://web.ifzq.gtimg.cn/appstock/app/hkfqkline/get?param=hk00700,day,,,5,qfq"
kline "tencent hkfqkline: hk00700 week" "https://web.ifzq.gtimg.cn/appstock/app/hkfqkline/get?param=hk00700,week,,,3,qfq"
kline "tencent usfqkline: usAAPL" "https://web.ifzq.gtimg.cn/appstock/app/usfqkline/get?param=usAAPL,day,,,5,qfq"
kline "tencent usfqkline: usAAPL.OQ" "https://web.ifzq.gtimg.cn/appstock/app/usfqkline/get?param=usAAPL.OQ,day,,,5,qfq"
kline "tencent usfqkline: us.IXIC" "https://web.ifzq.gtimg.cn/appstock/app/usfqkline/get?param=us.IXIC,day,,,5,qfq"
kline "tencent usfqkline: usAAPL month" "https://web.ifzq.gtimg.cn/appstock/app/usfqkline/get?param=usAAPL,month,,,3,qfq"
kline "tencent kline (no adjust): sh600519" "https://web.ifzq.gtimg.cn/appstock/app/kline/kline?param=sh600519,day,,,5"
