import XCTest
@testable import StoxCore

/// 走势图上的提醒线：提醒的价格怎么折算，线旁边的字怎么摆。
final class ChartLevelTests: XCTestCase {
    private let maotai = Symbol("sh600519")!
    private let alert = PriceAlert(priceAbove: 1300, priceBelow: 1100, riseAbove: 5, fallBelow: 3, profitAbove: 10, lossBelow: 8)
    private let holding = Holding(shares: 100, cost: 1200)

    func testTurnsEachAlertIntoAPrice() {
        let levels = alert.chartLevels(holding: holding, previousClose: 1250)
        XCTAssertEqual(levels.map(\.kind), [.takeProfit, .riseAbove, .priceAbove, .fallBelow, .stopLoss, .priceBelow], "从高到低")
        let expected = [1320, 1312.5, 1300, 1212.5, 1104, 1100]
        for (level, price) in zip(levels, expected) {
            XCTAssertEqual(level.price, price, accuracy: 1e-9, "\(level.kind)")
        }
        XCTAssertEqual(
            levels.map { $0.label(decimals: 2) },
            ["止盈 1320.00", "提醒 +5.00%", "提醒 1300.00", "提醒 -3.00%", "止损 1104.00", "提醒 1100.00"],
            "涨跌幅提醒写比例，其他的写价格"
        )
        XCTAssertFalse(levels.contains { !$0.isAlert })
        XCTAssertEqual(ChartLevel(kind: .cost, price: 1200).label(decimals: 3), "成本 1200.000")
    }

    func testSkipsWhatCannotBeDrawn() {
        let kline = alert.chartLevels(holding: holding, previousClose: nil)
        XCTAssertEqual(kline.map(\.kind), [.takeProfit, .priceAbove, .stopLoss, .priceBelow], "K 线上不画涨跌幅提醒")
        XCTAssertEqual(alert.chartLevels(holding: nil, previousClose: 0).map(\.kind), [.priceAbove, .priceBelow], "没有持仓、没有昨收")
        XCTAssertEqual(
            alert.chartLevels(holding: Holding(shares: 100, cost: 0), previousClose: nil).map(\.kind), [.priceAbove, .priceBelow],
            "成本价为 0 时算不出止盈止损"
        )
        XCTAssertEqual(
            alert.chartLevels(holding: Holding(shares: 0, cost: 1200), previousClose: nil).map(\.kind), [.priceAbove, .priceBelow],
            "卖光了不算持仓，和提醒时一样"
        )
        let deep = PriceAlert(fallBelow: 120, lossBelow: 100)
        XCTAssertTrue(deep.chartLevels(holding: holding, previousClose: 1250).isEmpty, "折出来的价格不是正数")
        let negative = PriceAlert(riseAbove: -5, profitAbove: -10).chartLevels(holding: holding, previousClose: 1250)
        XCTAssertEqual(negative.map(\.kind), [.takeProfit, .riseAbove], "填成负数的按绝对值算，和提醒时一样")
        XCTAssertEqual(negative.first?.price ?? 0, 1320, accuracy: 1e-9)
        XCTAssertEqual(negative.last?.percent, 5)
        XCTAssertTrue(PriceAlert().chartLevels(holding: holding, previousClose: 1250).isEmpty)
    }

    /// 线画在哪，提醒就在哪触发：价格越过止盈、止损、涨跌幅的那条线才提醒，没到不提醒。
    func testLinesMatchWhereAlertsFire() {
        let levels = alert.chartLevels(holding: holding, previousClose: 1250)
        func price(_ kind: ChartLevel.Kind) -> Double { levels.first { $0.kind == kind }!.price }
        func fires(_ condition: AlertCondition, at price: Double) -> Bool {
            let quote = Quote(symbol: maotai, name: "贵州茅台", price: price, previousClose: 1250)
            return condition.isMet(by: quote, holding: holding, threshold: alert.threshold(for: condition)!)
        }
        let cases: [(ChartLevel.Kind, AlertCondition, Double)] = [
            (.takeProfit, .profitAbove, 1), (.stopLoss, .lossBelow, -1), (.riseAbove, .riseAbove, 1), (.fallBelow, .fallBelow, -1),
            (.priceAbove, .priceAbove, 1), (.priceBelow, .priceBelow, -1),
        ]
        for (kind, condition, side) in cases {
            XCTAssertTrue(fires(condition, at: price(kind) + side * 0.01), "越过\(kind)那条线")
            XCTAssertFalse(fires(condition, at: price(kind) - side * 0.01), "还没到\(kind)那条线")
        }
    }

    func testAddsTheCostLine() {
        let item = WatchItem(symbol: maotai, alert: PriceAlert(priceAbove: 1300, lossBelow: 8), holding: holding)
        XCTAssertEqual(item.chartLevels(previousClose: nil).map(\.kind), [.priceAbove, .cost, .stopLoss])
        XCTAssertEqual(item.chartLevels(previousClose: nil, cost: false).map(\.kind), [.priceAbove, .stopLoss], "关掉成本线")
        XCTAssertEqual(item.chartLevels(previousClose: nil, alerts: false).map(\.kind), [.cost], "关掉提醒线")
        XCTAssertTrue(WatchItem(symbol: maotai).chartLevels(previousClose: 1250).isEmpty)
    }

    func testLabelSitsAboveItsLine() {
        typealias Label = LevelLabelLayout.Label
        let one = [Label(lineY: 30, width: 50, height: 10)]
        XCTAssertEqual(LevelLabelLayout.place(one, width: 300, height: 56, alignment: .center), [.init(x: 125, y: 18)], "线的上面，放在中间")
        XCTAssertEqual(LevelLabelLayout.place(one, width: 300, height: 56, alignment: .trailing), [.init(x: 249, y: 18)], "靠右留一点边")
        XCTAssertEqual(
            LevelLabelLayout.place([Label(lineY: 5, width: 50, height: 10)], width: 300, height: 56, alignment: .center),
            [.init(x: 125, y: 7)], "贴着顶边时写在线的下面"
        )
        XCTAssertEqual(
            LevelLabelLayout.place([Label(lineY: 5, width: 50, height: 10)], width: 300, height: 14, alignment: .center),
            [.init(x: 125, y: 4)], "上下都放不下时不出图"
        )
        XCTAssertTrue(LevelLabelLayout.place([], width: 300, height: 56, alignment: .center).isEmpty)
    }

    func testCloseLabelsShareARow() {
        typealias Label = LevelLabelLayout.Label
        let close = [Label(lineY: 30, width: 50, height: 10), Label(lineY: 34, width: 60, height: 10)]
        XCTAssertEqual(
            LevelLabelLayout.place(close, width: 300, height: 56, alignment: .trailing),
            [.init(x: 185, y: 18), .init(x: 239, y: 22)], "上下叠在一起的并排，整排靠右"
        )
        XCTAssertEqual(
            LevelLabelLayout.place(close, width: 300, height: 56, alignment: .center),
            [.init(x: 93, y: 18), .init(x: 147, y: 22)], "整排放在中间"
        )
        let apart = [Label(lineY: 30, width: 50, height: 10), Label(lineY: 45, width: 60, height: 10)]
        XCTAssertEqual(
            LevelLabelLayout.place(apart, width: 300, height: 56, alignment: .trailing),
            [.init(x: 249, y: 18), .init(x: 239, y: 33)], "离得远的各自靠右"
        )
        // 第一个贴着顶边写到了线的下面，和第二个叠在一起：还是按传进来的顺序从左往右。
        let flipped = [Label(lineY: 5, width: 50, height: 10), Label(lineY: 20, width: 60, height: 10)]
        XCTAssertEqual(
            LevelLabelLayout.place(flipped, width: 300, height: 56, alignment: .trailing),
            [.init(x: 185, y: 7), .init(x: 239, y: 8)]
        )
        // 一个挨一个：第一个和第三个不叠，但都和第二个叠，三个排成一排。
        let chain = [30, 36, 42].map { Label(lineY: Double($0), width: 40, height: 10) }
        let placed = LevelLabelLayout.place(chain, width: 300, height: 56, alignment: .trailing)
        XCTAssertEqual(placed.map(\.x), [171, 215, 259])
        XCTAssertEqual(placed.map(\.y), [18, 24, 30])
        // 一排太宽时从最左边排起。
        let wide = [Label(lineY: 30, width: 200, height: 10), Label(lineY: 31, width: 200, height: 10)]
        XCTAssertEqual(LevelLabelLayout.place(wide, width: 300, height: 56, alignment: .center).map(\.x), [0, 204])
    }
}
