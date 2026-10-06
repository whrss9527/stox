import XCTest
@testable import StoxCore

/// 通知被关掉时，面板里只在有开着的提醒时提示，没开提醒的人不打扰。
final class NotificationPermissionTests: XCTestCase {
    private let maotai = WatchItem(symbol: Symbol("sh600519")!)
    private let index = WatchItem(symbol: Symbol("sh000001")!)
    private let apple = WatchItem(symbol: Symbol("usAAPL")!)
    private let gold = WatchItem(symbol: Symbol("hf_XAU")!)

    func testPriceAlertsNeedTheMasterSwitch() {
        var alerted = maotai
        alerted.alert = PriceAlert(priceAbove: 1500)
        XCTAssertTrue(NotificationNeeds().hasActiveAlerts(in: [index, alerted]), "有一只设了价格提醒")
        XCTAssertFalse(NotificationNeeds().hasActiveAlerts(in: [index, maotai]), "都没设")
        XCTAssertFalse(NotificationNeeds(alertsEnabled: false).hasActiveAlerts(in: [alerted]), "关掉了“到价时发送系统通知”")
        XCTAssertFalse(NotificationNeeds().hasActiveAlerts(in: []))
    }

    func testSwitchesForTheWholeWatchlist() {
        let limit = NotificationNeeds(limitAlerts: true)
        XCTAssertTrue(limit.hasActiveAlerts(in: [maotai]), "涨跌停提醒看 A 股个股")
        XCTAssertFalse(limit.hasActiveAlerts(in: [index, apple, gold]), "指数、美股、期货没有涨跌停")
        XCTAssertTrue(NotificationNeeds(yearAlerts: true).hasActiveAlerts(in: [index]), "52 周新高新低含指数")
        XCTAssertTrue(NotificationNeeds(rapidMoves: true).hasActiveAlerts(in: [gold]), "异动提醒看整个自选")
        XCTAssertFalse(NotificationNeeds(alertsEnabled: false, limitAlerts: true, yearAlerts: true, rapidMoves: true).hasActiveAlerts(in: [maotai]))
    }

    func testCloseSummaryNeedsAHolding() {
        var held = maotai
        held.holding = Holding(shares: 100, cost: 1200)
        let summary = NotificationNeeds(alertsEnabled: false, closeSummary: true)
        XCTAssertTrue(summary.hasActiveAlerts(in: [held]), "收盘小结不受“到价时发送系统通知”管")
        XCTAssertFalse(summary.hasActiveAlerts(in: [maotai]), "没有持仓就没有收盘小结")
        var soldOut = maotai
        soldOut.holding = Holding(shares: 0, cost: 1200)
        XCTAssertFalse(summary.hasActiveAlerts(in: [soldOut]), "卖光了不算持仓")
    }

    func testWarnsOnlyWhenDenied() {
        var alerted = maotai
        alerted.alert = PriceAlert(lossBelow: 8)
        let needs = NotificationNeeds()
        XCTAssertTrue(needs.shouldWarn(.denied, items: [alerted]))
        for permission in [NotificationPermission.unknown, .notDetermined, .authorized] {
            XCTAssertFalse(needs.shouldWarn(permission, items: [alerted]), "\(permission)")
        }
        XCTAssertFalse(needs.shouldWarn(.denied, items: [maotai]), "没开提醒的人不打扰")
        XCTAssertEqual(NotificationPermission(rawValue: "denied"), .denied, "CI 用环境变量指定")
    }
}
