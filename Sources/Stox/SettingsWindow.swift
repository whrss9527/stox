import AppKit
import Combine
import SwiftUI
import StoxCore

enum SettingsPage: String, CaseIterable, Identifiable {
    case general
    case display
    case sync
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "通用"
        case .display: return "菜单栏与颜色"
        case .sync: return "iCloud 同步"
        case .about: return "关于与更新"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .display: return "menubar.rectangle"
        case .sync: return "icloud"
        case .about: return "info.circle"
        }
    }
}

@MainActor
final class SettingsNavigation: ObservableObject {
    @Published var page: SettingsPage = .general
}

/// 设置窗口：透明标题栏、全尺寸内容、左侧导航，整个窗口透出桌面的毛玻璃。
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    let navigation = SettingsNavigation()
    private var window: NSWindow?
    private var settings: SettingsStore?
    private var store: QuoteStore?
    private var updater: Updater?
    private var sync: SyncManager?
    private var appearanceSubscription: AnyCancellable?

    func configure(settings: SettingsStore, store: QuoteStore, updater: Updater, sync: SyncManager) {
        self.settings = settings
        self.store = store
        self.updater = updater
        self.sync = sync
        appearanceSubscription = settings.$appearance.sink { [weak self] mode in
            self?.window?.appearance = mode.nsAppearance
        }
    }

    func show(page: SettingsPage?) {
        if let page {
            navigation.page = page
        }
        if window == nil {
            window = makeWindow()
        }
        guard let window else { return }
        // 设置窗口打开期间当普通 App：菜单栏显示编辑菜单，⌘Tab 能切到它；关闭后回到只有菜单栏图标。
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    private func makeWindow() -> NSWindow? {
        guard let settings, let store, let updater, let sync else { return nil }
        let root = SettingsRootView(navigation: navigation, settings: settings, store: store, updater: updater, sync: sync)
        let hosting = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Stox 设置"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.setContentSize(NSSize(width: 760, height: 540))
        window.minSize = NSSize(width: 680, height: 460)
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.appearance = settings.appearance.nsAppearance
        return window
    }

    /// CI 用：打印设置窗口的位置，方便截图裁剪。
    func printDiagnostics() {
        guard let window, window.isVisible else {
            print("STOX_DIAG settings_window=missing")
            fflush(stdout)
            return
        }
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        let frame = window.frame
        print("STOX_DIAG settings_page=\(navigation.page.rawValue)")
        print("STOX_DIAG capture_frame=\(Int(frame.minX)) \(Int(screenHeight - frame.maxY)) \(Int(frame.width)) \(Int(frame.height))")
        fflush(stdout)
    }
}

/// 设置窗口的内容：左侧导航，右侧各页。
@MainActor
struct SettingsRootView: View {
    @ObservedObject var navigation: SettingsNavigation
    let settings: SettingsStore
    let store: QuoteStore
    let updater: Updater
    let sync: SyncManager

    var body: some View {
        NavigationSplitView {
            List(SettingsPage.allCases, selection: pageSelection) { page in
                Label(page.title, systemImage: page.symbol)
                    .tag(page)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
            .safeAreaInset(edge: .top) {
                HStack(spacing: 8) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 28, height: 28)
                    Text("Stox")
                        .font(.system(size: 14, weight: .semibold))
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.top, 34)
                .padding(.bottom, 4)
            }
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(VisualEffectView(material: .underWindowBackground).ignoresSafeArea())
        }
        .frame(minWidth: 680, minHeight: 460)
    }

    private var pageSelection: Binding<SettingsPage?> {
        Binding(get: { navigation.page }, set: { if let page = $0 { navigation.page = page } })
    }

    @ViewBuilder
    private var detail: some View {
        switch navigation.page {
        case .general: GeneralPage(settings: settings)
        case .display: DisplayPage(settings: settings)
        case .sync: SyncPage(sync: sync, store: store)
        case .about: AboutPage(settings: settings, updater: updater)
        }
    }
}

/// 页面标题。
struct PageHeader: View {
    var title: String
    var subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 22, weight: .bold))
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.top, 36)
        .padding(.bottom, 8)
    }
}

/// 表单里的灰色说明文字。
struct FormNote: View {
    var text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - 通用

@MainActor
struct GeneralPage: View {
    @ObservedObject var settings: SettingsStore
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginItemError: String?

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "通用", subtitle: "刷新频率、快捷键、价格提醒和登录时启动")
            Form {
                Section("行情刷新") {
                    Picker("刷新间隔", selection: $settings.refreshInterval) {
                        ForEach(SettingsStore.intervalOptions, id: \.self) { seconds in
                            Text("\(Int(seconds)) 秒").tag(seconds)
                        }
                    }
                    Toggle("休市时降低刷新频率", isOn: $settings.slowWhenIdle)
                    FormNote("自选涉及的市场都休市时改为每分钟刷新一次。打开面板时，数据不新鲜就会立即刷新。")
                }
                Section("快捷键") {
                    Toggle("用快捷键打开或关闭行情面板", isOn: $settings.hotKeyEnabled)
                    HStack {
                        HotkeyRecorder(binding: $settings.toggleHotkey)
                            .frame(width: 160, height: 28)
                        Button("恢复 ⌃⌥S") { settings.toggleHotkey = .defaultToggle }
                            .disabled(settings.toggleHotkey == .defaultToggle)
                    }
                    .disabled(!settings.hotKeyEnabled)
                    if settings.hotKeyEnabled, settings.hotkeyUnavailable {
                        Label("\(settings.toggleHotkey.display) 已经被其他程序占用，换一个组合试试", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    FormNote("点方框后按下新的组合键，至少包含 ⌃、⌥、⇧、⌘ 中的一个，按 Esc 取消。在任何 App 里都能用，不需要辅助功能权限。")
                }
                Section("价格提醒") {
                    Toggle("到价时发送系统通知", isOn: $settings.alertsEnabled)
                    FormNote("在行情面板里右键某只证券，选“价格提醒与简称…”设置目标价、涨跌幅，填了持仓的还能设止盈止损。每个条件每个交易日最多提醒一次。")
                    Toggle("收盘后发一条今日盈亏小结", isOn: $settings.closeSummary)
                        .onChange(of: settings.closeSummary) { enabled in
                            if enabled { Notifier.shared.requestAuthorization() }
                        }
                    FormNote("有持仓的市场收盘后各发一次：今日盈亏、持仓盈亏和市值。美股在盘后开始时发。")
                    Toggle("A 股涨停、跌停时提醒", isOn: $settings.limitAlerts)
                        .onChange(of: settings.limitAlerts) { enabled in
                            if enabled { Notifier.shared.requestAuthorization() }
                        }
                    FormNote("自选里的 A 股个股（不含指数）封涨停或跌停时发一条通知，开板再封板当天不再重复。")
                    Picker("异动提醒", selection: $settings.rapidMoveThreshold) {
                        ForEach(SettingsStore.rapidMoveOptions, id: \.self) { value in
                            Text(value == 0 ? "关闭" : "5 分钟内涨跌 \(Int(value))%").tag(value)
                        }
                    }
                    .onChange(of: settings.rapidMoveThreshold) { value in
                        if value > 0 { Notifier.shared.requestAuthorization() }
                    }
                    FormNote("交易时段里，自选里的证券相对最近 5 分钟的最低点涨了、或者相对最高点跌了超过这个幅度时提醒，同一只同一个方向 15 分钟内只提醒一次。")
                    Button("打开系统的通知设置") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!)
                    }
                }
                Section("启动") {
                    Toggle("登录时自动启动", isOn: launchAtLoginBinding)
                        .disabled(!LoginItem.isAvailable)
                    if let loginItemError {
                        Text(loginItemError)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin },
            set: { enabled in
                do {
                    try LoginItem.setEnabled(enabled)
                    loginItemError = nil
                } catch {
                    loginItemError = "设置失败：\(error.localizedDescription)"
                }
                launchAtLogin = LoginItem.isEnabled
            }
        )
    }
}

// MARK: - 菜单栏与颜色

@MainActor
struct DisplayPage: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "菜单栏与颜色", subtitle: "菜单栏里显示什么，涨跌用什么颜色，面板用深色还是浅色")
            Form {
                Section("外观") {
                    Picker("行情面板和设置窗口", selection: $settings.appearance) {
                        ForEach(AppearanceMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    FormNote("菜单栏里的行情文字始终跟随系统的深浅色，保证看得清。")
                }
                Section("菜单栏") {
                    Toggle("只显示图标，隐藏行情", isOn: $settings.hideTicker)
                    FormNote("右键单击菜单栏里的 Stox 可以随时在“显示行情”和“只显示图标”之间切换，左键单击照常打开行情面板。")
                    Toggle("休市时只显示图标", isOn: $settings.hideTickerWhenClosed)
                        .disabled(settings.hideTicker)
                    FormNote("菜单栏上的证券所在的市场都休市时只显示图标，开盘（包括美股盘前）后自动恢复，晚上不占地方。")
                    Toggle("显示名称", isOn: $settings.showName)
                        .disabled(settings.hideTicker)
                    Toggle("显示价格", isOn: $settings.showPrice)
                        .disabled(settings.hideTicker)
                    Toggle("显示涨跌幅", isOn: $settings.showPercent)
                        .disabled(settings.hideTicker)
                    Toggle("固定了多只时轮流显示", isOn: $settings.rotateTicker)
                        .disabled(settings.hideTicker)
                    Toggle("在菜单栏显示今日盈亏", isOn: $settings.showDayProfit)
                        .disabled(settings.hideTicker)
                    FormNote("在行情面板里右键某只证券，选“显示在菜单栏”就能把它固定到菜单栏。轮流显示时每 5 秒换一只，适合刘海屏。今日盈亏只算填了持仓的证券，几种货币都有时按汇率折成人民币显示一个数，不参与轮流。")
                }
                Section("行情面板") {
                    Toggle("紧凑列表", isOn: $settings.compactRows)
                    FormNote("每只一行：名称、代码、现价和色块排在一起，自选多时一屏能看到更多。持仓盈亏和盘前盘后价在展开后看。")
                    Toggle("价格变动时闪一下", isOn: $settings.flashOnChange)
                    Toggle("画均线和均价线", isOn: $settings.showMovingAverages)
                    FormNote("日 K、周 K、月 K 上画 5、10、20 根的收盘价均线，图的上方写着均线的值，鼠标指着时是那一根的。分时图和五日图上画成交均价（橙色），指数没有。")
                    Toggle("美股盘前盘后价", isOn: $settings.showExtendedHours)
                    FormNote("美股个股不在常规交易时段时，代码旁边显示盘前或盘后的最新价相对收盘的涨跌，详情里有价格和成交时间。每只美股个股要多发一个请求。")
                }
                Section("涨跌颜色") {
                    Picker("涨跌颜色", selection: $settings.colorConvention) {
                        ForEach(ColorConvention.allCases) { convention in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(convention.title)
                                Text(convention.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .tag(convention)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    LabeledContent("预览") {
                        ColorPreview(convention: settings.colorConvention)
                    }
                    FormNote("菜单栏、行情面板和提醒里的颜色都会跟着变。选“不显示红绿”时价格和涨跌幅都用系统默认的文字颜色，只靠正负号区分涨跌。")
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
    }
}

/// 涨跌颜色的预览：一涨一跌两只。
struct ColorPreview: View {
    var convention: ColorConvention

    var body: some View {
        HStack(spacing: 14) {
            sample(name: "茅台", price: "1492.50", change: "+1.25%", direction: .up)
            sample(name: "腾讯", price: "480.20", change: "-0.83%", direction: .down)
        }
        .font(.system(size: 12.5).monospacedDigit())
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.06)))
    }

    private func sample(name: String, price: String, change: String, direction: PriceDirection) -> some View {
        HStack(spacing: 4) {
            Text(name)
            Text(price)
                .foregroundStyle(Color(nsColor: Theme.tickerColor(for: direction, convention: convention)))
            Text(change)
                .foregroundStyle(Color(nsColor: Theme.tickerColor(for: direction, convention: convention)))
        }
    }
}

// MARK: - iCloud 同步

@MainActor
struct SyncPage: View {
    @ObservedObject var sync: SyncManager
    @ObservedObject var store: QuoteStore

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "iCloud 同步", subtitle: "通过 iCloud 云盘在多台 Mac 之间同步自选和设置")
            Form {
                Section("同步") {
                    Toggle("通过 iCloud 同步自选和设置", isOn: toggle)
                        .disabled(!sync.available && !sync.enabled)
                    LabeledContent("状态") { statusView }
                    if sync.enabled, sync.available {
                        HStack {
                            Button("立即同步") {
                                Task { await sync.syncNow() }
                            }
                            .disabled(sync.status == .syncing)
                            Button("在访达中显示") {
                                if let url = sync.fileURL, FileManager.default.fileExists(atPath: url.path) {
                                    NSWorkspace.shared.activateFileViewerSelecting([url])
                                } else if let folder = sync.folderURL {
                                    NSWorkspace.shared.open(folder)
                                }
                            }
                        }
                    }
                    if !sync.available {
                        FormNote("这台 Mac 没有打开 iCloud 云盘。到系统设置里点你的 Apple 账户，进入 iCloud 打开“iCloud 云盘”，再回来开启同步。")
                        Button("打开系统设置") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preferences.AppleIDPrefPane")!)
                        }
                    }
                }
                Section("会同步什么") {
                    FormNote("自选列表的内容和顺序、每只的菜单栏固定、简称、持仓和价格提醒，以及刷新间隔、菜单栏显示内容、涨跌颜色、提醒开关这些设置。")
                    FormNote("“只显示图标”、面板外观、快捷键、登录时启动、自动检查更新只和这台 Mac 有关，不同步。")
                }
                Section("怎么同步") {
                    FormNote("文件放在 iCloud 云盘的 Stox 文件夹里。另一台 Mac 开启同步时会读到它，可以选择用 iCloud 的、用本机的，或者把两边的自选合并。之后任何一台的改动几秒内就会出现在其他 Mac 上，两台同时改动时以晚的为准。")
                    FormNote("第一次开启时系统可能会询问是否允许 Stox 访问 iCloud 云盘，需要允许。")
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .confirmationDialog("iCloud 里已经有自选", isPresented: pendingPresented, titleVisibility: .visible) {
            Button("用 iCloud 的替换本机的") { sync.resolve(.useCloud) }
            Button("合并两边的自选") { sync.resolve(.merge) }
            Button("用本机的覆盖 iCloud") { sync.resolve(.useLocal) }
            Button("取消", role: .cancel) { sync.cancelEnable() }
        } message: {
            Text(pendingMessage)
        }
    }

    private var toggle: Binding<Bool> {
        Binding(
            get: { sync.enabled },
            set: { on in
                if on {
                    Task { await sync.enable() }
                } else {
                    sync.disable()
                }
            }
        )
    }

    /// 对话框关闭时不做事：按钮的动作已经把 pending 清掉了。
    private var pendingPresented: Binding<Bool> {
        Binding(get: { sync.pending != nil }, set: { _ in })
    }

    private var pendingMessage: String {
        guard let remote = sync.pending else { return "" }
        return "来自“\(remote.device)”，更新于 \(Self.dateFormatter.string(from: remote.updatedAt))，"
            + "有 \(remote.content.watchlist.count) 只自选；本机现在有 \(store.items.count) 只。要怎么处理？"
    }

    @ViewBuilder
    private var statusView: some View {
        switch sync.status {
        case .off:
            Text("未开启")
                .foregroundStyle(.secondary)
        case .unavailable:
            Label("iCloud 云盘没有打开", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        case .syncing:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("正在同步…")
                    .foregroundStyle(.secondary)
            }
        case .synced(let date, let device):
            VStack(alignment: .trailing, spacing: 2) {
                Label("已同步", systemImage: "checkmark.icloud")
                Text("最近一次改动来自“\(device)”，\(Self.relative(date))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .error(let message):
            VStack(alignment: .trailing, spacing: 6) {
                Label(message, systemImage: "xmark.icloud")
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.trailing)
                Button("打开隐私设置") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")!)
                }
                .controlSize(.small)
                Text("如果拒绝过访问 iCloud 云盘，在“文件和文件夹”里允许 Stox 访问。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - 关于与更新

@MainActor
struct AboutPage: View {
    @ObservedObject var settings: SettingsStore
    let updater: Updater

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "关于与更新", subtitle: "Stox 菜单栏行情")
            ScrollView {
                VStack(spacing: 16) {
                    aboutCard
                    optionsCard
                }
                .padding(24)
            }
        }
    }

    private var aboutCard: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 88, height: 88)
                .shadow(color: .black.opacity(0.2), radius: 12, y: 6)
            Text("Stox")
                .font(.system(size: 20, weight: .bold))
            Text("版本 \(AppInfo.version)")
                .foregroundStyle(.secondary)
            Text("菜单栏里的股票行情：A 股、港股、美股，一键打开，一键关闭。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 360)
            HStack(spacing: 10) {
                Button("GitHub") { NSWorkspace.shared.open(AppInfo.repositoryURL) }
                Button("反馈问题") { NSWorkspace.shared.open(AppInfo.issuesURL) }
            }
            Divider()
                .padding(.horizontal, 40)
            UpdateSection(updater: updater)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .glassCard(cornerRadius: 20)
    }

    private var optionsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("自动检查更新", isOn: $settings.autoCheckUpdates)
            FormNote("启动后和之后每 6 小时检查一次 GitHub 上的新版本。有新版本时发通知，行情面板底部会出现“更新”按钮，点一下自动下载、校验、替换并重新启动，不会自动安装。")
            Divider()
            HStack {
                FormNote("行情数据来自腾讯财经公开接口，仅供参考，港股延时约 15 分钟。")
                Spacer()
                Button("打开日志") {
                    if FileManager.default.fileExists(atPath: Log.fileURL.path) {
                        NSWorkspace.shared.activateFileViewerSelecting([Log.fileURL])
                    } else {
                        NSWorkspace.shared.open(Log.directory)
                    }
                }
                .controlSize(.small)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 16)
    }
}
