import Foundation

/// 只解析 Stox 的制表符表格。解析与预览不修改持仓，确认后一次应用本机改动。
public struct TableImport: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case holdings, trades }
    public enum Mode: Hashable, Sendable { case merge, replace }
    public struct Row: Equatable, Sendable, Identifiable {
        public var line: Int
        public var symbol: Symbol
        public var name: String
        public var holding: Holding?
        public var group: String?
        public var hasGroup: Bool
        public var trade: Trade?
        public var id: Int { line }
    }
    public struct Problem: Equatable, Sendable, Identifiable {
        public var line: Int
        public var message: String
        public var id: Int { line }
    }
    public enum Failure: Error {
        case invalidPreview, tooManyTrades(Symbol)
        public var message: String {
            switch self {
            case .invalidPreview: return L("请先修正表格中的错误行")
            case .tooManyTrades(let symbol): return L("%@ 合并后超过 %@ 笔交易，请减少记录或选择替换", symbol.displayCode, Trade.limit)
            }
        }
    }
    public var kind: Kind
    public var rows: [Row]
    public var problems: [Problem]
    public var duplicates: Int
    public var canImport: Bool { !rows.isEmpty && problems.isEmpty }

    private enum Column: Hashable { case name, symbol, currency, shares, cost, group, day, side, price, profit, fee, bonus }
    private static let headers: [String: Column] = [
        "名称": .name, "名稱": .name, "name": .name,  // l10n-ignore
        "代码": .symbol, "代碼": .symbol, "代號": .symbol, "symbol": .symbol, "code": .symbol,  // l10n-ignore
        "币种": .currency, "幣種": .currency, "currency": .currency,  // l10n-ignore
        "持有": .shares, "股数": .shares, "股數": .shares, "shares": .shares,  // l10n-ignore
        "成本价": .cost, "成本價": .cost, "cost": .cost, "cost price": .cost,  // l10n-ignore
        "分组": .group, "分組": .group, "group": .group,  // l10n-ignore
        "日期": .day, "date": .day, "类型": .side, "類型": .side, "type": .side,  // l10n-ignore
        "价格": .price, "價格": .price, "price": .price,  // l10n-ignore
        "已实现盈亏": .profit, "已實現盈虧": .profit, "realized p&l": .profit,  // l10n-ignore
        "费用": .fee, "費用": .fee, "fees": .fee,  // l10n-ignore
        "每股送转": .bonus, "每股送轉": .bonus, "bonus per share": .bonus,  // l10n-ignore
    ]

    public static func parse(_ text: String) -> TableImport {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var result = TableImport(kind: .holdings, rows: [], problems: [], duplicates: 0)
        guard let first = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { return result }
        let cells = lines[first].replacingOccurrences(of: "\u{feff}", with: "").components(separatedBy: "\t")
        var columns: [Column: Int] = [:]
        for (index, cell) in cells.enumerated() {
            guard let column = headers[cell.trimmingCharacters(in: .whitespaces).lowercased()] else { continue }
            guard columns[column] == nil else {
                result.problems.append(Problem(line: first + 1, message: L("表头包含重复列")))
                return result
            }
            columns[column] = index
        }
        result.kind = columns[.day] != nil || columns[.side] != nil ? .trades : .holdings
        let required: [Column] = result.kind == .holdings ? [.symbol, .shares, .cost] : [.symbol, .day, .side, .shares, .price]
        guard required.allSatisfy({ columns[$0] != nil }) else {
            result.problems.append(Problem(line: first + 1, message: L("持仓表需要代码、持有、成本价；交易表需要代码、日期、类型、股数、价格")))
            return result
        }
        guard lines.dropFirst(first + 1).filter({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }).count <= 1000 else {
            result.problems.append(Problem(line: first + 1, message: L("一次最多导入 1000 行，请分批粘贴")))
            return result
        }
        for index in (first + 1)..<lines.count {
            let line = lines[index]
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let values = line.components(separatedBy: "\t")
            func value(_ column: Column) -> String {
                guard let position = columns[column], position < values.count else { return "" }
                return values[position].trimmingCharacters(in: .whitespaces)
            }
            func number(_ column: Column) -> Double? {
                Double(value(column)).flatMap { $0.isFinite ? $0 : nil }
            }
            func problem(_ message: String) { result.problems.append(Problem(line: index + 1, message: message)) }
            guard values.count <= cells.count else { problem(L("列数多于表头，请使用制表符分隔")); continue }
            guard let symbol = SymbolInput.parse(value(.symbol)), symbol.canHold else { problem(L("无法识别可持仓的证券代码")); continue }
            if columns[.currency] != nil, value(.currency).uppercased() != symbol.market.region.currency {
                problem(L("币种与证券代码不符，请使用带市场前缀的代码")); continue
            }
            guard let shares = number(.shares), shares > 0 else { problem(L("股数必须是大于 0 的有限数字")); continue }
            var row = Row(line: index + 1, symbol: symbol, name: value(.name), holding: nil,
                          group: WatchItem.normalizedGroup(value(.group)), hasGroup: columns[.group] != nil, trade: nil)
            if value(.group).count > WatchItem.groupNameLimit { problem(L("分组名最多 %@ 个字", WatchItem.groupNameLimit)); continue }
            if result.kind == .holdings {
                guard let cost = number(.cost), cost >= 0, (shares * cost).isFinite else { problem(L("成本价必须是不小于 0 的有限数字")); continue }
                row.holding = Holding(shares: shares, cost: cost)
                if let previous = result.rows.first(where: { $0.symbol == symbol }) {
                    if previous.holding == row.holding && previous.name == row.name && previous.group == row.group { result.duplicates += 1 }
                    else { problem(L("同一证券的持仓内容不一致，请保留一行")) }
                    continue
                }
            } else {
                let day = value(.day)
                guard let date = KlineCalendar.date(from: day, region: symbol.market.region),
                      ProfitHistory.day(of: date, region: symbol.market.region) == day else { problem(L("日期请写成有效的 YYYY-MM-DD")); continue }
                var side: Trade.Side?
                var embeddedBonus: Double?
                let kind = value(.side).lowercased()
                switch kind {
                case "buy", "买入", "買入": side = .buy  // l10n-ignore
                case "sell", "卖出", "賣出": side = .sell  // l10n-ignore
                case "dividend", "分红", "分紅": side = .dividend  // l10n-ignore
                default: side = nil
                }
                let decorations = [("分红（每股送转 ", "）"), ("分紅（每股送轉 ", "）"), ("dividend (bonus ", " per share)")]  // l10n-ignore
                if let (prefix, suffix) = decorations.first(where: { kind.hasPrefix($0.0) && kind.hasSuffix($0.1) }),
                   let parsed = Double(kind.dropFirst(prefix.count).dropLast(suffix.count)), parsed >= 0, parsed.isFinite {
                    side = .dividend
                    embeddedBonus = parsed
                }
                guard let side, let price = number(.price), price >= 0, (shares * price).isFinite else { problem(L("类型应为买入、卖出或分红，价格必须不小于 0")); continue }
                let fee = value(.fee).isEmpty ? nil : number(.fee)
                let bonus = value(.bonus).isEmpty ? embeddedBonus : number(.bonus)
                let profit = value(.profit).isEmpty ? nil : number(.profit)
                guard (value(.fee).isEmpty || fee.map { $0 >= 0 } == true),
                      (value(.bonus).isEmpty || bonus.map { $0 >= 0 && side == .dividend } == true),
                      (value(.profit).isEmpty || (profit != nil && side != .buy)),
                      (embeddedBonus == nil || bonus == embeddedBonus),
                      (shares * (bonus ?? 0)).isFinite else { problem(L("费用、送转或已实现盈亏数值无效")); continue }
                let realized = profit ?? (side == .dividend ? shares * price - (fee ?? 0) : nil)
                row.trade = Trade(side: side, shares: shares, price: price, day: day, profit: realized, bonus: bonus, fee: fee)
                if result.rows.contains(where: { $0.symbol == symbol && $0.trade == row.trade }) { result.duplicates += 1; continue }
                if result.rows.filter({ $0.symbol == symbol }).count >= Trade.limit { problem(L("每只证券最多导入 %@ 笔交易", Trade.limit)); continue }
            }
            result.rows.append(row)
        }
        return result
    }

    /// 替换只清除全部已有持仓或已知交易日志；自选、提醒、备注与未知交易保留。
    /// 日志导入不重放买卖，不改变当前持仓；需要恢复持仓时单独导入持仓表。
    public func applying(to items: [WatchItem], mode: Mode) throws -> [WatchItem] {
        guard canImport else { throw Failure.invalidPreview }
        var result = items
        if mode == .replace {
            for index in result.indices {
                if kind == .holdings { result[index].holding = nil }
                else { result[index].trades = [] }
            }
        }
        for row in rows {
            if !result.contains(where: { $0.symbol == row.symbol }) { result.append(WatchItem(symbol: row.symbol, name: row.name)) }
            let index = result.firstIndex { $0.symbol == row.symbol }!
            if !row.name.isEmpty { result[index].name = row.name }
            if let holding = row.holding {
                result[index].holding = holding
                if row.hasGroup { result[index].group = row.group }
            }
            if let trade = row.trade, !result[index].trades.contains(trade) { result[index].trades.append(trade) }
        }
        for index in result.indices where kind == .trades {
            guard result[index].trades.count <= Trade.limit else { throw Failure.tooManyTrades(result[index].symbol) }
            result[index].trades = result[index].trades.enumerated().sorted {
                $0.element.day == $1.element.day ? $0.offset < $1.offset : $0.element.day < $1.element.day
            }.map(\.element)
        }
        return result
    }
}
