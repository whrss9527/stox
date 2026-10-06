import SwiftUI
import StoxCore

/// 系统设置里关掉了 Stox 的通知时，设置的“价格提醒”和编辑提醒的地方显示的提示，带一个打开系统设置的按钮。
@MainActor
struct NotificationDeniedNote: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(L("系统设置里关掉了 Stox 的通知，价格提醒、止盈止损和收盘小结都不会弹出来。"), systemImage: "bell.slash.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            Button(L("打开系统设置")) { Notifier.openSystemSettings() }
                .controlSize(.small)
                .help(L("在“通知”里找到 Stox，打开“允许通知”"))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 面板底部的一行小字：有开着的提醒，但系统设置里关掉了 Stox 的通知。点一下打开系统设置。
@MainActor
struct NotificationDeniedHint: View {
    var body: some View {
        Button { Notifier.openSystemSettings() } label: {
            HStack(spacing: 4) {
                Image(systemName: "bell.slash.fill")
                Text(L("通知已关闭，提醒发不出来"))
                Text(L("打开系统设置"))
                    .underline()
                Spacer(minLength: 0)
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.orange)
            .lineLimit(1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .help(L("系统设置里关掉了 Stox 的通知，到价提醒、止盈止损都不会弹出来。点这里打开系统设置，在“通知”里找到 Stox，打开“允许通知”。"))
    }
}
