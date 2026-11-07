#if STOX_UI_FIXTURE
import Foundation
import XCTest
import StoxCore
@testable import Stox

final class UIFixtureAdapterTests: XCTestCase {
    @MainActor
    func testLanguageBundleChangesStringsAndFormattingTogether() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = AppLanguage.bundle
        defer { AppLanguage.bundle = original }
        for language in ["en", "zh-Hans"] {
            let lproj = folder.appendingPathComponent("source/" + language + ".lproj")
            try FileManager.default.createDirectory(at: lproj, withIntermediateDirectories: true)
            try "\"key\" = \"\(language)\";".write(to: lproj.appendingPathComponent("Localizable.strings"), atomically: true, encoding: .utf8)
            let bundle = try UIFixture.languageBundle(language, resources: folder.appendingPathComponent("source"),
                                                      directory: folder.appendingPathComponent("bundles"))
            AppLanguage.bundle = bundle
            XCTAssertEqual(L("key"), language)
            XCTAssertEqual(AppLanguage.isEnglish, language == "en")
            XCTAssertEqual(bundle.preferredLocalizations.first, language)
        }
    }

    func testPreferencesStayInTheTemporaryFixtureFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("preferences.plist")
        let defaults = UIFixtureDefaults(file: file)
        XCTAssertNil(defaults.object(forKey: "AppleLanguages"))
        defaults.set(true, forKey: "bool")
        defaults.set(2.5, forKey: "double")
        defaults.set(7, forKey: "int")
        defaults.set("fixture", forKey: "string")
        defaults.set(Data([1, 2]), forKey: "data")
        XCTAssertEqual(defaults.object(forKey: "bool") as? Bool, true)
        XCTAssertEqual(defaults.double(forKey: "double"), 2.5)
        XCTAssertEqual(defaults.integer(forKey: "int"), 7)
        XCTAssertEqual(defaults.string(forKey: "string"), "fixture")
        XCTAssertEqual(defaults.data(forKey: "data"), Data([1, 2]))
        let saved = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: file), options: [], format: nil) as? [String: Any])
        XCTAssertEqual(saved["bool"] as? Bool, true)
        defaults.removeObject(forKey: "string")
        XCTAssertNil(defaults.string(forKey: "string"))
    }

    func testFakeProviderCanFailAndRecoverWithoutLosingFixtureIdentity() async throws {
        let provider = UIFixtureProvider()
        let symbol = Symbol("sh600519")!
        let first = try await provider.fetchQuotes(for: [symbol])
        XCTAssertEqual(first[symbol]?.price, 1239.58)
        await provider.setFailure(true)
        do {
            _ = try await provider.fetchQuotes(for: [symbol])
            XCTFail("fixture must fail while the failure control is on")
        } catch { XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet) }
        await provider.setFailure(false)
        let restored = try await provider.fetchQuotes(for: [symbol])
        XCTAssertEqual(restored, first)
    }

    func testSearchProvidesExistingAndNewRows() async throws {
        let results = try await UIFixtureProvider().search("fixture")
        XCTAssertEqual(results.count, 8)
        let saved = Set(UIFixtureProvider.items.prefix(5).map(\.symbol))
        XCTAssertTrue(results.contains { saved.contains($0.symbol) })
        XCTAssertTrue(results.contains { !saved.contains($0.symbol) })
    }

    func testFakeRequestsHonorCancellation() async throws {
        let task = Task { try await UIFixtureProvider().fetchRank(.gainers, count: 40) }
        task.cancel()
        do { _ = try await task.value; XCTFail("canceled fixture request must stop") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}
#endif
