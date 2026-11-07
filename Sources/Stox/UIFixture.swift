#if STOX_UI_FIXTURE
import AppKit
import SwiftUI
import StoxCore

/// Compile-time-only adapters. The controls below open the production panel and settings.
/// Build with scripts/build-ui-fixture.sh; this code is absent from release builds.
enum UIFixture {
    static let root = FileManager.default.temporaryDirectory.appendingPathComponent("StoxUIFixture-" + UUID().uuidString, isDirectory: true)
    static let defaults = UIFixtureDefaults(file: root.appendingPathComponent("preferences.plist"))
    static let provider = UIFixtureProvider()
    static let date = ISO8601DateFormatter().date(from: "2026-11-06T06:00:00Z")!
    @MainActor static var clock: QuoteStoreClock { QuoteStoreClock(now: { date }) }

    @MainActor static func prepare() {
        precondition(Bundle.main.bundleIdentifier == "io.github.whrss9527.stox.uifixture20261107"
                     && Bundle.main.object(forInfoDictionaryKey: "StoxUIFixture") as? Bool == true,
                     "UI fixture must run inside its separate, network-disabled app bundle")
        defaults.set(false, forKey: "update.autoCheck")
        defaults.set(false, forKey: "sync.enabled")
        defaults.set(false, forKey: "alertsEnabled")
        defaults.set(false, forKey: "closeSummary")
        defaults.set(false, forKey: "hotKeyEnabled")
        defaults.set(false, forKey: "slowWhenIdle")
        defaults.set(true, forKey: "tipsDismissed")
        defaults.set(true, forKey: "showAllocation")
        defaults.set(try! JSONEncoder().encode(Array(UIFixtureProvider.items.prefix(5))), forKey: "watchlist.v1")
        applyLanguage("en")
        print("STOX_UI_FIXTURE root=\(root.path) network=app-sandbox-denied provider=fake")
        fflush(stdout)
    }

    @MainActor static func applyLanguage(_ language: String) {
        guard let resources = Bundle.main.resourceURL,
              let bundle = try? languageBundle(language, resources: resources, directory: root.appendingPathComponent("languages")) else { return }
        AppLanguage.bundle = bundle
        defaults.set([language], forKey: InterfaceLanguage.defaultsKey)
        #if !APP_STORE
        _ = StoxUpdates.configuration(defaults: defaults)
        #endif
    }

    /// An lproj alone reports English as preferredLocalizations, even for Chinese.
    /// A complete temporary bundle keeps production number/date formatting in the chosen language too.
    static func languageBundle(_ language: String, resources: URL, directory: URL) throws -> Bundle {
        let target = directory.appendingPathComponent(language + ".bundle", isDirectory: true)
        let contents = target.appendingPathComponent("Contents", isDirectory: true)
        if !FileManager.default.fileExists(atPath: target.path) {
            let translations = contents.appendingPathComponent("Resources", isDirectory: true)
            try FileManager.default.createDirectory(at: translations, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: resources.appendingPathComponent(language + ".lproj"),
                                            to: translations.appendingPathComponent(language + ".lproj"))
            let info: [String: Any] = ["CFBundleIdentifier": "stox.fixture.language." + language,
                                       "CFBundleDevelopmentRegion": language, "CFBundleLocalizations": [language],
                                       "CFBundlePackageType": "BNDL"]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: contents.appendingPathComponent("Info.plist"))
        }
        guard let bundle = Bundle(url: target) else { throw CocoaError(.fileReadCorruptFile) }
        return bundle
    }
}

/// Never reads or writes a CFPreferences domain. Every fixture model uses this adapter.
final class UIFixtureDefaults: UserDefaults, @unchecked Sendable {
    private let file: URL
    private var values: [String: Any] = [:]
    private let lock = NSRecursiveLock()
    init(file: URL) {
        self.file = file
        super.init(suiteName: "StoxUIFixture-" + UUID().uuidString)!
    }
    override func object(forKey key: String) -> Any? {
        lock.lock(); defer { lock.unlock() }
        return values[key]
    }
    override func set(_ value: Any?, forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        values[key] = value
        if let data = try? PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0) {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
    }
    override func removeObject(forKey key: String) { set(nil, forKey: key) }
    override func string(forKey key: String) -> String? { object(forKey: key) as? String }
    override func data(forKey key: String) -> Data? { object(forKey: key) as? Data }
    override func bool(forKey key: String) -> Bool { (object(forKey: key) as? NSNumber)?.boolValue ?? false }
    override func double(forKey key: String) -> Double { (object(forKey: key) as? NSNumber)?.doubleValue ?? 0 }
    override func integer(forKey key: String) -> Int { (object(forKey: key) as? NSNumber)?.intValue ?? 0 }
    override func array(forKey key: String) -> [Any]? { object(forKey: key) as? [Any] }
    override func dictionaryRepresentation() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return values
    }
}

actor UIFixtureProvider: QuoteProvider {
    static let items: [WatchItem] = [
        WatchItem(symbol: Symbol("sh600519")!, name: "贵州茅台", pinned: true, holding: Holding(shares: 10, cost: 1200), group: "示例"), // l10n-ignore: synthetic market data
        WatchItem(symbol: Symbol("hk00700")!, name: "腾讯控股", holding: Holding(shares: 20, cost: 420), group: "示例"), // l10n-ignore: synthetic market data
        WatchItem(symbol: Symbol("usAAPL")!, name: "苹果", holding: Holding(shares: 5, cost: 200)), // l10n-ignore: synthetic market data
        WatchItem(symbol: Symbol("sh000001")!, name: "上证指数"), // l10n-ignore: synthetic market data
        WatchItem(symbol: Symbol("usMSFT")!, name: "微软"), // l10n-ignore: synthetic market data
        WatchItem(symbol: Symbol("sz000858")!, name: "五粮液"), // l10n-ignore: synthetic market data
        WatchItem(symbol: Symbol("usGOOGL")!, name: "Alphabet"),
        WatchItem(symbol: Symbol("hk09988")!, name: "阿里巴巴"), // l10n-ignore: synthetic market data
    ]
    private var fails = false
    func setFailure(_ value: Bool) { fails = value }
    private func delay(_ seconds: Double = 0.25) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        if fails { throw URLError(.notConnectedToInternet) }
    }
    private func quote(_ symbol: Symbol) -> Quote {
        let index = Self.items.firstIndex(where: { $0.symbol == symbol }) ?? 0
        let price = [1239.58, 435.2, 218.4, 3280.12, 415.7, 128.6, 180.3, 85.4][index]
        return Quote(symbol: symbol, name: Self.items[index].name, price: price, previousClose: price / 1.0123,
                     open: price * 0.99, high: price * 1.01, low: price * 0.98, volume: 123456,
                     amount: price * 123456, timestamp: UIFixture.date,
                     englishName: ["sh600519": "Kweichow Moutai", "hk00700": "Tencent", "usAAPL": "Apple", "usMSFT": "Microsoft"][symbol.rawValue])
    }
    func fetchQuotes(for symbols: [Symbol]) async throws -> [Symbol: Quote] {
        try await delay()
        return Dictionary(uniqueKeysWithValues: symbols.map { ($0, quote($0)) })
    }
    func search(_ query: String) async throws -> [SearchResult] {
        try await delay()
        // "fixture" deliberately returns both saved and new symbols for keyboard/add checks.
        return Self.items.filter { query.lowercased() == "fixture" || $0.name.localizedCaseInsensitiveContains(query)
            || $0.symbol.rawValue.localizedCaseInsensitiveContains(query) }
            .map { SearchResult(symbol: $0.symbol, name: $0.name, typeCode: "GP") }
    }
    func fetchIntraday(for symbol: Symbol) async throws -> IntradaySeries? {
        try await delay()
        let price = quote(symbol).price
        let points = (0..<120).map { index in
            IntradayPoint(minute: 570 + index, price: price * (0.99 + Double(index) * 0.00008 + sin(Double(index) / 8) * 0.002),
                          average: price * 0.994, volume: Double(100 + index))
        }
        return IntradaySeries(symbol: symbol, date: "20261106", points: points)
    }
    func fetchKline(for symbol: Symbol, period: KlinePeriod, count: Int, exchangeCode: String?) async throws -> KlineSeries? {
        try await delay()
        let price = quote(symbol).price
        let candles = (1...30).map { index in
            let close = price * (0.94 + Double(index) * 0.002)
            return Candle(date: String(format: "2026-10-%02d", index), open: close * 0.997, close: close,
                          high: close * 1.01, low: close * 0.99, volume: Double(10000 + index * 100))
        }
        return KlineSeries(symbol: symbol, period: period, candles: candles)
    }
    func fetchExchangeRates() async throws -> ExchangeRates? { try await delay(); return ExchangeRates(hkdCNY: 0.92, usdCNY: 7.18) }
    func fetchRank(_ kind: RankKind, count: Int) async throws -> [RankEntry]? {
        try await delay(kind == .gainers ? 1.2 : 0.15)
        return Self.items.filter { $0.symbol.market.region == .cn }.enumerated().map { index, item in
            RankEntry(symbol: item.symbol, name: item.name, price: quote(item.symbol).price,
                      change: kind == .losers ? -2 : 2, changePercent: kind == .losers ? -3.2 : 3.2,
                      amount: Double(index + 1) * 100_000_000, turnoverRate: 1.2)
        }
    }
    func fetchIndustries(count: Int) async throws -> [IndustryEntry]? {
        try await delay(0.15)
        return [IndustryEntry(code: "a", name: "食品饮料", changePercent: 2.34), // l10n-ignore: synthetic market data
                IndustryEntry(code: "b", name: "计算机", changePercent: -1.28)] // l10n-ignore: synthetic market data
    }
}

@MainActor
final class UIFixtureControls {
    private var window: NSWindow!
    init(settings: SettingsStore, store: QuoteStore, sync: SyncManager, controller: StatusItemController) {
        let root = UIFixtureControlView(settings: settings, store: store, controller: controller)
        window = NSWindow(contentViewController: NSHostingController(rootView: root))
        window.title = "Stox UI Fixture — synthetic data, offline"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 520, height: 270))
        window.center()
        window.isReleasedWhenClosed = false
    }
    func show() {
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct UIFixtureControlView: View {
    @ObservedObject var settings: SettingsStore
    let store: QuoteStore
    let controller: StatusItemController
    @State private var language = "en"
    @State private var failure = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(verbatim: "Production UI · fake data adapters · network denied").font(.headline)
            HStack {
                Picker("Language", selection: $language) {
                    Text(verbatim: "English").tag("en")
                    Text(verbatim: "简体中文").tag("zh-Hans") // l10n-ignore: fixture language self-name
                }.onChange(of: language) { value in
                    UIFixture.applyLanguage(value)
                    controller.resetFixturePresentation()
                    SettingsWindowController.shared.resetFixturePresentation()
                }
                Picker("Theme", selection: $settings.appearance) {
                    Text(verbatim: "System").tag(AppearanceMode.system)
                    Text(verbatim: "Light").tag(AppearanceMode.light)
                    Text(verbatim: "Dark").tag(AppearanceMode.dark)
                }
            }
            HStack {
                Button("Watchlist") { show() }
                Button("Rankings") { show(route: .rank) }
                Button("Search") { show(search: "fixture") }
                Button("Details") { show(expand: Symbol("sh600519")) }
            }
            HStack {
                Button("Settings (680px)") { SettingsWindowController.shared.showFixtureMinimum() }
                Toggle("Fail requests", isOn: $failure).onChange(of: failure) { value in
                    Task { await UIFixture.provider.setFailure(value); await store.refresh() }
                }
                Button("Refresh") { Task { await store.refresh() } }
            }
            Text(verbatim: "Preferences, holdings, logs and sync use only this temporary session:\n" + UIFixture.root.path)
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }.padding(20)
    }
    private func show(route: PanelRoute = .list, expand: Symbol? = nil, search: String? = nil) {
        controller.openPanel(route: route, expand: expand, search: search, printDiagnostics: true)
        settings.panelPinned = true
    }
}
#endif
