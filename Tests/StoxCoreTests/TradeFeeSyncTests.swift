import XCTest
@testable import StoxCore

final class TradeFeeSyncTests: XCTestCase {
    /// 0.50.2–1.0.4 的 Trade 字段及类型，不认识费用交易标签。
    private struct LegacyTrade: Codable {
        enum Side: String, Codable { case buy, sell, dividend }
        var side: Side
        var shares: Double
        var price: Double
        var day: String
        var profit: Double?
        var bonus: Double?
    }

    func testFeesSurviveLegacyDecodeEditAndEncode() throws {
        let holding = Holding(shares: 100, cost: 10)
        let records = [
            Trade(side: .buy, shares: 100, price: 10, day: "2026-09-28"),
            Trade(side: .buy, shares: 50, price: 12, day: "2026-09-29", fee: 5),
            Trade.sell(20, at: 13, from: holding, day: "2026-09-29", fee: 2),
            Trade.dividend(cash: 0.5, bonus: 0.1, holding: holding, day: "2026-09-29", fee: 3),
        ]
        // 使用 #74 的原始保留机制，模拟旧客户端对有费用记录的读写。
        var legacy = try JSONDecoder().decode(PreservingArray<LegacyTrade>.self, from: JSONEncoder().encode(records))
        XCTAssertEqual(legacy.values.count, 1)
        XCTAssertEqual(legacy.unknown.map(\.index), [1, 2, 3])
        legacy.values[0].price = 11
        let restored = try JSONDecoder().decode([Trade].self, from: JSONEncoder().encode(legacy))
        XCTAssertEqual(restored[0].price, 11)
        XCTAssertEqual(Array(restored.dropFirst()), Array(records.dropFirst()))
    }

    func testLegacyRecordsHaveNoFeeAndKeepLegacyTypes() throws {
        let raw = Data(#"{"side":"buy","shares":100,"price":10,"day":"2026-09-29"}"#.utf8)
        let trade = try JSONDecoder().decode(Trade.self, from: raw)
        XCTAssertNil(trade.fee)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(trade)) as? [String: Any])
        XCTAssertEqual(json["side"] as? String, "buy")
        XCTAssertNil(json["fee"])
        XCTAssertNoThrow(try JSONDecoder().decode(LegacyTrade.self, from: JSONEncoder().encode(trade)))
    }

    func testExplicitZeroFeeAlsoSurvivesLegacyRoundTrip() throws {
        let trade = Trade(side: .buy, shares: 10, price: 12, day: "2026-09-29", fee: 0)
        let legacy = try JSONDecoder().decode(PreservingArray<LegacyTrade>.self, from: JSONEncoder().encode([trade]))
        XCTAssertTrue(legacy.values.isEmpty)
        let restored = try JSONDecoder().decode([Trade].self, from: JSONEncoder().encode(legacy))
        XCTAssertEqual(restored, [trade])
    }

    func testFeeTradesSurviveWatchlistBackupAndSyncMerge() throws {
        let trade = Trade.sell(20, at: 13, from: Holding(shares: 100, cost: 10), day: "2026-09-29", fee: 2)
        let item = WatchItem(symbol: Symbol("sh600519")!, holding: Holding(shares: 80, cost: 10), trades: [trade])
        XCTAssertEqual(Watchlist.decode(try XCTUnwrap(Watchlist.encode([item]))), [item])
        let base = SyncDocument(updatedAt: Date(timeIntervalSince1970: 100), device: "A",
                                content: SyncContent(watchlist: [item, WatchItem(symbol: Symbol("usAAPL")!)],
                                                     settings: SyncedSettings()))
        var local = base, remote = base
        local.updatedAt.addTimeInterval(10)
        local.content.watchlist[0].note = "local"
        remote.updatedAt.addTimeInterval(20)
        remote.content.watchlist[1].alias = "remote"
        let merged = SyncMerge.threeWay(base: base.content, local: local, remote: remote)
        let roundTrip = try SyncDocument.decode(merged.encoded())
        XCTAssertEqual(roundTrip.content.watchlist[0].trades, [trade])
        XCTAssertEqual(roundTrip.content.watchlist[0].note, "local")
        XCTAssertEqual(roundTrip.content.watchlist[1].alias, "remote")
    }

    func testMalformedFeesStayOpaqueInsteadOfDroppingRecords() throws {
        for fee: Any in [-1, "bad", NSNull()] {
            let raw = try JSONSerialization.data(withJSONObject: [["side": "buy-fee-v1", "shares": 10, "price": 12,
                                                                   "day": "2026-09-29", "fee": fee]])
            let records = try JSONDecoder().decode(PreservingArray<Trade>.self, from: raw)
            XCTAssertTrue(records.values.isEmpty)
            XCTAssertEqual(records.unknown.count, 1)
            XCTAssertEqual(try JSONDecoder().decode(PreservedJSON.self, from: JSONEncoder().encode(records)),
                           try JSONDecoder().decode(PreservedJSON.self, from: raw))
        }
    }

    func testInvalidFeeAmountsCannotBeSaved() {
        for fee in [-1.0, Double.infinity, Double.nan] {
            XCTAssertThrowsError(try JSONEncoder().encode(Trade(side: .buy, shares: 10, price: 12,
                                                               day: "2026-09-29", fee: fee)))
        }
    }

    func testFutureFeeVersionIsPreservedAsOpaqueJSON() throws {
        let raw = Data(#"[{"side":"buy-fee-v2","shares":10,"price":12,"day":"2026-09-29","fee":5,"extra":{"keep":true}}]"#.utf8)
        let records = try JSONDecoder().decode(PreservingArray<Trade>.self, from: raw)
        XCTAssertTrue(records.values.isEmpty)
        XCTAssertEqual(records.unknown.count, 1)
        XCTAssertEqual(try JSONDecoder().decode(PreservedJSON.self, from: JSONEncoder().encode(records)),
                       try JSONDecoder().decode(PreservedJSON.self, from: raw))
    }
}
