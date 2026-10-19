import AppKit

/// 只在鼠标实际移动后判断离开；快捷键打开面板时，停在别处的鼠标不触发关闭。
@MainActor
final class PanelMouseDismissal {
    private weak var panel: PanelWindow?
    private let statusButtonFrame: () -> NSRect?
    private let mouseLocation: () -> NSPoint
    private let mouseButtons: () -> Int
    private let onExit: () -> Void
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var menuObservers: [NSObjectProtocol] = []
    private var trackingMenus = Set<ObjectIdentifier>()
    private var lastLocation: NSPoint?
    private var pendingClose: Task<Void, Never>?

    init(panel: PanelWindow, statusButtonFrame: @escaping () -> NSRect?,
         mouseLocation: @escaping () -> NSPoint = { NSEvent.mouseLocation },
         mouseButtons: @escaping () -> Int = { NSEvent.pressedMouseButtons }, onExit: @escaping () -> Void) {
        self.panel = panel
        self.statusButtonFrame = statusButtonFrame
        self.mouseLocation = mouseLocation
        self.mouseButtons = mouseButtons
        self.onExit = onExit
    }

    func start() {
        stop()
        lastLocation = mouseLocation()
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged,
                                             .otherMouseDragged, .leftMouseUp, .rightMouseUp, .otherMouseUp]
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            MainActor.assumeIsolated { self?.mouseMoved(event) }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] event in
            MainActor.assumeIsolated { self?.mouseMoved(event) }
        }
        for name in [NSMenu.didBeginTrackingNotification, NSMenu.didEndTrackingNotification] {
            menuObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, let menu = note.object as? NSMenu else { return }
                    if name == NSMenu.didBeginTrackingNotification {
                        self.trackingMenus.insert(ObjectIdentifier(menu))
                        self.cancelPendingClose()
                    } else {
                        self.trackingMenus.remove(ObjectIdentifier(menu))
                        self.checkLocation()
                    }
                }
            })
        }
    }

    func stop() {
        cancelPendingClose()
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
        menuObservers.forEach(NotificationCenter.default.removeObserver)
        menuObservers.removeAll()
        trackingMenus.removeAll()
        lastLocation = nil
    }

    private func mouseMoved(_ event: NSEvent) {
        let point = mouseLocation()
        let released = [.leftMouseUp, .rightMouseUp, .otherMouseUp].contains(event.type)
        guard point != lastLocation || released else { return }
        lastLocation = point
        checkLocation()
    }

    private func checkLocation() {
        guard shouldClose else {
            cancelPendingClose()
            return
        }
        guard pendingClose == nil else { return }
        // 给快速移回及菜单栏到面板的移动留一点余地，避免边界抖动造成闪退。
        pendingClose = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled, let self else { return }
            self.pendingClose = nil
            if self.shouldClose { self.onExit() }
        }
    }

    private func cancelPendingClose() {
        pendingClose?.cancel()
        pendingClose = nil
    }

    private var shouldClose: Bool {
        guard let panel, panel.isVisible, !panel.pinned,
              trackingMenus.isEmpty, mouseButtons() == 0 else { return false }
        let point = mouseLocation()
        // 4pt 包含按钮与面板间的细缝；从菜单栏移向面板时不会误关。
        if panel.frame.insetBy(dx: -4, dy: -4).contains(point)
            || statusButtonFrame()?.insetBy(dx: -4, dy: -4).contains(point) == true { return false }
        return !contains(point, inChildrenOf: panel)
    }

    private func contains(_ point: NSPoint, inChildrenOf window: NSWindow) -> Bool {
        (window.childWindows ?? []).contains {
            $0.isVisible && ($0.frame.contains(point) || contains(point, inChildrenOf: $0))
        }
    }
}
