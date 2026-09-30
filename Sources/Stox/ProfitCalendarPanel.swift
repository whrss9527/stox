import SwiftUI
import StoxCore

/// 盈亏日历：一个月一页，每个交易日一格，格子里是那天收盘后记下的今日盈亏，赚（亏）得越多底色越深。
/// 几种货币的持仓分开看；下面是这个月的合计和赚、亏的天数。也可以按年看，每个月一格，点一格回到那个月。
/// 数据就是“盈亏记录”，只在这台 Mac 上。
@MainActor
struct ProfitCalendarPanel: View {
    @EnvironmentObject private var store: QuoteStore
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var router: PanelRouter

    /// 看的是哪种货币；nil 是有记录的第一种。
    @State private var region: MarketRegion?
    /// 看的是哪个月：年 × 12 + 月 − 1；nil 是有记录的最后一个月。
    @State private var monthIndex: Int?
    /// 按年看时看的是哪一年；nil 是有记录的最后一年。
    @State private var yearValue: Int?

    static let cellHeight: CGFloat = 36
    /// 按年看时一个月一格，四列三行。
    static let monthCellHeight: CGFloat = 46
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
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            // 从按月切到按年时看的是正在看的那个月所在的一年。
            Picker("按月或按年", selection: Binding(get: { settings.profitCalendarByYear }, set: { byYear in
                if byYear, let region = shownRegion { yearValue = shownMonth(region) / 12 }
                settings.profitCalendarByYear = byYear
            })) {
                Text("月").tag(false)
                Text("年").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 76)
            .help("按月看每天，或者按年看每个月")
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

    /// 这种货币按年看时看的那一年，落在有记录的范围里。
    private func shownYear(_ region: MarketRegion) -> Int {
        let current = Calendar(identifier: .gregorian).dateComponents(in: region.timeZone, from: Date()).year ?? 2026
        guard let range = ProfitYear.yearRange(of: store.profitHistory, region: region) else { return current }
        return min(max(yearValue ?? range.upperBound, range.lowerBound), range.upperBound)
    }

    @ViewBuilder
    private func content(_ region: MarketRegion) -> some View {
        let regions = store.profitHistory.regions
        VStack(spacing: 8) {
            if regions.count > 1 {
                Picker("货币", selection: Binding(get: { region }, set: { self.region = $0; monthIndex = nil; yearValue = nil })) {
                    ForEach(regions, id: \.self) { region in
                        Text(region.currencyName).tag(region)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            if settings.profitCalendarByYear {
                yearContent(region)
            } else {
                monthContent(region)
            }
        }
    }

    @ViewBuilder
    private func monthContent(_ region: MarketRegion) -> some View {
        let index = shownMonth(region)
        let range = ProfitCalendar.monthRange(of: store.profitHistory, region: region)
        let calendar = ProfitCalendar(history: store.profitHistory, region: region, year: index / 12, month: index % 12 + 1)
        VStack(spacing: 8) {
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

    @ViewBuilder
    private func yearContent(_ region: MarketRegion) -> some View {
        let year = shownYear(region)
        let range = ProfitYear.yearRange(of: store.profitHistory, region: region)
        let profitYear = ProfitYear(history: store.profitHistory, region: region, year: year)
        VStack(spacing: 8) {
            HStack {
                Button {
                    yearValue = year - 1
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(IconButtonStyle())
                .disabled(range.map { year <= $0.lowerBound } ?? true)
                .help("上一年")
                Spacer()
                Text(profitYear.title)
                    .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                Spacer()
                Button {
                    yearValue = year + 1
                } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(IconButtonStyle())
                .disabled(range.map { year >= $0.upperBound } ?? true)
                .help("下一年")
            }
            yearGrid(profitYear, region: region)
            yearSummary(profitYear)
        }
    }

    /// 一年十二个月，四列三行；这个月描一圈边，点一格按月看那个月。
    private func yearGrid(_ year: ProfitYear, region: MarketRegion) -> some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: Self.spacing), count: 4)
        let scale = year.largestMagnitude
        let now = Calendar(identifier: .gregorian).dateComponents(in: region.timeZone, from: Date())
        return LazyVGrid(columns: columns, spacing: Self.spacing) {
            ForEach(year.months) { month in
                Button {
                    monthIndex = year.year * 12 + month.month - 1
                    settings.profitCalendarByYear = false
                } label: {
                    monthCell(month, scale: scale, isCurrent: now.year == year.year && now.month == month.month)
                }
                .buttonStyle(.plain)
                .help(monthHelp(month, year: year.year) + "，点一下看这个月每天的")
            }
        }
    }

    private func monthCell(_ month: ProfitYear.Month, scale: Double?, isCurrent: Bool) -> some View {
        let total = month.total
        let color = Theme.priceColor(for: PriceDirection(total ?? 0), convention: settings.colorConvention)
        // 底色深浅按这一年赚（亏）得最多的那个月比。
        let strength = total.flatMap { value in scale.map { $0 > 0 ? min(abs(value) / $0, 1) : 0 } } ?? 0
        return VStack(alignment: .leading, spacing: 0) {
            Text("\(month.month)月")
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if let total, !settings.hideAmounts {
                Text(Self.signedCompact(total))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: Self.monthCellHeight)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(total == nil ? Color.primary.opacity(0.03) : color.opacity(0.08 + 0.3 * strength))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(isCurrent ? 0.8 : 0), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(month.month) 月")
        .accessibilityValue(month.total.map { "记了 \(month.recordedDays) 天，合计 " + amount(QuoteFormatter.signedMoney($0)) } ?? "没有记录")
    }

    private func monthHelp(_ month: ProfitYear.Month, year: Int) -> String {
        guard let total = month.total else { return "\(year)年\(month.month)月没有记录" }
        return "\(year)年\(month.month)月记了 \(month.recordedDays) 天，合计 " + amount(QuoteFormatter.signedMoney(total))
    }

    private func yearSummary(_ year: ProfitYear) -> some View {
        HStack(spacing: 8) {
            if let total = year.total {
                Text("全年 " + amount(QuoteFormatter.signedMoney(total)))
                    .foregroundStyle(Theme.priceColor(for: PriceDirection(total), convention: settings.colorConvention))
                Text("赚 \(year.profitMonths) 个月 · 亏 \(year.lossMonths) 个月")
                    .foregroundStyle(.secondary)
            } else {
                Text("这一年没有记录")
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 11).monospacedDigit())
        .lineLimit(1)
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

    /// CI 用：今年（有记录的第一种货币）有几个月记过。
    static func recordedMonthsThisYear(store: QuoteStore) -> Int {
        guard let region = store.profitHistory.regions.first else { return 0 }
        let year = Calendar(identifier: .gregorian).dateComponents(in: region.timeZone, from: Date()).year ?? 0
        return ProfitYear(history: store.profitHistory, region: region, year: year).recordedMonths.count
    }

    /// CI 用：现在这个月（有记录的第一种货币）记了几天。
    static func recordedDaysThisMonth(store: QuoteStore) -> Int {
        guard let region = store.profitHistory.regions.first else { return 0 }
        let now = Calendar(identifier: .gregorian).dateComponents(in: region.timeZone, from: Date())
        return ProfitCalendar(history: store.profitHistory, region: region, year: now.year ?? 0, month: now.month ?? 0)
            .recordedDays.count
    }
}
