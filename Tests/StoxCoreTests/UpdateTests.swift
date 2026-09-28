import XCTest
@testable import StoxCore

final class UpdateTests: XCTestCase {
    /// 2026-09-28 发布的 v0.1.0 的接口返回（节选）。
    private let releaseJSON = #"""
    {"tag_name":"v0.1.0","name":"Stox v0.1.0","draft":false,"prerelease":false,
     "html_url":"https://github.com/whrss9527/stox/releases/tag/v0.1.0",
     "published_at":"2026-09-28T08:00:05Z","body":"## 安装\n\n1. 下载 Stox.zip",
     "assets":[{"name":"Stox.zip","size":901945,"content_type":"application/zip",
                "browser_download_url":"https://github.com/whrss9527/stox/releases/download/v0.1.0/Stox.zip",
                "digest":"sha256:8d8c88b640373163c97c742058047867a3c516c9854c92fc4905aae614c330d2"}]}
    """#

    func testParseRelease() throws {
        let release = try XCTUnwrap(UpdateCheck.parse(Data(releaseJSON.utf8)))
        XCTAssertEqual(release.version, "0.1.0")
        XCTAssertEqual(release.tag, "v0.1.0")
        XCTAssertEqual(release.archiveName, "Stox.zip")
        XCTAssertEqual(release.archiveSize, 901_945)
        XCTAssertEqual(release.archiveURL?.absoluteString, "https://github.com/whrss9527/stox/releases/download/v0.1.0/Stox.zip")
        XCTAssertEqual(release.archiveSHA256, "8d8c88b640373163c97c742058047867a3c516c9854c92fc4905aae614c330d2")
        XCTAssertNil(release.checksumsURL)
        XCTAssertTrue(release.canInstall, "只有 GitHub 的附件摘要也能校验")
        XCTAssertEqual(release.publishedAt, ISO8601DateFormatter().date(from: "2026-09-28T08:00:05Z"))
        XCTAssertTrue(release.notes.hasPrefix("## 安装"))
    }

    func testParseWithChecksumsFile() throws {
        let json = #"""
        {"tag_name":"v9.9.9","html_url":"http://127.0.0.1:8765/latest.json",
         "assets":[{"name":"Stox.zip","size":10,"browser_download_url":"http://127.0.0.1:8765/Stox.zip"},
                   {"name":"SHA256SUMS.txt","size":80,"browser_download_url":"http://127.0.0.1:8765/SHA256SUMS.txt"}]}
        """#
        let release = try XCTUnwrap(UpdateCheck.parse(Data(json.utf8)))
        XCTAssertEqual(release.version, "9.9.9")
        XCTAssertEqual(release.checksumsURL?.absoluteString, "http://127.0.0.1:8765/SHA256SUMS.txt")
        XCTAssertNil(release.archiveSHA256)
        XCTAssertTrue(release.canInstall)
    }

    func testReleasesWithoutArchiveCannotBeInstalled() throws {
        let json = #"{"tag_name":"v1.0.0","html_url":"https://example.com","assets":[{"name":"notes.txt","browser_download_url":"https://example.com/n"}]}"#
        let release = try XCTUnwrap(UpdateCheck.parse(Data(json.utf8)))
        XCTAssertFalse(release.canInstall)
        XCTAssertNil(UpdateCheck.parse(Data(#"{"tag_name":"v2.0.0","prerelease":true}"#.utf8)))
        XCTAssertNil(UpdateCheck.parse(Data("not json".utf8)))
    }

    func testVersionComparison() {
        XCTAssertTrue(UpdateCheck.isNewer("0.2.0", than: "0.1.0"))
        XCTAssertTrue(UpdateCheck.isNewer("v0.10.0", than: "0.9.9"))
        XCTAssertTrue(UpdateCheck.isNewer("1.0", than: "0.9.9"))
        XCTAssertTrue(UpdateCheck.isNewer("1.0.1", than: "1.0"))
        XCTAssertTrue(UpdateCheck.isNewer("1.0.0", than: "1.0.0-beta"))
        XCTAssertFalse(UpdateCheck.isNewer("1.0.0-beta", than: "1.0.0"))
        XCTAssertFalse(UpdateCheck.isNewer("0.1.0", than: "0.1.0"))
        XCTAssertFalse(UpdateCheck.isNewer("0.1.0", than: "0.2.0"))
    }

    func testChecksums() {
        let text = """
        8d8c88b640373163c97c742058047867a3c516c9854c92fc4905aae614c330d2  Stox.zip
        8D8C88B640373163C97C742058047867A3C516C9854C92FC4905AAE614C330D2 *Stox Beta.zip
        not-a-hash  other.zip
        """
        let parsed = Checksums.parse(text)
        XCTAssertEqual(parsed["Stox.zip"], "8d8c88b640373163c97c742058047867a3c516c9854c92fc4905aae614c330d2")
        XCTAssertEqual(parsed["Stox Beta.zip"], "8d8c88b640373163c97c742058047867a3c516c9854c92fc4905aae614c330d2")
        XCTAssertNil(parsed["other.zip"])
    }

    func testInstallPlan() {
        let applications = URL(fileURLWithPath: "/Applications", isDirectory: true)
        let userApplications = URL(fileURLWithPath: "/Users/me/Applications", isDirectory: true)
        let folders = [applications, userApplications]
        let installed = URL(fileURLWithPath: "/Applications/Stox.app")

        // 平常：原地替换。
        XCTAssertEqual(
            InstallLocation.plan(bundle: installed, translocated: false, original: nil, readOnly: false, folders: folders, canWrite: { _ in true }),
            InstallPlan(target: installed, trashAfter: nil, relocating: false)
        )
        // 不是 .app（swift run）：没法更新。
        XCTAssertNil(InstallLocation.plan(bundle: URL(fileURLWithPath: "/tmp/debug/Stox"), translocated: false, original: nil,
                                          readOnly: false, folders: folders, canWrite: { _ in true }))

        let translocated = URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/ABC/d/Stox.app")
        // 在“应用程序”里但带着隔离标记被搬走：原地替换原来的位置。
        XCTAssertEqual(
            InstallLocation.plan(bundle: translocated, translocated: true, original: installed, readOnly: true, folders: folders, canWrite: { _ in true }),
            InstallPlan(target: installed, trashAfter: nil, relocating: false)
        )
        // 在下载文件夹里直接打开：装进“应用程序”，旧的移到废纸篓。
        let downloads = URL(fileURLWithPath: "/Users/me/Downloads/Stox.app")
        XCTAssertEqual(
            InstallLocation.plan(bundle: translocated, translocated: true, original: downloads, readOnly: true, folders: folders, canWrite: { _ in true }),
            InstallPlan(target: installed, trashAfter: downloads, relocating: true)
        )
        // “应用程序”不可写时换成个人的 ~/Applications。
        XCTAssertEqual(
            InstallLocation.plan(bundle: translocated, translocated: true, original: downloads, readOnly: true, folders: folders,
                                 canWrite: { $0.path == userApplications.path }),
            InstallPlan(target: userApplications.appendingPathComponent("Stox.app"), trashAfter: downloads, relocating: true)
        )
    }
}

final class ReleaseNotesTests: XCTestCase {
    func testKeepsOnlyTheHighlights() {
        let notes = """
        ## 更新内容

        - 五日分时
        - 键盘操作

        ## 安装

        1. 下载 Stox.zip
        2. 拖进应用程序

        ## What's Changed
        * Add a five-day intraday chart by @whrss9527 in https://github.com/whrss9527/stox/pull/13

        **Full Changelog**: https://github.com/whrss9527/stox/compare/v0.10.0...v0.11.0
        """
        XCTAssertEqual(ReleaseNotesText.highlights(notes), "- 五日分时\n- 键盘操作")
    }

    func testOlderNotesDropInstallSteps() {
        let notes = "## 安装\r\n\r\n1. 下载\r\n\r\n## What's Changed\r\n* Add holdings by @whrss9527\r\n\r\n**Full Changelog**: https://x"
        XCTAssertEqual(ReleaseNotesText.highlights(notes), "")
        XCTAssertEqual(ReleaseNotesText.highlights("修复了一些问题"), "修复了一些问题", "没有标题的说明原样显示")
        let release = ReleaseInfo(version: "0.13.0", tag: "v0.13.0", pageURL: URL(string: "https://github.com")!, notes: "## 更新内容\n- 筛选")
        XCTAssertEqual(release.highlights, "- 筛选")
        XCTAssertEqual(UpdateCheck.releaseURL(version: "0.16.0")?.absoluteString,
                       "https://api.github.com/repos/whrss9527/stox/releases/tags/v0.16.0")
    }
}
