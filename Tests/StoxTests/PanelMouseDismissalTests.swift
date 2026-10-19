import AppKit
import XCTest
@testable import Stox

@MainActor
final class PanelMouseDismissalTests: XCTestCase {
    func testMouseExitClosesWhilePanelStillHasKeyboardFocus() async throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        XCTAssertTrue(fixture.panel.isKeyWindow)
        try fixture.move(to: NSPoint(x: 50, y: 50))
        XCTAssertTrue(fixture.panel.isKeyWindow, "鼠标移动没有改变键盘焦点")
        await settle()
        XCTAssertFalse(fixture.panel.isVisible, "无需点击别处即可关闭")
    }

    func testStationaryPointerAndStatusButtonTransitDoNotClose() async throws {
        let fixture = Fixture(initialPoint: NSPoint(x: 50, y: 50))
        defer { fixture.cleanup() }
        try fixture.move(to: fixture.point)
        await settle()
        XCTAssertTrue(fixture.panel.isVisible, "快捷键打开时鼠标静止在别处不会关闭")
        for point in [NSPoint(x: 332, y: 413), NSPoint(x: 332, y: 401), NSPoint(x: 350, y: 300)] {
            try fixture.move(to: point)
            await settle()
            XCTAssertTrue(fixture.panel.isVisible, "按钮到面板的路径不误关")
        }
    }

    func testContinuedMovementOutsideDoesNotKeepPostponingClose() async throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        for index in 0..<6 {
            try fixture.move(to: NSPoint(x: 50 + index, y: 50))
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertFalse(fixture.panel.isVisible, "移出后持续移动也正常关闭")
    }

    func testLeavingStatusButtonClosesWithoutEnteringPanelFirst() async throws {
        let fixture = Fixture(initialPoint: NSPoint(x: 332, y: 413))
        defer { fixture.cleanup() }
        try fixture.move(to: NSPoint(x: 50, y: 50))
        await settle()
        XCTAssertFalse(fixture.panel.isVisible)
    }

    func testReentryAndPinningCancelPendingClose() async throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        try fixture.move(to: NSPoint(x: 50, y: 50))
        try fixture.move(to: NSPoint(x: 350, y: 300))
        await settle()
        XCTAssertTrue(fixture.panel.isVisible)
        try fixture.move(to: NSPoint(x: 50, y: 50))
        fixture.panel.pinned = true
        await settle()
        XCTAssertTrue(fixture.panel.isVisible, "本次保持打开覆盖鼠标离开")
        fixture.panel.pinned = false
        try fixture.move(to: NSPoint(x: 60, y: 50))
        await settle()
        XCTAssertFalse(fixture.panel.isVisible)
    }

    func testNestedMenusSuspendClosingUntilAllMenusEnd() async throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let menu = NSMenu(title: "Options")
        let submenu = NSMenu(title: "Group")
        for object in [menu, submenu] {
            NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: object)
        }
        try fixture.move(to: NSPoint(x: 50, y: 50))
        await settle()
        XCTAssertTrue(fixture.panel.isVisible)
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: submenu)
        await settle()
        XCTAssertTrue(fixture.panel.isVisible, "主菜单仍在操作")
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu)
        await settle()
        XCTAssertFalse(fixture.panel.isVisible, "菜单结束且鼠标仍在外部时关闭")
    }

    func testAttachedWindowAndDraggingDoNotClosePrematurely() async throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let child = PanelWindow(contentView: NSView())
        child.setFrame(NSRect(x: 510, y: 210, width: 100, height: 100), display: false)
        fixture.panel.addChildWindow(child, ordered: .above)
        child.orderFrontRegardless()
        defer {
            fixture.panel.removeChildWindow(child)
            child.orderOut(nil)
        }
        try fixture.move(to: NSPoint(x: 550, y: 250))
        await settle()
        XCTAssertTrue(fixture.panel.isVisible)
        child.orderOut(nil)
        fixture.buttons = 1
        try fixture.move(to: NSPoint(x: 560, y: 250), type: .leftMouseDragged)
        await settle()
        XCTAssertTrue(fixture.panel.isVisible, "拖动途中不关闭")
        fixture.buttons = 0
        try fixture.move(to: fixture.point, type: .leftMouseUp)
        await settle()
        XCTAssertFalse(fixture.panel.isVisible, "外部松开鼠标后正常关闭")
    }

    func testCloseAndReopenCancelOldExitTask() async throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        try fixture.move(to: NSPoint(x: 50, y: 50))
        fixture.tracker.stop()
        fixture.panel.orderOut(nil)
        fixture.point = NSPoint(x: 350, y: 300)
        fixture.panel.orderFrontRegardless()
        fixture.panel.makeKey()
        fixture.tracker.start()
        await settle()
        XCTAssertTrue(fixture.panel.isVisible)
        try fixture.move(to: NSPoint(x: 50, y: 50))
        await settle()
        XCTAssertFalse(fixture.panel.isVisible)
    }

    private func settle() async {
        try? await Task.sleep(nanoseconds: 350_000_000)
    }

    /// 通过 NSApplication 的实际事件监视器发事件；替换鼠标读数，避免移动开发者的真实光标。
    @MainActor
    private final class Fixture {
        let panel = PanelWindow(contentView: NSView())
        var point: NSPoint
        var buttons = 0
        var tracker: PanelMouseDismissal!

        init(initialPoint: NSPoint = NSPoint(x: 350, y: 300)) {
            point = initialPoint
            panel.setFrame(NSRect(x: 200, y: 200, width: 300, height: 200), display: false)
            panel.orderFrontRegardless()
            panel.makeKey()
            tracker = PanelMouseDismissal(panel: panel,
                statusButtonFrame: { NSRect(x: 320, y: 402, width: 24, height: 22) },
                mouseLocation: { [unowned self] in point }, mouseButtons: { [unowned self] in buttons },
                onExit: { [weak panel] in panel?.orderOut(nil) })
            tracker.start()
        }

        func move(to location: NSPoint, type: NSEvent.EventType = .mouseMoved) throws {
            point = location
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type,
                location: panel.convertPoint(fromScreen: location), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
            NSApp.sendEvent(event)
        }

        func cleanup() {
            tracker.stop()
            panel.orderOut(nil)
        }
    }
}
