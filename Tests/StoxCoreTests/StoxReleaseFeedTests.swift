import Foundation
import FritCore
import XCTest
@testable import StoxCore

final class StoxReleaseFeedTests: XCTestCase {
    /// 固定旧正式版的附件协议，迁移后旧客户端和新 CLI 仍选择 Stox.zip。
    func testLegacyPublishedReleaseUsesTheSharedParserAndOwnedArchiveSelection() throws {
        let json = #"""
        {"tag_name":"v0.1.0","html_url":"https://github.com/whrss9527/stox/releases/tag/v0.1.0",
         "body":"## 更新内容\n- 行情改进","assets":[
          {"name":"Stox.zip","size":901945,"browser_download_url":"https://github.com/whrss9527/stox/releases/download/v0.1.0/Stox.zip",
           "digest":"sha256:8d8c88b640373163c97c742058047867a3c516c9854c92fc4905aae614c330d2"}]}
        """#
        let records = try XCTUnwrap(ReleaseFeed.parse(Data(json.utf8)))
        let candidate = StoxReleaseFeed.candidate(try XCTUnwrap(ReleaseFeed.newest(records)))
        XCTAssertEqual(candidate.archive?.name, "Stox.zip")
        XCTAssertEqual(candidate.archive?.size, 901_945)
        XCTAssertEqual(candidate.archive?.sha256, "8d8c88b640373163c97c742058047867a3c516c9854c92fc4905aae614c330d2")
        XCTAssertTrue(candidate.canInstall)
    }

    func testTestFeedCannotSelectAnotherOriginOrSiblingDirectory() {
        let source = URL(string: "http://127.0.0.1:8765/feed/latest.json")!
        for url in ["http://127.0.0.1:8766/feed/Stox.zip", "http://127.0.0.1:8765/other/Stox.zip", "http://localhost:8765/feed/Stox.zip"] {
            let release = GitHubRelease(tagName: "v9.9.9", htmlURL: source,
                assets: [.init(name: "Stox.zip", downloadURL: URL(string: url)!, digest: "sha256:" + String(repeating: "a", count: 64))])
            XCTAssertFalse(StoxReleaseFeed.candidate(release, testSource: source).canInstall, url)
        }
        let release = GitHubRelease(tagName: "v9.9.9", htmlURL: source, assets: [
            .init(name: "Stox.zip", downloadURL: URL(string: "http://127.0.0.1:8765/feed/Stox.zip")!, digest: "sha256:" + String(repeating: "a", count: 64))])
        XCTAssertTrue(StoxReleaseFeed.candidate(release, testSource: source).canInstall)
        XCTAssertFalse(StoxReleaseFeed.candidate(release).canInstall)
    }
}
