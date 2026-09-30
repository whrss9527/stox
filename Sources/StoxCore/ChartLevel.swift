import Foundation

/// 走势图上的一条横线：持仓的成本价，或者设了价格提醒、止盈止损时提醒的那个价格。
public struct ChartLevel: Equatable, Sendable {
    public enum Kind: String, Sendable {
        /// 持仓成本价。
        case cost
        /// 价格高于、低于。
        case priceAbove, priceBelow
        /// 涨幅、跌幅达到：按昨收折成价格，只在分时图上画。
        case riseAbove, fallBelow
        /// 止盈、止损：按持仓成本价折成价格。
        case takeProfit, stopLoss
    }

    public var kind: Kind
    public var price: Double
    /// 涨跌幅提醒的比例（%，涨为正、跌为负）：线旁边写它，不写价格。
    public var percent: Double?

    public init(kind: Kind, price: Double, percent: Double? = nil) {
        self.kind = kind
        self.price = price
        self.percent = percent
    }

    /// 是提醒线（不是成本线）。
    public var isAlert: Bool { kind != .cost }

    /// 线旁边写的字：`成本 1200.00`、`提醒 1300.00`、`提醒 +5.00%`、`止盈 1260.00`、`止损 1140.00`。
    public func label(decimals: Int) -> String {
        let price = QuoteFormatter.price(price, decimals: decimals)
        switch kind {
        case .cost: return L("成本 ") + price
        case .priceAbove, .priceBelow: return L("提醒 ") + price
        case .riseAbove, .fallBelow: return L("提醒 ") + QuoteFormatter.percent(percent ?? 0)
        case .takeProfit: return L("止盈 ") + price
        case .stopLoss: return L("止损 ") + price
        }
    }
}

extension PriceAlert {
    /// 提醒的价格，在走势图上各画一条线，按价格从高到低排。
    /// - Parameters:
    ///   - holding: 持仓：设了止盈止损时按成本价折成价格，和提醒时的算法一样（盈亏比例相对成本）。
    ///     没有持仓或成本价为 0 时不画止盈止损。
    ///   - previousClose: 昨收：设了涨跌幅提醒时按它折成价格。K 线上传 nil，不画涨跌幅提醒，它只管今天。
    public func chartLevels(holding: Holding?, previousClose: Double?) -> [ChartLevel] {
        var levels: [ChartLevel] = []
        func add(_ kind: ChartLevel.Kind, _ price: Double, percent: Double? = nil) {
            // 跌幅、止损填到 100% 以上时折出来的价格不是正数，画不出来。
            guard price.isFinite, price > 0 else { return }
            levels.append(ChartLevel(kind: kind, price: price, percent: percent))
        }
        if let priceAbove { add(.priceAbove, priceAbove) }
        if let priceBelow { add(.priceBelow, priceBelow) }
        if let previousClose, previousClose > 0 {
            if let riseAbove { add(.riseAbove, previousClose * (1 + abs(riseAbove) / 100), percent: abs(riseAbove)) }
            if let fallBelow { add(.fallBelow, previousClose * (1 - abs(fallBelow) / 100), percent: -abs(fallBelow)) }
        }
        if let holding, holding.isValid, holding.cost > 0 {
            if let profitAbove { add(.takeProfit, holding.cost * (1 + abs(profitAbove) / 100)) }
            if let lossBelow { add(.stopLoss, holding.cost * (1 - abs(lossBelow) / 100)) }
        }
        return levels.sorted { $0.price > $1.price }
    }
}

extension WatchItem {
    /// 走势图上要画的横线，按价格从高到低排：成本线（cost 为 true、填了持仓时）和提醒线（alerts 为 true、设了提醒时）。
    /// previousClose 是分时图的昨收，涨跌幅提醒按它折成价格；K 线上传 nil。
    public func chartLevels(previousClose: Double?, cost: Bool = true, alerts: Bool = true) -> [ChartLevel] {
        var levels = alerts ? alert.chartLevels(holding: holding, previousClose: previousClose) : []
        if cost, let price = holding?.cost, price > 0 {
            levels.append(ChartLevel(kind: .cost, price: price))
        }
        return levels.sorted { $0.price > $1.price }
    }
}

/// 走势图上横线旁边的字怎么摆：每个字写在自己那条线的上面，贴着顶边放不下时写在线的下面；
/// 几条线挨得近、字上下叠在一起时，这几个字横着排成一排，谁也不盖住谁。
public enum LevelLabelLayout {
    public enum Alignment: Sendable {
        /// 一排字放在中间：分时图的四个角写着最高最低。
        case center
        /// 一排字靠右：K 线最新的在右边。
        case trailing
    }

    /// 一条线和它旁边的字：线的纵坐标（从上往下算），字（连底色）的宽高。
    public struct Label: Equatable, Sendable {
        public var lineY: Double
        public var width: Double
        public var height: Double

        public init(lineY: Double, width: Double, height: Double) {
            self.lineY = lineY
            self.width = width
            self.height = height
        }
    }

    /// 字左上角的位置。
    public struct Placement: Equatable, Sendable {
        public var x: Double
        public var y: Double

        public init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }
    }

    /// 字和线之间的空隙。
    public static let lineGap: Double = 2
    /// 一排里的字之间的空隙。
    public static let spacing: Double = 4
    /// 靠右时右边留的边。
    public static let margin: Double = 1

    /// 按 labels 的顺序（传进来时从高到低）排，返回每个字左上角的位置，和 labels 一一对应。
    public static func place(_ labels: [Label], width: Double, height: Double, alignment: Alignment) -> [Placement] {
        // 先定上下：写在线的上面，放不下时写在下面，都不出图。
        let ys: [Double] = labels.map { label in
            let above = label.lineY - lineGap - label.height
            let y = above >= 0 ? above : label.lineY + lineGap
            return min(max(y, 0), max(height - label.height, 0))
        }
        // 从上往下看，和上一排里的字上下有重叠的放进同一排。
        var rows: [[Int]] = []
        var rowBottom = -Double.infinity
        for index in labels.indices.sorted(by: { (ys[$0], $0) < (ys[$1], $1) }) {
            if !rows.isEmpty, ys[index] < rowBottom {
                rows[rows.count - 1].append(index)
                rowBottom = max(rowBottom, ys[index] + labels[index].height)
            } else {
                rows.append([index])
                rowBottom = ys[index] + labels[index].height
            }
        }
        // 一排里的字按传进来的顺序从左往右排，整排放在中间或者靠右，左边不出图。
        var xs = Array(repeating: 0.0, count: labels.count)
        for row in rows {
            let members = row.sorted()
            let total = members.map { labels[$0].width }.reduce(0, +) + spacing * Double(members.count - 1)
            var x: Double
            switch alignment {
            case .center: x = (width - total) / 2
            case .trailing: x = width - margin - total
            }
            x = max(x, 0)
            for index in members {
                xs[index] = x
                x += labels[index].width + spacing
            }
        }
        return labels.indices.map { Placement(x: xs[$0], y: ys[$0]) }
    }
}
