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

    func testFixtureLaunchFlagsAreAllowlistedAndStayInTemporaryDefaults() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let defaults = UIFixtureDefaults(file: folder.appendingPathComponent("preferences.plist"))
        for language in ["en", "zh-Hans", "zh-Hant"] {
            let options = UIFixtureLaunchOptions(arguments: ["Fixture", "--fixture-language", language,
                "--fixture-crypto-only", "--fixture-compact", "--fixture-dark", "--sync-enabled"])
            XCTAssertEqual(options.language, language)
            try options.apply(to: defaults)
            let items = try XCTUnwrap(defaults.data(forKey: "watchlist.v1").flatMap(Watchlist.decode))
            XCTAssertEqual(items.count, 3)
            XCTAssertTrue(items.allSatisfy { $0.symbol.isCrypto && $0.holding == nil })
            XCTAssertTrue(defaults.bool(forKey: "list.compact"))
            XCTAssertTrue(defaults.bool(forKey: "tips.dismissed"))
            XCTAssertEqual(defaults.string(forKey: "appearance"), "dark")
            XCTAssertNil(defaults.object(forKey: "sync.enabled"))
            XCTAssertNil(defaults.object(forKey: "AppleLanguages"))
        }
        for arguments in [["--fixture-language", "fr"], ["--fixture-language"], ["--fixture-language=en"],
                          ["--fixture-compact=true", "--fixture-dark=true", "--fixture-crypto-only=true"]] {
            let options = UIFixtureLaunchOptions(arguments: arguments)
            XCTAssertEqual(options, UIFixtureLaunchOptions(arguments: []))
        }
        try UIFixtureLaunchOptions(arguments: []).apply(to: defaults)
        XCTAssertFalse(defaults.bool(forKey: "list.compact"))
        XCTAssertEqual(defaults.string(forKey: "appearance"), "light")
        XCTAssertEqual(defaults.data(forKey: "watchlist.v1").flatMap(Watchlist.decode), UIFixtureProvider.initialItems)
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
        XCTAssertEqual(results.count, UIFixtureProvider.items.count)
        let saved = Set(UIFixtureProvider.initialItems.map(\.symbol))
        XCTAssertTrue(results.contains { saved.contains($0.symbol) })
        XCTAssertTrue(results.contains { !saved.contains($0.symbol) })
    }

    func testExtendedHoursFixturePreservesItsPriceAndFailureControls() async throws {
        let provider = UIFixtureProvider()
        let symbol = Symbol("usAAPL")!
        let quote = try await provider.fetchQuotes(for: [symbol])[symbol]
        let extended = try await provider.fetchExtendedHours(for: symbol, exchangeCode: nil)
        XCTAssertEqual(extended?.session, .afterHours)
        XCTAssertEqual(try XCTUnwrap(extended).price, try XCTUnwrap(quote).price * 1.008)
        XCTAssertNil(extended?.time)
        await provider.setFailure(true)
        do {
            _ = try await provider.fetchExtendedHours(for: symbol, exchangeCode: nil)
            XCTFail("extended-hours fixtures must honor the failure control")
        } catch { XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet) }
    }


    func testCryptoFixturePreservesRollingWindowUnitsPrecisionAndOldTimestamp() async throws {
        let provider = UIFixtureProvider()
        let btc = Symbol("ccBTCUSDT")!, doge = Symbol("ccDOGEUSDT")!, eth = Symbol("ccETHUSDT")!
        let values = try await provider.fetchQuotes(for: [btc, doge, eth])
        let lowPrice = try XCTUnwrap(values[doge])
        XCTAssertEqual(lowPrice.price, 0.087654)
        XCTAssertEqual(lowPrice.priceDecimals, 6)
        XCTAssertEqual(lowPrice.volume, 30_000_000_000)
        XCTAssertEqual(lowPrice.amount, lowPrice.price * lowPrice.volume)
        XCTAssertEqual(values[btc]?.open, values[btc]?.previousClose)
        XCTAssertEqual(values[btc]?.timestamp, UIFixture.date)
        XCTAssertEqual(values[eth]?.timestamp, UIFixture.date.addingTimeInterval(-600))
        XCTAssertFalse(UIFixtureProvider.initialItems.filter { $0.symbol.isCrypto }.contains { $0.holding != nil })
        let received = try await provider.fetchIntraday(for: btc)
        let series = try XCTUnwrap(received)
        XCTAssertEqual(series.start, UIFixture.date.addingTimeInterval(-86400))
        XCTAssertEqual(series.points.first?.minute, 0)
        XCTAssertEqual(series.points.last?.minute, 1440)
        XCTAssertTrue(series.points.allSatisfy { $0.average == nil })
    }

    func testFakeRequestsHonorCancellation() async throws {
        let task = Task { try await UIFixtureProvider().fetchRank(.gainers, count: 40) }
        task.cancel()
        do { _ = try await task.value; XCTFail("canceled fixture request must stop") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}
#endif
