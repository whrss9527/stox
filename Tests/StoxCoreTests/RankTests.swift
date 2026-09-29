import XCTest
@testable import StoxCore

final class RankTests: XCTestCase {
    // 2026-09-29 10:08 从腾讯涨跌榜接口抓取的真实返回（节选，每只只留了用到的字段和几个别的）。
    static let gainers = #"""
    {"code":0,"msg":"ok","data":{"rank_list":[
    {"code":"sz301716","hsl":"51.82","name":"N鸿富诚","stock_type":"GP-A-CYB","turnover":"380275","zd":"502.02","zdf":"653.16","zxj":"578.88"},
    {"code":"bj920779","hsl":"16.77","name":"武汉蓝电","stock_type":"GP","turnover":"8730","zd":"4.44","zdf":"20.32","zxj":"26.29"},
    {"code":"sz301513","hsl":"13.13","name":"尚水智能","stock_type":"GP-A-CYB","turnover":"12835","zd":"8.57","zdf":"20.00","zxj":"51.42"},
    {"code":"xx000000","name":"认不出","zxj":"1.00"},
    {"code":"sh600000","name":"没有现价","zxj":"0.00"}
    ],"offset":0,"total":5571}}
    """#

    func testURL() {
        XCTAssertEqual(TencentRank.url(.gainers, count: 20)?.absoluteString,
                       "https://proxy.finance.qq.com/cgi/cgi-bin/rank/hs/getBoardRankList?_appver=11.17.0&board_code=aStock&sort_type=priceRatio&direct=down&offset=0&count=20")
        XCTAssertTrue(TencentRank.url(.losers, count: 20)?.absoluteString.contains("sort_type=priceRatio&direct=up") == true)
        XCTAssertTrue(TencentRank.url(.turnover, count: 5)?.absoluteString.contains("sort_type=turnover&direct=down&offset=0&count=5") == true)
    }

    func testParse() throws {
        let entries = TencentRank.parse(Data(Self.gainers.utf8))
        XCTAssertEqual(entries.map(\.symbol.rawValue), ["sz301716", "bj920779", "sz301513"], "认不出的代码、没有现价的跳过")
        let first = try XCTUnwrap(entries.first)
        XCTAssertEqual(first.name, "N鸿富诚")
        XCTAssertEqual(first.price, 578.88)
        XCTAssertEqual(first.change, 502.02)
        XCTAssertEqual(first.changePercent, 653.16)
        XCTAssertEqual(first.amount, 3_802_750_000, "成交额是万元")
        XCTAssertEqual(first.turnoverRate, 51.82)
        XCTAssertEqual(first.direction, .up)
        XCTAssertTrue(first.isNewListing)
        XCTAssertFalse(entries[1].isNewListing)
        XCTAssertTrue(RankEntry(symbol: Symbol("sh688001")!, name: "C华兴", price: 1, change: 0, changePercent: 0, amount: 0).isNewListing)
    }

    // 同一时间抓取的行业榜（节选）。
    static let industries = #"""
    {"code":0,"msg":"ok","data":{"rank_list":[
    {"code":"pt01801180","hsl":"2.03","lzg":{"code":"sh600657","name":"信达地产","zd":"0.31","zdf":"10.10","zxj":"3.38"},"name":"房地产","stock_type":"BK-HY-1","zd":"53.41","zdf":"2.79","zxj":"1970.05"},
    {"code":"pt01801760","lzg":{"code":"sz300785","name":"值得买","zd":"3.46","zdf":"10.32","zxj":"36.98"},"name":"传媒","zdf":"1.67","zxj":"666.93"},
    {"code":"pt01801720","name":"建筑装饰","zdf":"0.77"},
    {"code":"pt0","name":"","zdf":"1"}
    ],"offset":0,"total":31}}
    """#

    func testIndustries() throws {
        XCTAssertEqual(TencentRank.url(.industries, count: 40)?.absoluteString,
                       "https://proxy.finance.qq.com/cgi/cgi-bin/rank/pt/getRank?board_type=hy&sort_type=priceRatio&direct=down&offset=0&count=40")
        let industries = TencentRank.parseIndustries(Data(Self.industries.utf8))
        XCTAssertEqual(industries.map(\.name), ["房地产", "传媒", "建筑装饰"], "没有名字的跳过")
        let first = try XCTUnwrap(industries.first)
        XCTAssertEqual(first.code, "pt01801180")
        XCTAssertEqual(first.changePercent, 2.79)
        XCTAssertEqual(first.direction, .up)
        XCTAssertEqual(first.leader?.symbol.rawValue, "sh600657")
        XCTAssertEqual(first.leader?.name, "信达地产")
        XCTAssertEqual(first.leader?.changePercent, 10.10)
        XCTAssertNil(industries[2].leader, "没有领涨股")
        XCTAssertEqual(TencentRank.parse(Data(Self.industries.utf8)), [], "板块代码不是股票代码")
    }

    func testBadResponses() {
        XCTAssertEqual(TencentRank.parse(Data(#"{"code":12,"msg":"rpc name invalid"}"#.utf8)), [])
        XCTAssertEqual(TencentRank.parse(Data("<html>502</html>".utf8)), [])
        XCTAssertEqual(TencentRank.parse(Data(#"{"code":0,"data":{"rank_list":[]}}"#.utf8)), [])
    }
}
