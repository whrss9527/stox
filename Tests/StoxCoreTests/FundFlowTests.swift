import XCTest
@testable import StoxCore

final class FundFlowTests: XCTestCase {
    /// 2026-09-29 11:29 取的贵州茅台（分时只留了开头、午休前和中间几分钟）。
    private let moutai = """
    {"code":0,"msg":"ok","data":{"todayFundFlow":{"desc":"逐笔统计当日成交买卖单，把资金划分为主力和散户，其中主力=超大单+大单。",\
    "stockCode":"sh600519","mainNetIn":"248174709","mainIn":"1139175994","mainInRate":"29","mainOut":"891001285","mainOutRate":"23",\
    "retailIn":"829955812","retailInRate":"21","retailOut":"1078130521","retailOutRate":"27","superFlow":"274928373","bigFlow":"-26753664",\
    "normalFlow":"-248063453","smallFlow":"-111256","rank":"","summary":{"mcRatio":"0.02","rank":"10/5571",\
    "s0":"主力净流入额市场排名10/5571，占流通市值比例0.02%；今日净流入较近5日净流入的均值增加42028.15万元。"}},\
    "todayFundTrend":{"stockCode":"sh600519","minList":[\
    {"time":"202609290931","Price":"1243.51","MainNetInflow":"23408549","RetailNetInflow":"-23408549"},\
    {"time":"202609290930","Price":"1241.74","MainNetInflow":"18315130","RetailNetInflow":"-18315130"},\
    {"time":"202609291000","Price":"1233.50","MainNetInflow":"68822117"},\
    {"time":"202609291129","Price":"1235.68","MainNetInflow":"248174709"}]},\
    "fiveDayFundFlow":{"fiveDayMainNetIn":"-860533857","DayMainNetInList":[{"date":"2026-09-21","mainNetIn":"-26867603"},\
    {"date":"2026-09-22","mainNetIn":"-82789480"},{"date":"2026-09-23","mainNetIn":"-55665636"},{"date":"2026-09-24","mainNetIn":"-518627683"},\
    {"date":"2026-09-28","mainNetIn":"-176583455"}]},"historyFundFlow":null,"activeFlow":null,"prec":"2","insCode":"","ffHide":""}}
    """

    /// 同一时间的沪深 300ETF：没有排名，小结开头多一个逗号。
    private let etf = """
    {"code":0,"msg":"ok","data":{"todayFundFlow":{"stockCode":"sh510300","mainNetIn":"-158223893","mainIn":"658208297","mainOut":"816432190",\
    "retailIn":"362025116","retailOut":"203801224","superFlow":"-266828709","bigFlow":"108604817","normalFlow":"74921719","smallFlow":"83302173",\
    "rank":"","summary":{"mcRatio":"0.15","rank":"","s0":"，占流通市值比例0.15%；连续4日净流出；今日净流入较近5日净流入的均值增加31238.44万元。"}},\
    "todayFundTrend":null,"fiveDayFundFlow":null,"historyFundFlow":null,"activeFlow":null,"prec":"2","insCode":"","ffHide":""}}
    """

    func testParsesTodayTrendAndPreviousDays() throws {
        let flow = try XCTUnwrap(TencentFundFlow.parse(Data(moutai.utf8)))
        XCTAssertEqual(flow.mainNetInflow, 248_174_709)
        XCTAssertEqual(flow.mainInflow - flow.mainOutflow, flow.mainNetInflow, "主力净流入是流入减流出")
        XCTAssertEqual(flow.retailInflow, 829_955_812)
        XCTAssertEqual(flow.retailOutflow, 1_078_130_521)
        XCTAssertEqual(flow.superNet + flow.bigNet, flow.mainNetInflow, "主力是超大单加大单")
        XCTAssertEqual(flow.mediumNet, -248_063_453)
        XCTAssertEqual(flow.smallNet, -111_256)
        XCTAssertEqual(flow.rank, FundFlow.Rank(position: 10, total: 5571))
        XCTAssertEqual(flow.note?.hasPrefix("主力净流入额市场排名10/5571"), true)
        XCTAssertEqual(flow.direction, .up)

        XCTAssertEqual(flow.trend.map(\.minute), [570, 571, 600, 689], "按时间排好，分钟数和分时图一样")
        XCTAssertEqual(flow.trend.first?.mainNetInflow, 18_315_130)
        XCTAssertEqual(flow.trend.first?.price, 1241.74)
        XCTAssertEqual(flow.trend.last?.mainNetInflow, flow.mainNetInflow, "最后一分钟的累计就是当天的合计")

        XCTAssertEqual(flow.days.map(\.date), ["2026-09-21", "2026-09-22", "2026-09-23", "2026-09-24", "2026-09-28"])
        XCTAssertEqual(try XCTUnwrap(flow.daysTotal), -860_533_857, "和接口给的 fiveDayMainNetIn 一致")
    }

    func testETFHasNoRank() throws {
        let flow = try XCTUnwrap(TencentFundFlow.parse(Data(etf.utf8)))
        XCTAssertEqual(flow.mainNetInflow, -158_223_893)
        XCTAssertNil(flow.rank)
        XCTAssertEqual(flow.note, "占流通市值比例0.15%；连续4日净流出；今日净流入较近5日净流入的均值增加31238.44万元。", "去掉开头的逗号")
        XCTAssertTrue(flow.trend.isEmpty)
        XCTAssertTrue(flow.days.isEmpty)
        XCTAssertNil(flow.daysTotal)
        XCTAssertNil(flow.trendRange)
        XCTAssertEqual(flow.direction, .down)
    }

    func testMissingOrFailedResponses() {
        let empty = #"{"code":0,"msg":"ok","data":{"todayFundFlow":null,"todayFundTrend":null,"fiveDayFundFlow":null}}"#
        XCTAssertNil(TencentFundFlow.parse(Data(empty.utf8)), "没有当天的合计")
        XCTAssertNil(TencentFundFlow.parse(Data(#"{"code":-1,"msg":"param error","data":null}"#.utf8)))
        XCTAssertNil(TencentFundFlow.parse(Data("v_pv_none_match=\"1\";".utf8)))
    }

    func testOnlyAShareStocksAndETFs() throws {
        XCTAssertTrue(TencentFundFlow.supports(Symbol("sh600519")!))
        XCTAssertTrue(TencentFundFlow.supports(Symbol("sh510300")!))
        XCTAssertTrue(TencentFundFlow.supports(Symbol("sz300750")!))
        XCTAssertFalse(TencentFundFlow.supports(Symbol("sh000001")!), "指数没有")
        XCTAssertFalse(TencentFundFlow.supports(Symbol("hk00700")!))
        XCTAssertFalse(TencentFundFlow.supports(Symbol("usAAPL")!))
        XCTAssertFalse(TencentFundFlow.supports(Symbol("jj161725")!))
        XCTAssertNil(TencentFundFlow.url(for: Symbol("hk00700")!))

        let url = try XCTUnwrap(TencentFundFlow.url(for: Symbol("sh600519")!))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(url.host, "proxy.finance.qq.com")
        XCTAssertEqual(items.first { $0.name == "code" }?.value, "sh600519")
        XCTAssertEqual(items.first { $0.name == "type" }?.value, "todayFundFlow,todayFundTrend,fiveDayFundFlow")
    }

    func testTrendRangeAndHover() throws {
        let flow = FundFlow(mainNetInflow: 30, trend: [
            FundFlowPoint(minute: 570, mainNetInflow: -20),
            FundFlowPoint(minute: 690, mainNetInflow: 10),
            FundFlowPoint(minute: 780, mainNetInflow: 50),
            FundFlowPoint(minute: 900, mainNetInflow: 30),
        ])
        XCTAssertEqual(flow.trendRange, -20...50)
        XCTAssertEqual(FundFlow(mainNetInflow: 5, trend: [FundFlowPoint(minute: 570, mainNetInflow: 5)]).trendRange, 0...5, "总是包含 0")
        // 横轴只有交易时段：11:30 和 13:00 在同一个位置（120），15:00 在最右边（240）。
        XCTAssertEqual(flow.point(nearest: 0)?.minute, 570)
        XCTAssertEqual(flow.point(nearest: 119)?.minute, 690)
        XCTAssertEqual(flow.point(nearest: 200)?.minute, 900)
    }

    func testSignedLargeNumber() {
        XCTAssertEqual(QuoteFormatter.signedLargeNumber(248_174_709), "+2.48亿")
        XCTAssertEqual(QuoteFormatter.signedLargeNumber(-26_753_664), "-2675.37万")
        XCTAssertEqual(QuoteFormatter.signedLargeNumber(-111_256), "-11.13万")
        XCTAssertEqual(QuoteFormatter.signedLargeNumber(-5000), "-5000")
        XCTAssertEqual(QuoteFormatter.signedLargeNumber(0.2), "0")
    }
}
