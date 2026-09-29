import SwiftUI
import StoxCore

/// 盈亏日历：一个月一页，每个交易日一格，格子里是那天收盘后记下的今日盈亏，赚（亏）得越多底色越深。
/// 几种货币的持仓分开看；下面是这个月的合计和赚、亏的天数。数据就是“盈亏记录”，只在这台 Mac 上。
@MainActor
struct ProfitCalendarPanel: View {
    @EnvironmentObject private var store: QuoteStore
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var router: PanelRouter

    /// 看的是哪种货币；nil 是有记录的第一种。
    @State private var region: MarketRegion?
    /// 看的是哪个月：年 × 12 + 月 − 1；nil 是有记录的最后一个月。
    @State private var monthIndex: Int?

    static let cellHeight: CGFloat = 36
    private static let spacing: CGFloat = 3

    var body: some View {
        VStack(spacing: 10) {
            header
            if let region = shownRegion {
                content(region)
                    .padding(10)
                    .glassCard()
            } else {
                Text("还没有盈亏记录：填了持仓以后，每个交易日收盘后会记一笔")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .frame(maxWidth: .infinity)
                    .frame(height: 100)
                    .glassCard()
            }
            HStack {
                Spacer()
                Button("返回") { router.route = .list }
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.regular)
            .padding(.horizontal, 2)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                router.route = .list
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(IconButtonStyle())
            .help("返回（Esc）")
            VStack(alignment: .leading, spacing: 2) {
                Text("盈亏日历")
                    .font(.system(size: 14, weight: .semibold))
                Text("每个交易日收盘后记下的今日盈亏，只在这台 Mac 上")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(10)
        .glassCard(prominent: true)
    }

    /// 有记录的货币里选中的那一种。
    private var shownRegion: MarketRegion? {
        let regions = store.profitHistory.regions
        if let region, regions.contains(region) { return region }
        return regions.first
    }

    /// 这种货币正在看的月份，落在有记录的范围里。
    private func shownMonth(_ region: MarketRegion) -> Int {
        let now = Calendar(identifier: .gregorian).dateComponents(in: region.timeZone, from: Date())
        let current = (now.year ?? 2026) * 12 + (now.month ?? 1) - 1
        guard let range = ProfitCalendar.monthRange(of: store.profitHistory, region: region) else { return current }
        return min(max(monthIndex ?? range.upperBound, range.lowerBound), range.upperBound)
    }

    @ViewBuilder
    private func content(_ region: MarketRegion) -> some View {
        let regions = store.profitHistory.regions
        let index = shownMonth(region)
        let range = ProfitCalendar.monthRange(of: store.profitHistory, region: region)
        let calendar = ProfitCalendar(history: store.profitHistory, region: region, year: index / 12, month: index % 12 + 1)
        VStack(spacing: 8) {
            if regions.count > 1 {
                Picker("货币", selection: Binding(get: { region }, set: { self.region = $0; monthIndex = nil })) {
                    ForEach(regions, id: \.self) { region in
                        Text(region.currencyName).tag(region)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            HStack {
                Button {
                    monthIndex = index - 1
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(IconButtonStyle())
                .disabled(range.map { index <= $0.lowerBound } ?? true)
                .help("上一个月")
                Spacer()
                Text(calendar.title)
                    .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                Spacer()
                Button {
                    monthIndex = index + 1
                } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(IconButtonStyle())
                .disabled(range.map { index >= $0.upperBound } ?? true)
                .help("下一个月")
            }
            grid(calendar, today: ProfitHistory.day(of: Date(), region: region))
            summary(calendar)
        }
    }

    /// today 是这个市场今天的日期，那一格描一圈边。
    private func grid(_ calendar: ProfitCalendar, today: String) -> some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: Self.spacing), count: 7)
        let scale = calendar.largestMagnitude
        return LazyVGrid(columns: columns, spacing: Self.spacing) {
            ForEach(ProfitCalendar.weekdayTitles.indices, id: \.self) { index in
                Text(ProfitCalendar.weekdayTitles[index])
                    .font(.system(size: 10))
                    .foregroundStyle(index >= 5 ? HierarchicalShapeStyle.tertiary : HierarchicalShapeStyle.secondary)
                    .frame(maxWidth: .infinity)
            }
            ForEach(0..<calendar.leadingBlanks, id: \.self) { _ in
                Color.clear.frame(height: Self.cellHeight)
            }
            ForEach(calendar.cells) { cell in
                self.cell(cell, scale: scale, isToday: cell.date == today)
            }
        }
    }

    private func cell(_ cell: ProfitCalendar.Cell, scale: Double?, isToday: Bool) -> some View {
        let profit = cell.dayProfit
        let color = Theme.priceColor(for: PriceDirection(profit ?? 0), convention: settings.colorConvention)
        // 底色深浅按这个月赚（亏）得最多的那天比。
        let strength = profit.flatMap { value in scale.map { $0 > 0 ? min(abs(value) / $0, 1) : 0 } } ?? 0
        return VStack(alignment: .leading, spacing: 0) {
            Text("\(cell.day)")
                .font(.system(size: 9.5).monospacedDigit())
                .foregroundStyle(cell.isWeekend ? HierarchicalShapeStyle.tertiary : HierarchicalShapeStyle.secondary)
            Spacer(minLength: 0)
            if let profit, !settings.hideAmounts {
                Text(Self.signedCompact(profit))
                    .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
        }
        .padding(.horizontal, 3)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: Self.cellHeight)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(profit == nil ? Color.primary.opacity(0.03) : color.opacity(0.08 + 0.3 * strength))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(isToday ? 0.8 : 0), lineWidth: 1)
        )
        .help(profit.map { "\(cell.date) 今日盈亏 " + amount(QuoteFormatter.signedMoney($0)) } ?? "\(cell.date) 没有记录")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(cell.day) 日")
        .accessibilityValue(profit.map { "今日盈亏 " + amount(QuoteFormatter.signedMoney($0)) } ?? "没有记录")
    }

    private func summary(_ calendar: ProfitCalendar) -> some View {
        HStack(spacing: 8) {
            if let total = calendar.total {
                Text("本月 " + amount(QuoteFormatter.signedMoney(total)))
                    .foregroundStyle(Theme.priceColor(for: PriceDirection(total), convention: settings.colorConvention))
                Text("赚 \(calendar.profitDays) 天 · 亏 \(calendar.lossDays) 天")
                    .foregroundStyle(.secondary)
            } else {
                Text("这个月没有记录")
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 11).monospacedDigit())
        .lineLimit(1)
    }

    /// 隐藏金额时是 ****。
    private func amount(_ text: String) -> String {
        settings.hideAmounts ? QuoteFormatter.hiddenAmount : text
    }

    /// 格子里的数写短一点：`+688`、`-1.23万`。
    static func signedCompact(_ value: Double) -> String {
        let sign = value >= 0.005 ? "+" : (value <= -0.005 ? "-" : "")
        return sign + QuoteFormatter.compactMoney(abs(value))
    }

    /// CI 用：现在这个月（有记录的第一种货币）记了几天。
    static func recordedDaysThisMonth(store: QuoteStore) -> Int {
        guard let region = store.profitHistory.regions.first else { return 0 }
        let now = Calendar(identifier: .gregorian).dateComponents(in: region.timeZone, from: Date())
        return ProfitCalendar(history: store.profitHistory, region: region, year: now.year ?? 0, month: now.month ?? 0)
            .recordedDays.count
    }
}
