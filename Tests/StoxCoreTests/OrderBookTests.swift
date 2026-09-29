import XCTest
@testable import StoxCore

final class OrderBookTests: XCTestCase {
    private func levels(_ book: OrderBook?, _ side: KeyPath<OrderBook, [OrderBook.Level]>) -> [[Double]] {
        (book?[keyPath: side] ?? []).map { [$0.price, $0.volume] }
    }

    func testTencentAShares() throws {
        let quotes = TencentQuoteParser.parse(Fixtures.aShares)
        let moutai = try XCTUnwrap(quotes[Symbol("sh600519")!]?.orderBook)
        XCTAssertEqual(levels(moutai, \.bids), [[1238.92, 100], [1238.91, 100], [1238.86, 100], [1238.85, 100], [1238.83, 600]],
                       "买一到买五，量从手换算成股")
        XCTAssertEqual(levels(moutai, \.asks), [[1239.48, 200], [1239.49, 200], [1239.59, 300], [1239.62, 100], [1239.67, 100]])
        XCTAssertEqual(moutai.outerVolume, 1_190_000)
        XCTAssertEqual(moutai.innerVolume, 1_063_700)
        XCTAssertEqual(moutai.bidVolume, 1000)
        XCTAssertEqual(moutai.askVolume, 900)
        XCTAssertEqual(try XCTUnwrap(moutai.imbalance), 100.0 / 1900 * 100, accuracy: 1e-9)
        XCTAssertEqual(moutai.maxVolume, 600)

        let bank = try XCTUnwrap(quotes[Symbol("sz000001")!]?.orderBook)
        XCTAssertEqual(bank.bids.first, OrderBook.Level(price: 11.29, volume: 160_100))
        XCTAssertEqual(bank.asks.last, OrderBook.Level(price: 11.34, volume: 210_800))
        XCTAssertEqual(try XCTUnwrap(bank.imbalance), 20.31, accuracy: 0.01, "和接口第 74 位的委比一致")

        let etf = try XCTUnwrap(quotes[Symbol("sh510300")!]?.orderBook)
        XCTAssertEqual(etf.bids.first, OrderBook.Level(price: 4.416, volume: 114_000), "ETF 也有五档")
        XCTAssertEqual(etf.asks.count, 5)
    }

    func testStarMarketVolumesAreShares() throws {
        let quotes = TencentQuoteParser.parse(Fixtures.starAndChiNext)
        let star = try XCTUnwrap(quotes[Symbol("sh688981")!])
        XCTAssertEqual(star.volume, 64_392, "科创板的成交量本来就是股")
        XCTAssertEqual(star.amount, 7_506_175)
        XCTAssertEqual(star.amount / star.volume, star.price, accuracy: 0.01, "成交额除以成交量是价格")
        let starBook = try XCTUnwrap(star.orderBook)
        XCTAssertEqual(starBook.outerVolume, 52_736)
        XCTAssertEqual(starBook.innerVolume, 11_656)
        XCTAssertEqual(starBook.bids.first, OrderBook.Level(price: 116.57, volume: 1400), "挂单量仍然是手")
        XCTAssertEqual(starBook.asks.last, OrderBook.Level(price: 116.85, volume: 300))

        let chiNext = try XCTUnwrap(quotes[Symbol("sz300750")!])
        XCTAssertEqual(chiNext.volume, 541_700, "创业板是手")
        XCTAssertEqual(chiNext.amount / chiNext.volume, chiNext.price, accuracy: 0.01)
        XCTAssertEqual(chiNext.orderBook?.outerVolume, 447_600)
        XCTAssertEqual(chiNext.orderBook?.bids.first, OrderBook.Level(price: 291, volume: 800))

        XCTAssertTrue(TencentQuoteParser.isStar(Symbol("sh689009")!, fields: []), "没有类别时看代码")
        XCTAssertFalse(TencentQuoteParser.isStar(Symbol("sz300750")!, fields: []))
    }

    func testOnlyAShareStocksHaveOne() throws {
        let aShares = TencentQuoteParser.parse(Fixtures.aShares)
        XCTAssertNil(aShares[Symbol("sh000001")!]?.orderBook, "指数没有盘口")
        let suspended = try XCTUnwrap(aShares[Symbol("bj830799")!]?.orderBook, "停牌的有盘口，只是空的")
        XCTAssertTrue(suspended.isEmpty)
        XCTAssertNil(suspended.imbalance)
        XCTAssertEqual(suspended.maxVolume, 0)

        let hongKong = TencentQuoteParser.parse(Fixtures.hongKong)
        XCTAssertNil(hongKong[Symbol("hk00700")!]?.orderBook, "港股的买一卖一只是现价")
        let unitedStates = TencentQuoteParser.parse(Fixtures.unitedStates)
        XCTAssertNil(unitedStates[Symbol("usAAPL")!]?.orderBook)
    }

    func testSina() throws {
        let symbols = ["sh600519", "sh000001", "sh510300", "hk00700"].compactMap(Symbol.init)
        let quotes = SinaQuoteParser.parse(SinaTests.sample, symbols: symbols)
        let moutai = try XCTUnwrap(quotes[Symbol("sh600519")!]?.orderBook)
        XCTAssertEqual(levels(moutai, \.bids), [[1243.77, 100], [1243.75, 100], [1243.57, 100], [1243.5, 200], [1243.47, 100]],
                       "新浪每档先量后价，量已经是股")
        XCTAssertEqual(levels(moutai, \.asks), [[1243.88, 319], [1243.9, 2000], [1243.91, 1000], [1243.92, 900], [1243.93, 100]])
        XCTAssertNil(moutai.outerVolume, "新浪没有内外盘")
        XCTAssertEqual(quotes[Symbol("sh510300")!]?.orderBook?.bids.first, OrderBook.Level(price: 4.417, volume: 1_329_100))
        XCTAssertNil(quotes[Symbol("sh000001")!]?.orderBook)
        XCTAssertNil(quotes[Symbol("hk00700")!]?.orderBook)
    }

    func testLevelsStopAtTheFirstEmptyPrice() {
        // 集合竞价时第一档是虚拟成交价和匹配量，第二档的价格是 0、量是未匹配量。
        let pairs: [(price: Double?, volume: Double?)] = [(1243.88, 177), (0, 7), (0, 0), (nil, nil), (0, 0)]
        XCTAssertEqual(OrderBook.levels(pairs, volumeScale: 100), [OrderBook.Level(price: 1243.88, volume: 17_700)])
        XCTAssertEqual(OrderBook.levels([(12.5, -3)], volumeScale: 1), [OrderBook.Level(price: 12.5, volume: 0)], "量不会是负数")
    }

    func testLimitUpAndDepth() {
        let bids = (0..<7).map { OrderBook.Level(price: 11 - Double($0) * 0.01, volume: 100) }
        let limitUp = OrderBook(bids: bids, asks: [])
        XCTAssertEqual(limitUp.bids.count, OrderBook.depth, "每边最多五档")
        XCTAssertEqual(limitUp.imbalance, 100, "涨停时卖盘空了，委比 100%")
        let limitDown = OrderBook(bids: [], asks: [OrderBook.Level(price: 9, volume: 5000)])
        XCTAssertEqual(limitDown.imbalance, -100)
        XCTAssertFalse(limitDown.isEmpty)
    }
}
