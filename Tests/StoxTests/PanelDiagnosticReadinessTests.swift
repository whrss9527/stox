import XCTest
@testable import Stox

@MainActor
final class PanelDiagnosticReadinessTests: XCTestCase {
    func testBatchInputNeverWaitsForSingleSearchResults() throws {
        let router = PanelRouter()
        router.searchText = "601318 09988 TSLA 茅台"
        let batch = try XCTUnwrap(router.batch)
        XCTAssertEqual(batch.symbols.count, 3)
        XCTAssertEqual(batch.rejected, ["茅台"])
        XCTAssertFalse(router.waitsForSearchDiagnostics, "批量输入不产生单条搜索结果，不能白等5秒")
        router.searchText = "茅台"
        XCTAssertTrue(router.waitsForSearchDiagnostics, "普通搜索仍等待防抖/网络返回")
        router.clearSearch()
        XCTAssertFalse(router.waitsForSearchDiagnostics)
    }
}
