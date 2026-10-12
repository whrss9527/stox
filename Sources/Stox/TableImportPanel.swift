import AppKit
import SwiftUI
import StoxCore

@MainActor
struct TableImportPanel: View {
    @EnvironmentObject private var store: QuoteStore
    @EnvironmentObject private var router: PanelRouter
    @State private var text = ""
    @State private var mode: TableImport.Mode = .merge

    var body: some View {
        let preview = TableImport.parse(text)
        let problem = applicationProblem(preview)
        return VStack(spacing: 10) {
            HStack {
                Text(L("导入持仓或买卖表格")).font(.system(size: 14, weight: .semibold))
                Spacer()
                Button(L("粘贴")) { text = NSPasteboard.general.string(forType: .string) ?? "" }
            }
            .padding(10)
            .glassCard(prominent: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("粘贴带表头的制表符文本，可用 Stox 复制的持仓或买卖表格。"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    TextEditor(text: $text)
                        .font(.system(size: 11).monospaced())
                        .frame(height: 120)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
                    Picker(L("导入方式"), selection: $mode) {
                        Text(L("合并")).tag(TableImport.Mode.merge)
                        Text(L("替换")).tag(TableImport.Mode.replace)
                    }.pickerStyle(.segmented)
                    Text(preview.kind == .holdings
                         ? L("合并更新表中持仓；替换先清除全部已有持仓。自选、提醒和买卖记录保留。")
                         : L("合并添加不重复的记录；替换先清除全部已知买卖记录。当前持仓不改变，也不重放买卖。"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(L("预览：%@ 行有效，%@ 行错误，%@ 行重复", preview.rows.count, preview.problems.count, preview.duplicates))
                        .font(.system(size: 12, weight: .medium))
                    if let problem { Text(problem).foregroundStyle(Color.red).font(.system(size: 11)) }
                    ForEach(preview.problems) { problem in
                        Text(L("第 %@ 行：%@", problem.line, problem.message)).font(.system(size: 11)).foregroundStyle(Color.red)
                    }
                    ForEach(preview.rows) { row in
                        VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(L("第 %@ 行", row.line)).foregroundStyle(.secondary)
                            Text(row.symbol.rawValue).monospaced()
                            Text(AppLanguage.securityName(row.name)).lineLimit(1)
                            Spacer(minLength: 0)
                            if let holding = row.holding {
                                Text(QuoteFormatter.plain(holding.shares) + " × " + QuoteFormatter.plain(holding.cost))
                            } else if let trade = row.trade {
                                Text(trade.day + " " + trade.side.title + " " + QuoteFormatter.plain(trade.shares) + " × " + QuoteFormatter.plain(trade.price))
                            }
                        }.font(.system(size: 11))
                            if let trade = row.trade {
                                Text(L("费用：%@；已实现盈亏：%@；每股送转：%@",
                                       trade.fee.map { QuoteFormatter.plain($0) } ?? "0",
                                       trade.profit.map { QuoteFormatter.plain($0) } ?? L("未知"),
                                       QuoteFormatter.plain(trade.bonus ?? 0)))
                                    .font(.system(size: 10)).foregroundStyle(.secondary)
                            } else if row.hasGroup {
                                Text(L("分组：%@", row.group ?? L("未分组")))
                                    .font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }.padding(10)
            }
            .frame(maxHeight: max(120, router.pageMaxHeight - 90))
            .glassCard()
            HStack {
                Button(L("取消")) { router.route = .list }
                Spacer()
                Button(L("导入")) {
                    guard let result = try? preview.applying(to: store.items, mode: mode) else { return }
                    store.replaceWatchlist(result)
                    router.route = .list
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!preview.canImport || problem != nil)
            }.controlSize(.regular)
        }
    }

    private func applicationProblem(_ preview: TableImport) -> String? {
        guard preview.canImport else { return nil }
        do { _ = try preview.applying(to: store.items, mode: mode); return nil }
        catch let error as TableImport.Failure { return error.message }
        catch { return L("请先修正表格中的错误行") }
    }
}
