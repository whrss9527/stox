import Foundation
import StoxCore
import WidgetKit

@MainActor
final class WidgetPublisher {
    private var lastSnapshot: WidgetSnapshot?
    private var lastReload: Date?

    func publish(items: [WatchItem], quotes: [Symbol: Quote]) {
        // 与其他端到端测试一样，调试路径明确注入；不会落到用户的共享容器。
        let directory: URL?
        if let path = ProcessInfo.processInfo.environment["STOX_WIDGET_DIR"] {
            directory = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.io.github.whrss9527.stox.widgets")
        }
        guard let directory else { return }
        let now = Date()
        let snapshot = WidgetSnapshot(items: items, quotes: quotes, now: now)
        guard snapshot.quotes != lastSnapshot?.quotes || now.timeIntervalSince(lastSnapshot?.capturedAt ?? .distantPast) >= 300 else { return }
        do {
            try WidgetSnapshotFile.write(snapshot, in: directory)
            let listChanged = snapshot.quotes.map(\.id) != lastSnapshot?.quotes.map(\.id)
            lastSnapshot = snapshot
            if listChanged || now.timeIntervalSince(lastReload ?? .distantPast) >= 300 {
                WidgetCenter.shared.reloadTimelines(ofKind: "StoxQuotes")
                lastReload = now
            }
        } catch {
            Log.error("小组件行情保存失败：\(error.localizedDescription)")
        }
    }
}
