import XCTest
@testable import StoxCore

/// 英文界面里的名称、按界面语言选的默认自选，和新浪的环球股指。
final class EnglishNameTests: XCTestCase {
    // 2026-10-01 从腾讯行情接口抓取（原样）：美股、美股指数、港股、港股指数和一个 A 股指数。
    static let tencent = #"""
    v_usAAPL="200~苹果~AAPL.OQ~333.02~329.40~330.80~49988558~0~0~334.25~40~0~0~0~0~0~0~0~0~334.30~80~0~0~0~0~0~0~0~0~~2026-09-30 16:00:01~3.62~1.10~339.50~330.14~USD~49988558~16751578866~0.34~38.19~~44.64~~2.84~48571.32959~48601.53824~Apple Inc.~8.72~345.34~242.76~-40~45.20~0.32~48601.53824~22.83~-1.19~GP~148.75~36.08~0.18~2.43~7.29~14594180000~14585108878~1.58~36.30~1.06~335.11~~~~~";
    v_usBRK.B="200~伯克希尔B~BRK.B.N~497.95~502.35~501.43~7050909~0~0~498.25~280~0~0~0~0~0~0~0~0~498.65~80~0~0~0~0~0~0~0~0~~2026-09-30 16:05:57~-4.40~-0.88~502.12~497.95~USD~7050909~3518830955~0.33~12.52~~16.04~~0.83~6212.48999~10659.66442~Berkshire Hathaway Inc. New~39.77~537.74~464.01~200~1.43~~10659.66442~-0.94~-1.82~GP~12.11~7.07~-4.20~-0.87~-1.20~2140709794~1247613213~1.93~15.01~~499.06~~~~~";
    v_usJPM="200~摩根大通~JPM.N~330.83~334.98~334.89~9121168~0~0~331.25~80~0~0~0~0~0~0~0~0~331.80~80~0~0~0~0~0~0~0~0~~2026-09-30 16:05:57~-4.15~-1.24~336.34~330.83~USD~9121168~3026002303~0.34~14.17~~16.52~~1.64~8765.71506~8794.07739~Jp Morgan Chase & Co.~23.34~366.50~276.43~0~2.49~1.86~8794.07739~4.13~-1.99~GP~17.71~1.35~-5.18~-6.80~-2.47~2658186195~2649613113~1.06~12.14~6.15~331.76~~~~~";
    v_usKO="200~可口可乐~KO.N~86.08~86.84~87.35~15844178~0~0~86.16~200~0~0~0~0~0~0~0~0~86.23~100~0~0~0~0~0~0~0~0~~2026-09-30 16:05:57~-0.76~-0.88~87.52~86.07~USD~15844178~1369583425~0.37~25.85~~28.32~~1.66~3677.27389~3703.63439~Coca-Cola Company (The)~3.33~91.94~64.14~100~10.25~2.44~3703.63439~25.51~-2.28~GP~44.23~13.49~-2.04~-1.60~3.02~4302549243~4271925993~1.19~22.19~2.10~86.44~~~~~";
    v_usSPY="200~标普500指数ETF-SPDR~SPY.AM~762.63~764.20~766.45~62110041~0~0~765.53~40~0~0~0~0~0~0~0~0~765.54~480~0~0~0~0~0~0~0~0~~2026-09-30 16:00:01~-1.57~-0.21~769.41~762.18~USD~62110041~47556933333~~~~~~0.95~~~State Street Spdr S&P 500 Etf~~777.42~626.07~-440~~~~12.71~-0.67~GP-ETF~~~1.39~0.36~2.25~~~1.44~~~765.69~~~~1061582000~";
    v_us.INX="200~标普500~.INX~7651.54~7670.84~7688.99~3151899948~0~0~7640.51~0~0~0~0~0~0~0~0~0~7707.72~0~0~0~0~0~0~0~0~0~~2026-09-30 16:38:12~-19.30~-0.25~7722.88~7651.54~USD~3151899948~24116888528120~~~~~~0.93~~~S&P 500 Index~~7816.70~6316.91~0~~~~11.77~-0.71~ZS~~~1.32~0.26~1.97~~~1.11~~~7651.54~~~~~";
    v_us.DJI="200~道琼斯~.DJI~50906.05~51349.92~51424.84~487861488~0~0~50931.85~0~0~0~0~0~0~0~0~0~51102.19~0~0~0~0~0~0~0~0~0~~2026-09-30 16:48:36~-443.87~-0.86~51473.93~50906.05~USD~487861488~24953095573872~~~~~~1.11~~~Dow Jones~~54744.33~45057.28~0~~~~5.91~-1.18~ZS~~~-1.08~-3.53~-3.82~~~1.19~~~51147.91~~~~~";
    v_hk00700="100~腾讯控股~00700~431.000~432.000~430.000~22634903.0~0~0~431.000~0~0~0~0~0~0~0~0~0~431.000~0~0~0~0~0~0~0~0~0~22634903.0~2026/09/30 16:08:33~-1.000~-0.23~432.200~424.400~431.000~22634903.0~9704691475.292~0~15.74~~0~0~1.81~39189.1301~39189.1301~TENCENT~1.23~677.700~411.000~1.43~20.29~0~0~0~0~0~14.45~3.01~0.25~100~-27.40~-2.27~GP~20.41~11.00~-0.55~-1.64~-9.98~9092605595.00~9092605595.00~14.91~5.315~428.749~-30.39~HKD~1~50";
    v_hk09988="100~阿里巴巴-W~09988~106.600~106.200~105.300~47287932.0~0~0~106.600~0~0~0~0~0~0~0~0~0~106.600~0~0~0~0~0~0~0~0~0~47287932.0~2026/09/30 16:08:33~0.400~0.38~107.400~105.200~106.600~47287932.0~5031551463.270~0~18.08~~0~0~2.07~21215.4888~21215.4888~BABA-W~0.93~185.173~88.650~0.93~26.69~0~0~0~0~0~25.13~1.65~0.24~100~-24.81~-2.91~GP~7.04~3.60~0.38~-3.00~-0.84~19901959514.00~19901959514.00~43.40~0.992~106.402~-26.42~HKD~1~50";
    v_hk00005="100~汇丰控股~00005~158.000~159.000~157.400~7997112.0~0~0~158.000~0~0~0~0~0~0~0~0~0~158.000~0~0~0~0~0~0~0~0~0~7997112.0~2026/09/30 16:08:27~-1.000~-0.63~158.200~156.400~158.000~7997112.0~1257349471.747~0~16.49~~0~0~1.13~27084.2688~27084.2688~HSBC HOLDINGS~3.72~168.916~94.532~0.78~-21.27~0~0~0~0~0~14.26~2.01~0.05~400~34.69~-0.94~GP~12.23~0.75~-1.80~-2.83~4.56~17141942291.00~17141942291.00~11.81~5.881~157.225~29.39~HKD~1~50";
    v_hkHSI="100~恒生指数~HSI~24613.270~24523.570~24393.880~18715777.0419~0~0~24613.270~0~0~0~0~0~0~0~0~0~24613.270~0~0~0~0~0~0~0~0~0~0.0~2026/09/30 18:31:27~89.700~0.37~24637.650~24332.640~24613.270~18715777.0419~18715777.042~0~0~~0~0~1.24~0~0~Hang Seng Index~0~28056.100~22518.000~1.32~-0.51~0~0~0~0~0~0.00~0.00~0.00~0~-3.97~-0.89~ZS~~~-0.41~-2.76~1.71~0.00~0.00~0.00~0.000~~-6.98~HKD~1~";
    v_sh000001="1~上证指数~000001~3842.19~3830.45~3839.25~414560247~0~0~0.00~0~0.00~0~0.00~0~0.00~0~0.00~0~0.00~0~0.00~0~0.00~0~0.00~0~0.00~0~~20260930161500~11.74~0.31~3851.22~3833.09~3842.19/414560247/679398992445~414560247~67939899~0.85~16.76~~3851.22~3833.09~0.47~602370.78~682245.82~0.00~-1~-1~0.92~0~3842.53~~~~~~67939899.2445~0.0000~0~ ~ZS~-3.19~-2.78~~~~4258.86~3741.11~-0.57~-3.46~-3.71~4858320758781~~-9.37~-4.50~4858320758781~~~-1.05~-0.02~~CNY~0~~0.00~0~";
    """#

    // 同一时间新浪的环球股指（原样）。多伦多只有前 6 个字段，XIN9I 查不到。
    static let sina = #"""
    var hq_str_znb_NKY="日经225,68956.5000,2202.78,3.30,2:12 AM,1759126320,2026-10-01,14:30:01,67106.5200,66753.7200,68995.3000,67081.6600,0";
    var hq_str_znb_UKX="英国富时100,10445.5900,-160.41,-1.51,9/26/2025,1758859200,2026-10-01,17:26:52,10606.3900,10606.0000,10606.3900,10390.7300,0";
    var hq_str_znb_DAX="德国DAX30,25028.9492,-170.24,-0.68,9/26/2025,1758859200,2026-10-01,17:40:55,25058.0801,25199.1895,25104.7793,24831.5996,0";
    var hq_str_znb_SPTSX="S&P/TSX综合指数,29761.28,29.30,0.10,9/26/2025,1758859200";
    var hq_str_znb_XIN9I="";
    """#

    private let quotes = TencentQuoteParser.parse(EnglishNameTests.tencent)

    private func item(_ raw: String, alias: String? = nil) -> (item: WatchItem, quote: Quote?) {
        let symbol = Symbol(raw)!
        let quote = quotes[symbol]
        return (WatchItem(symbol: symbol, name: quote?.name ?? "", alias: alias, pinned: true), quote)
    }

    private func english(_ raw: String) -> String {
        let (item, quote) = item(raw)
        return item.displayName(with: quote, english: true)
    }

    private func englishTicker(_ raw: String) -> String {
        let (item, quote) = item(raw)
        return item.tickerName(with: quote, english: true)
    }

    func testParsesEnglishNames() throws {
        XCTAssertEqual(quotes.count, 12)
        XCTAssertEqual(quotes[Symbol("usAAPL")!]?.name, "苹果", "名称还是中文")
        XCTAssertEqual(quotes[Symbol("usAAPL")!]?.englishName, "Apple Inc.")
        XCTAssertEqual(quotes[Symbol("usBRK.B")!]?.englishName, "Berkshire Hathaway Inc. New")
        XCTAssertNil(quotes[Symbol("usSPY")!]?.englishName, "ETF 的英文全称不要")
        XCTAssertEqual(quotes[Symbol("us.INX")!]?.englishName, "S&P 500 Index")
        XCTAssertEqual(quotes[Symbol("hk00700")!]?.englishName, "TENCENT")
        XCTAssertEqual(quotes[Symbol("hk00005")!]?.englishName, "HSBC HOLDINGS")
        XCTAssertEqual(quotes[Symbol("hkHSI")!]?.englishName, "Hang Seng Index")
        XCTAssertNil(quotes[Symbol("sh000001")!]?.englishName, "A 股的第 46 位是市净率")

        // 新浪的港股第 0 位是英文名，美股没有。
        let sina = SinaQuoteParser.parse(SinaTests.sample, symbols: [Symbol("hk00700")!, Symbol("usAAPL")!])
        XCTAssertEqual(sina[Symbol("hk00700")!]?.englishName, "TENCENT")
        XCTAssertEqual(sina[Symbol("usAAPL")!]?.name, "苹果")
        XCTAssertNil(sina[Symbol("usAAPL")!]?.englishName)
    }

    func testCompanyNames() {
        let names = [
            "Apple Inc.": "Apple",
            "Berkshire Hathaway Inc. New": "Berkshire Hathaway",
            "Microsoft Corporation": "Microsoft",
            "Nvidia Corporation": "Nvidia",
            "Alphabet Inc.": "Alphabet",
            "Alphabet Inc. Class A": "Alphabet",
            "Alibaba Group Holding Ltd": "Alibaba",
            "Tesla, Inc.": "Tesla",
            "Meta Platforms, Inc.": "Meta Platforms",
            "Amazon.Com, Inc.": "Amazon.Com",
            "Jp Morgan Chase & Co.": "Jp Morgan Chase",
            "Coca-Cola Company (The)": "Coca-Cola",
            "Visa Inc.": "Visa",
            "Group": "Group",
        ]
        for (name, short) in names {
            XCTAssertEqual(EnglishName.company(name), short, name)
        }
        XCTAssertEqual(EnglishName.abbreviate("HSBC HOLDINGS"), "HSBC")
        XCTAssertEqual(EnglishName.abbreviate("TENCENT"), "TENCENT")
        XCTAssertEqual(EnglishName.abbreviate("CHINA MOBILE"), "CHINA MOBILE")
        XCTAssertEqual(EnglishName.abbreviate("BANK OF COMMUNICATIONS"), "BANK", "末尾的 of 不要")
        XCTAssertEqual(EnglishName.abbreviate("Hang Seng China Enterprises Index"), "Hang Seng")
        XCTAssertEqual(EnglishName.abbreviate("SUPERCALIFRAGILISTIC"), "SUPERCALIFRA")
        XCTAssertNil(EnglishName.cleaned(" "))
        XCTAssertNil(EnglishName.cleaned("0.00"))
        XCTAssertNil(EnglishName.cleaned("腾讯"))
    }

    func testEnglishNamesInTheList() {
        XCTAssertEqual(english("usAAPL"), "Apple")
        XCTAssertEqual(english("usBRK.B"), "Berkshire Hathaway")
        XCTAssertEqual(english("usJPM"), "Jp Morgan Chase")
        XCTAssertEqual(english("usKO"), "Coca-Cola")
        XCTAssertEqual(english("usSPY"), "SPY", "没有英文名的美股用代码")
        XCTAssertEqual(english("us.INX"), "S&P 500")
        XCTAssertEqual(english("us.DJI"), "Dow Jones")
        XCTAssertEqual(english("hk00700"), "TENCENT")
        XCTAssertEqual(english("hk09988"), "BABA-W")
        XCTAssertEqual(english("hkHSI"), "Hang Seng")
        XCTAssertEqual(english("sh000001"), "SSE Composite")
        XCTAssertEqual(english("hf_XAU"), "Spot Gold")
        XCTAssertEqual(english("whEURUSD"), "EUR/USD")
        XCTAssertEqual(english("whUSDX"), "US Dollar Index")
        XCTAssertEqual(english("whUSDTRY"), "USD/TRY", "品种表里没有的外汇")
        XCTAssertEqual(english("znb_NKY"), "Nikkei 225")

        // 还没有行情时：美股、港股用代码；A 股、场外基金没有英文名，用中文名。
        XCTAssertEqual(WatchItem(symbol: Symbol("usAAPL")!, name: "苹果").displayName(with: nil, english: true), "AAPL")
        XCTAssertEqual(WatchItem(symbol: Symbol("hk00700")!, name: "腾讯控股").displayName(with: nil, english: true), "00700")
        XCTAssertEqual(WatchItem(symbol: Symbol("sh600519")!, name: "贵州茅台").displayName(with: nil, english: true), "贵州茅台")
        XCTAssertEqual(WatchItem(symbol: Symbol("jj161725")!, name: "招商中证白酒指数A").displayName(with: nil, english: true), "招商中证白酒指数A")
        XCTAssertEqual(WatchItem(symbol: Symbol("sz000001")!).displayName(with: nil, english: true), "000001")
    }

    func testEnglishNamesInTheMenuBar() {
        XCTAssertEqual(englishTicker("usAAPL"), "AAPL", "美股在菜单栏上用代码")
        XCTAssertEqual(englishTicker("usBRK.B"), "BRK.B")
        XCTAssertEqual(englishTicker("us.INX"), "S&P 500")
        XCTAssertEqual(englishTicker("us.DJI"), "Dow")
        XCTAssertEqual(englishTicker("hkHSI"), "HSI")
        XCTAssertEqual(englishTicker("hk00700"), "TENCENT")
        XCTAssertEqual(englishTicker("hk00005"), "HSBC")
        XCTAssertEqual(englishTicker("sh000001"), "SSE")
        XCTAssertEqual(englishTicker("hf_XAU"), "Gold")
        XCTAssertEqual(englishTicker("whEURUSD"), "EUR/USD")
        XCTAssertEqual(englishTicker("znb_NKY"), "Nikkei")
        XCTAssertEqual(WatchItem(symbol: Symbol("sh600519")!, name: "贵州茅台").tickerName(with: nil, english: true), "贵州茅台")

        // 用户设的简称总是优先。
        let aliased = item("usAAPL", alias: " 果 ")
        XCTAssertEqual(aliased.item.tickerName(with: aliased.quote, english: true), "果")
        XCTAssertEqual(aliased.item.automaticTickerName(with: aliased.quote, english: true), "AAPL", "编辑页里简称的提示")

        let entries = MenuBarTicker.entries(
            items: [item("us.INX").item, item("usAAPL").item], quotes: quotes, options: TickerOptions(), english: true
        )
        XCTAssertEqual(entries.map { $0.first?.text }, ["S&P 500", "AAPL"])
        XCTAssertEqual(entries[0].map(\.text), ["S&P 500", "7651.54", "-0.25%"])
    }

    /// 中文界面和以前一模一样：名称是数据源的中文名，菜单栏上截断中文名。
    func testChineseInterfaceIsUnchanged() {
        for (symbol, quote) in quotes {
            let item = WatchItem(symbol: symbol, name: "记下的名称", pinned: true)
            XCTAssertEqual(item.displayName(with: quote, english: false), quote.name)
            XCTAssertEqual(item.displayName(with: quote), quote.name, "测试里没有翻译表，是中文界面")
            XCTAssertEqual(item.displayName(with: nil, english: false), "记下的名称")
            XCTAssertEqual(item.tickerName(with: quote, english: false), "记下的名")
            XCTAssertEqual(item.tickerName, "记下的名")
        }
        let items = Watchlist.defaults(english: false)
        let entries = MenuBarTicker.entries(items: items, quotes: quotes, options: TickerOptions(), english: false)
        XCTAssertEqual(entries.map(\.first?.text), ["上证"])
        XCTAssertEqual(entries[0].map(\.text), ["上证", "3842.19", "+0.31%"])
        XCTAssertEqual(MenuBarTicker.entries(items: items, quotes: quotes, options: TickerOptions()), entries)

        let result = SearchResult(symbol: Symbol("usAAPL")!, name: "苹果", typeCode: "GP")
        XCTAssertEqual(result.displayName(quote: quotes[result.symbol], english: false), "苹果")
        XCTAssertEqual(result.displayName(quote: quotes[result.symbol]), "苹果")
        XCTAssertEqual(result.displayName(quote: quotes[result.symbol], english: true), "Apple")
        XCTAssertEqual(result.displayName(quote: nil, english: true), "AAPL")
        XCTAssertEqual(GlobalCatalog.search("黄金")[0].displayName(quote: nil, english: true), "Spot Gold")
    }

    func testDefaultWatchlistByLanguage() {
        let chinese = Watchlist.defaults(english: false)
        XCTAssertEqual(chinese.map(\.symbol.rawValue), ["sh000001", "sz399001", "sz399006", "hkHSI", "us.IXIC", "sh600519", "hk00700", "usAAPL"])
        XCTAssertEqual(Watchlist.defaults, chinese, "测试里没有翻译表，是中文界面")
        XCTAssertEqual(Watchlist.commonIndices, Watchlist.commonIndices(english: false))

        let english = Watchlist.defaults(english: true)
        XCTAssertEqual(english.map(\.symbol.rawValue), ["us.INX", "us.IXIC", "us.DJI", "usAAPL", "usMSFT", "usNVDA", "hf_XAU", "whEURUSD"])
        XCTAssertEqual(Set(english.map(\.symbol)).count, english.count)
        XCTAssertEqual(english.filter(\.pinned).map { $0.tickerName(with: nil, english: true) }, ["S&P 500"])
        XCTAssertEqual(english.filter(\.pinned).map(\.tickerName), ["S&P 500"], "切到中文界面也是这个简称")
        XCTAssertEqual(Watchlist.commonIndices(english: true).map(\.symbol.rawValue), ["us.INX", "us.IXIC", "us.DJI"])
        XCTAssertEqual(english.map { $0.displayName(with: nil, english: true) },
                       ["S&P 500", "Nasdaq Composite", "Dow Jones", "AAPL", "MSFT", "NVDA", "Spot Gold", "EUR/USD"])
        // 美股指数的代码要带点（us.INX、us.DJI），腾讯取得到。
        XCTAssertNotNil(quotes[Symbol("us.INX")!])
        XCTAssertNotNil(quotes[Symbol("us.DJI")!])
    }

    func testSearchesIndicesByEnglishName() {
        func codes(_ query: String) -> [String] { EnglishName.searchIndices(query).map(\.symbol.rawValue) }
        XCTAssertEqual(codes("S&P 500"), ["us.INX"])
        XCTAssertEqual(codes("s&p"), ["us.INX"])
        XCTAssertEqual(codes("dow"), ["us.DJI"])
        XCTAssertEqual(codes("nasdaq"), ["us.IXIC", "us.NDX"])
        XCTAssertEqual(codes("Hang Seng"), ["hkHSI", "hkHSTECH"])
        XCTAssertEqual(codes("csi 300"), ["sh000300", "sz399300"])
        XCTAssertEqual(codes("inx"), ["us.INX"], "代码也行")
        XCTAssertEqual(codes("ss"), [], "至少三个字才看开头")
        XCTAssertEqual(codes("000001"), [])
        XCTAssertEqual(codes("上证"), [])
        XCTAssertEqual(EnglishName.searchIndices("s&p 500").first?.typeLabel, "指数")
    }

    func testParsesGlobalIndices() throws {
        let symbols = ["znb_NKY", "znb_UKX", "znb_DAX", "znb_SPTSX", "znb_XIN9I"].map { Symbol($0)! }
        let quotes = SinaQuoteParser.parse(Self.sina, symbols: symbols)
        XCTAssertEqual(quotes.count, 3, "只有前 6 个字段的、空的不认")

        let nikkei = try XCTUnwrap(quotes[symbols[0]])
        XCTAssertEqual(nikkei.name, "日经225")
        XCTAssertEqual(nikkei.price, 68956.5)
        XCTAssertEqual(nikkei.previousClose, 66753.72)
        XCTAssertEqual(nikkei.open, 67106.52)
        XCTAssertEqual(nikkei.high, 68995.3)
        XCTAssertEqual(nikkei.low, 67081.66)
        XCTAssertEqual(nikkei.change, 2202.78, accuracy: 1e-6, "和接口给的涨跌一样")
        XCTAssertEqual(nikkei.changePercent, 3.30, accuracy: 0.005)
        XCTAssertEqual(nikkei.priceDecimals, 2)
        XCTAssertEqual(QuoteFormatter.price(nikkei.price, decimals: nikkei.priceDecimals), "68956.50")
        // 北京时间 14:30，就是东京 15:30 收盘。
        let close = MarketRegion.cn.calendar.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 14, minute: 30, second: 1))
        XCTAssertEqual(nikkei.timestamp, close)
        XCTAssertTrue(nikkei.hasTraded)
        XCTAssertNil(nikkei.bid)
        XCTAssertNil(nikkei.englishName)

        XCTAssertEqual(quotes[symbols[2]]?.name, "德国DAX", "用品种表里的名称，不用新浪过时的“德国DAX30”")
        XCTAssertEqual(quotes[symbols[1]]?.direction, .down)
        XCTAssertEqual(SinaProvider.code(for: symbols[0]), "znb_NKY")
        XCTAssertEqual(SinaProvider.quoteURL(for: Array(symbols.prefix(2)))?.absoluteString, "https://hq.sinajs.cn/list=znb_NKY,znb_UKX")
    }

    func testGlobalIndexSymbols() throws {
        let nikkei = try XCTUnwrap(Symbol("znb_NKY"))
        XCTAssertEqual(nikkei.market, .zn)
        XCTAssertEqual(nikkei.code, "NKY")
        XCTAssertEqual(nikkei.rawValue, "znb_NKY")
        XCTAssertEqual(nikkei.displayCode, "NKY")
        XCTAssertEqual(nikkei.market.label, "指")
        XCTAssertEqual(nikkei.market.region, .global)
        XCTAssertTrue(nikkei.isGlobal)
        XCTAssertTrue(nikkei.isIndex)
        XCTAssertFalse(nikkei.canHold)
        XCTAssertFalse(nikkei.hasIntraday, "没有走势图")
        XCTAssertFalse(nikkei.hasKline)
        XCTAssertNil(QuoteLinks.web(nikkei))
        XCTAssertFalse(TencentFundFlow.supports(nikkei))
        XCTAssertEqual(Symbol(market: .zn, code: "b_ukx")?.rawValue, "znb_UKX")
        XCTAssertEqual(Symbol(market: .zn, code: "UKX")?.rawValue, "znb_UKX")
        XCTAssertNil(Symbol("znb_"))

        XCTAssertEqual(SymbolInput.parse("znb_nky"), nikkei)
        XCTAssertEqual(SymbolInput.parse(" znb_NKY "), nikkei)
        XCTAssertNil(SymbolInput.parse("ZNB_NKY"), "要小写前缀")
        XCTAssertEqual(SymbolInput.parse("znga")?.rawValue, "usZNGA", "不带 b_ 的还是美股")
        XCTAssertTrue(SymbolInput.isExplicitCode("znb_NKY"))
        XCTAssertEqual(SymbolInput.parseList("znb_NKY hf_XAU")?.symbols.map(\.rawValue), ["znb_NKY", "hf_XAU"])

        // 编码成新浪的写法，旧版本认不出的会在同步时跳过（见 LossyWatchItem）。
        let data = try JSONEncoder().encode([nikkei])
        XCTAssertEqual(String(data: data, encoding: .utf8), #"["znb_NKY"]"#)
        XCTAssertEqual(try JSONDecoder().decode([Symbol].self, from: data), [nikkei])

        let items = ["sh600519", "hf_XAU", "znb_NKY"].map { WatchItem(symbol: Symbol($0)!) }
        XCTAssertEqual(WatchlistFilter.available(for: items), [.all, .cn, .global])
        XCTAssertEqual(WatchlistFilter.global.apply(items).map(\.symbol.rawValue), ["hf_XAU", "znb_NKY"])
    }

    func testSearchesGlobalIndices() {
        func codes(_ query: String) -> [String] { GlobalCatalog.search(query).map(\.symbol.rawValue) }
        XCTAssertEqual(codes("nikkei"), ["znb_NKY"])
        XCTAssertEqual(codes("日经"), ["znb_NKY"])
        XCTAssertEqual(codes("dax"), ["znb_DAX"])
        XCTAssertEqual(codes("ftse"), ["znb_UKX"])
        XCTAssertEqual(codes("富时"), ["znb_UKX"])
        XCTAssertEqual(codes("kospi"), ["znb_KOSPI"])
        XCTAssertEqual(codes("taiex"), ["znb_TWJQ"])
        XCTAssertEqual(codes("euro stoxx"), ["znb_SX5E"], "英文名的开头")
        XCTAssertEqual(codes("znb_nky"), ["znb_NKY"])
        let result = GlobalCatalog.search("nikkei")[0]
        XCTAssertEqual(result.name, "日经225")
        XCTAssertEqual(result.typeLabel, "指数")
        XCTAssertEqual(GlobalCatalog.entry(for: result.symbol)?.english, "Nikkei 225")
        XCTAssertNil(GlobalCatalog.entry(for: Symbol("sh600519")!))
    }

    private struct Stub: QuoteProvider {
        var quotes: [Symbol: Quote] = [:]
        var error: ProviderError?

        func fetchQuotes(for symbols: [Symbol]) async throws -> [Symbol: Quote] {
            if let error { throw error }
            return quotes
        }

        func search(_ query: String) async throws -> [SearchResult] { [] }
    }

    /// 腾讯的数据源把环球股指交给新浪取，别的照常向腾讯要。
    func testTencentAsksSinaForGlobalIndices() async throws {
        let nikkei = Symbol("znb_NKY")!
        let sina = Stub(quotes: [nikkei: Quote(symbol: nikkei, name: "日经225", price: 2, previousClose: 1)])
        let provider = TencentProvider(quoteEndpoint: "http://127.0.0.1:9/", sina: sina)
        let quotes = try await provider.fetchQuotes(for: [nikkei])
        XCTAssertEqual(quotes[nikkei]?.price, 2)

        // 腾讯取不到时照常报错，交给备用数据源。
        do {
            _ = try await provider.fetchQuotes(for: [nikkei, Symbol("sh600519")!])
            XCTFail("腾讯取不到时应该报错")
        } catch {}
        // 只有环球股指、新浪也取不到时同样报错。
        let failing = TencentProvider(quoteEndpoint: "http://127.0.0.1:9/", sina: Stub(error: .badStatus(403)))
        do {
            _ = try await failing.fetchQuotes(for: [nikkei])
            XCTFail("只有环球股指、新浪取不到时应该报错")
        } catch {
            XCTAssertEqual(error as? ProviderError, .badStatus(403))
        }
    }
}
