import AppKit
import XCTest
import StoxCore
@testable import Stox

final class PanelPresentationTests: XCTestCase {
    @MainActor
    func testLegacyPinDoesNotRestoreAndPinIsNotPersisted() {
        let context = AppTestContext()
        defer { context.cleanup() }
        context.defaults.set(true, forKey: "panel.pinned")
        let settings = SettingsStore(defaults: context.defaults)
        XCTAssertFalse(settings.panelPinned)
        settings.panelPinned = true
        XCTAssertFalse(SettingsStore(defaults: context.defaults).panelPinned)
    }

    @MainActor
    func testDefaultFocusLossClosesEvenWithStalePinBeforeOpening() throws {
        let context = AppTestContext()
        defer { context.cleanup() }
        let store = try context.store(provider: FakeQuoteProvider(), items: [WatchItem(symbol: Symbol("sh600519")!)])
        defer { store.stop() }
        let sync = SyncManager(store: store, settings: context.settings, defaults: context.defaults,
                               clock: context.clock, location: .override(temporaryFolder()), watchesChanges: false)
        defer { sync.disable() }
        let controller = StatusItemController(store: store, settings: context.settings, sync: sync)
        defer { controller.closePanel() }
        context.settings.panelPinned = true
        controller.openPanel()
        let panel = try XCTUnwrap(controller.panel)
        XCTAssertTrue(panel.isVisible)
        XCTAssertFalse(context.settings.panelPinned)
        XCTAssertFalse(panel.pinned)
        XCTAssertEqual(panel.level, .popUpMenu)
        panel.resignKey()
        XCTAssertFalse(panel.isVisible)
    }

    @MainActor
    func testExplicitPinLastsOnlyUntilCloseAndReopen() throws {
        let context = AppTestContext()
        defer { context.cleanup() }
        let store = try context.store(provider: FakeQuoteProvider(), items: [WatchItem(symbol: Symbol("sh600519")!)])
        defer { store.stop() }
        let sync = SyncManager(store: store, settings: context.settings, defaults: context.defaults,
                               clock: context.clock, location: .override(temporaryFolder()), watchesChanges: false)
        defer { sync.disable() }
        let controller = StatusItemController(store: store, settings: context.settings, sync: sync)
        defer { controller.closePanel() }
        controller.openPanel()
        let panel = try XCTUnwrap(controller.panel)
        context.settings.panelPinned = true
        XCTAssertTrue(panel.pinned)
        XCTAssertTrue(panel.isMovable)
        XCTAssertEqual(panel.level, .floating)
        controller.openPanel() // An action targeting the already-open panel keeps the explicit choice.
        XCTAssertTrue(context.settings.panelPinned)
        panel.resignKey()
        XCTAssertTrue(panel.isVisible)
        let screen = try XCTUnwrap(panel.screen ?? NSScreen.main).visibleFrame
        let floatingOrigin = NSPoint(x: screen.midX - panel.frame.width / 2,
                                     y: screen.midY - panel.frame.height / 2)
        panel.setFrameOrigin(floatingOrigin)
        context.settings.pinnedTopLeft = CGPoint(x: panel.frame.minX, y: panel.frame.maxY)
        context.settings.panelPinned = false
        XCTAssertFalse(panel.pinned)
        // The status item can move while macOS arranges the menu bar; its old x is not an anchor.
        XCTAssertNotEqual(panel.frame.origin, floatingOrigin)
        XCTAssertGreaterThan(panel.frame.maxY, screen.midY + panel.frame.height / 2)
        context.settings.panelPinned = true
        controller.closePanel()
        XCTAssertFalse(context.settings.panelPinned)
        controller.openPanel()
        XCTAssertTrue(controller.panel === panel)
        XCTAssertTrue(panel.isVisible)
        XCTAssertFalse(panel.pinned)
        XCTAssertFalse(panel.isMovable)
        XCTAssertEqual(panel.level, .popUpMenu)
        panel.resignKey()
        XCTAssertFalse(panel.isVisible)
    }

    private func temporaryFolder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("StoxPanelTests-" + UUID().uuidString)
    }
}
