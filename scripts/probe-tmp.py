#!/usr/bin/env python3
# Temporary probe (to be removed): print raw responses with field indexes.
import re, sys, urllib.request, urllib.parse

UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

def get(url, referer=None, enc="utf-8"):
    headers = {"User-Agent": UA}
    if referer:
        headers["Referer"] = referer
    req = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return r.read().decode(enc, "replace")
    except Exception as e:
        return f"!! request failed: {e}"

def show(title, url, referer=None, enc="utf-8", sep=None, raw=False):
    print("=" * 70)
    print("##", title)
    print("##", url)
    text = get(url, referer, enc)
    if raw or text.startswith("!!"):
        print(text[:6000])
        return
    found = False
    for key, payload in re.findall(r'(?:v_|hq_str_)([^=\s]+)="([^"]*)"', text):
        found = True
        s = sep or ("~" if "~" in payload else ",")
        parts = payload.split(s)
        print(f"-- {key}: {len(parts)} fields")
        print("  " + "  ".join(f"[{i}]{v}" for i, v in enumerate(parts)))
    if not found:
        print(text[:3000])
    sys.stdout.flush()

Q = "https://qt.gtimg.cn/utf8/q="
show("tencent US stocks", Q + "usAAPL,usBRK.B,usMSFT,usNVDA,usGOOGL,usBABA,usTSLA,usMETA,usAMZN,usJPM,usV,usKO,usSPY,usQQQ")
show("tencent US indices", Q + "us.IXIC,us.DJI,us.INX,usINX,us.NDX,usSPX,us.SPX,usDJI,usIXIC")
show("tencent HK", Q + "hk00700,hk09988,hk00005,hk01810,hk03690,hk02800,hkHSI,hkHSCEI,hkHSTECH")
show("tencent CN indices", Q + "sh000001,sz399001,sz399006,sh000300,sh000688,sh000016,sh000905,bj899050")
show("tencent global guesses", Q + "usN225,us.N225,gzN225,hkN225,znb_NKY,usFTSE,us.FTSE,us.GDAXI,us.UKX,us.KOSPI")
show("tencent GBK path US", "https://qt.gtimg.cn/q=usAAPL,hk00700", enc="gb18030")

S = "https://smartbox.gtimg.cn/s3/?v=2&t=all&c=1&q="
for q in ["aapl", "apple", "msft", "nvda", "brk", "tencent", "00700", "nikkei", "日经", "日经225", "富时100", "dax",
          "德国dax", "恒生指数", "标普", "道琼斯", "inx", "sp500", "kospi", "ftse"]:
    show("tencent smartbox " + q, S + urllib.parse.quote(q), raw=True)

SINA = "https://hq.sinajs.cn/list="
R = "https://finance.sina.com.cn/"
show("sina znb_", SINA + "znb_NKY,znb_UKX,znb_DAX,znb_CAC,znb_SX5E,znb_KOSPI,znb_AS51,znb_SPTSX,znb_SENSEX,znb_TWSE,znb_TWJQ,znb_INDU,znb_SPX,znb_CCMP,znb_HSI,znb_STI,znb_NIFTY,znb_IBOV,znb_FTSEMIB,znb_IBEX,znb_SMI,znb_AEX,znb_XIN9I,znb_TAIEX,znb_JCI,znb_SET,znb_FBMKLCI,znb_PCOMP,znb_VNINDEX,znb_NZSE50FG,znb_AORD", referer=R, enc="gb18030")
show("sina int_", SINA + "int_nikkei,int_ftse,int_dax,int_cac,int_dji,int_nasdaq,int_sp500,int_hangseng,int_kospi,int_sensex,int_tsx,int_asx,int_stoxx50", referer=R, enc="gb18030")
show("sina b_", SINA + "b_NKY,b_UKX,b_DAX,b_CAC,b_SX5E,b_KOSPI,b_AS51,b_SPTSX,b_SENSEX,b_TWSE", referer=R, enc="gb18030")
show("sina gb_ indices", SINA + "gb_$dji,gb_dji,gb_inx,gb_$inx,gb_ixic,gb_$ixic,gb_aapl,gb_brk$b", referer=R, enc="gb18030")
show("sina hk English", SINA + "hk00700,hk09988,rt_hk00700,hkHSI,rt_hkHSI", referer=R, enc="gb18030")
show("sina search nikkei", "https://suggest3.sinajs.cn/suggest/type=&key=nikkei&name=suggestdata", referer=R, enc="gb18030", raw=True)
show("sina search nikkei cn", "https://suggest3.sinajs.cn/suggest/type=&key=" + urllib.parse.quote("日经", encoding="gb18030") + "&name=suggestdata", referer=R, enc="gb18030", raw=True)
show("sina search ftse", "https://suggest3.sinajs.cn/suggest/type=&key=ftse&name=suggestdata", referer=R, enc="gb18030", raw=True)
