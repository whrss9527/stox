import Foundation
import FritCore
import FritUpdate
import XCTest
@testable import Stox

private final class ReleaseProtocol: URLProtocol {
    private static let payload = Data(#"""
    {"tag_name":"v9.9.9","html_url":"https://github.com/whrss9527/stox/releases/tag/v9.9.9","assets":[
      {"name":"Stox.zip","browser_download_url":"https://github.com/whrss9527/stox/releases/download/v9.9.9/Stox.zip",
       "digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]}
    """#.utf8)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.payload)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class StoxUpdateIntegrationTests: XCTestCase {
    func testUpdatedCardPreservesListLinesAndInlineMarkdown() {
        let rendered = StoxReleaseNotes.attributed("## **1.6.1**\r\n- **更新器**：保留设置\r\n\r\n* Continue")
        XCTAssertEqual(String(rendered.characters), "1.6.1\n• 更新器：保留设置\n\n• Continue")
        XCTAssertTrue(rendered.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
    }

    @MainActor
    func testSharedUpdaterKeepsLegacySkipAndNotificationPreferences() async throws {
        let name = "stox-update-integration-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let language = FritLocalization.languageOverride
        defer { defaults.removePersistentDomain(forName: name); FritLocalization.languageOverride = language }
        defaults.set("9.9.9", forKey: "update.skippedVersion")
        defaults.set("9.9.9", forKey: "update.notifiedVersion")
        var config = StoxUpdates.configuration(defaults: defaults)
        XCTAssertEqual(config.signer, .sameTeamAsCurrent)
        XCTAssertTrue(config.alsoAccept.isEmpty)
        config.currentVersion = "1.6.0"
        config.log = UpdateLogger(info: { _ in }, error: { _ in })
        config.sessions = { _ in
            let session = URLSessionConfiguration.ephemeral
            session.protocolClasses = [ReleaseProtocol.self]
            return [session]
        }
        let updater = FritUpdate.Updater(configuration: config)
        var notifications = 0
        updater.notify = { _ in notifications += 1 }
        _ = await updater.check(manual: false)
        guard case .skipped = updater.phase else { return XCTFail("旧跳过偏好没有保留") }
        defaults.removeObject(forKey: "update.skippedVersion")
        let candidate = await updater.check(manual: false)
        XCTAssertEqual(candidate?.archive?.name, "Stox.zip")
        XCTAssertTrue(candidate?.canInstall == true)
        XCTAssertEqual(notifications, 0)
        defaults.removeObject(forKey: "update.notifiedVersion")
        _ = await updater.check(manual: false)
        XCTAssertEqual(notifications, 1)
        XCTAssertEqual(defaults.string(forKey: "update.notifiedVersion"), "9.9.9")
    }
}
