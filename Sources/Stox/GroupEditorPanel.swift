import SwiftUI
import StoxCore

/// 新建或编辑一个分组：改组名、勾选放进这个分组的证券，也可以解散。在面板里打开，Esc 返回列表。
@MainActor
struct GroupEditorPanel: View {
    /// 编辑的分组；新建时为 nil。
    let original: String?
    /// 新建时先勾上的那一只（从某一行的右键菜单进来时）。
    let member: Symbol?

    @EnvironmentObject private var store: QuoteStore
    @EnvironmentObject private var router: PanelRouter
    @State private var name = ""
    @State private var members: Set<Symbol> = []
    @State private var loaded = false

    /// 勾选列表最多这么高，自选多时在里面滚动。
    private static let listMaxHeight: CGFloat = 300

    var body: some View {
        VStack(spacing: 10) {
            header

            HStack {
                Text(L("组名"))
                Spacer()
                TextField("", text: $name, prompt: Text(L("比如 科技、长期持有")))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                    .onSubmit(save)
            }
            .font(.system(size: 12.5))
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .glassCard()

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(L("放进这个分组的"))
                        .font(.system(size: 12.5, weight: .semibold))
                    Spacer()
                    Text(L("已选 %@ 只", members.count))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(store.items) { item in
                            memberRow(item)
                        }
                    }
                }
                .frame(height: min(CGFloat(store.items.count) * 24, Self.listMaxHeight))
                Text(footer)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .glassCard()

            HStack {
                if let original {
                    Button(L("解散分组"), role: .destructive) {
                        store.saveGroup("", members: [], replacing: original)
                        router.route = .list
                    }
                }
                Spacer()
                Button(L("取消")) { router.route = .list }
                Button(L("保存"), action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
            .controlSize(.regular)
            .padding(.horizontal, 2)
        }
        .onAppear(perform: load)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                router.route = .list
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(IconButtonStyle())
            .help(L("返回（Esc）"))
            VStack(alignment: .leading, spacing: 2) {
                Text(original.map { L("分组“%@”", $0) } ?? L("新建分组"))
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                Text(L("每只最多在一个分组里，放进来的会从原来的分组移出"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(10)
        .glassCard(prominent: true)
    }

    private func memberRow(_ item: WatchItem) -> some View {
        Toggle(isOn: Binding(
            get: { members.contains(item.symbol) },
            set: { checked in
                if checked { members.insert(item.symbol) } else { members.remove(item.symbol) }
            }
        )) {
            HStack(spacing: 6) {
                Text(store.quotes[item.symbol]?.name ?? item.displayName)
                    .font(.system(size: 12))
                    .lineLimit(1)
                Text(item.symbol.displayCode)
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                // 在别的分组里的标出来，勾上就会搬过来。
                if let group = item.group, group != original {
                    Text(group)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .toggleStyle(.checkbox)
        .frame(height: 22)
    }

    private var trimmedName: String? { WatchItem.normalizedGroup(name) }

    private var isValid: Bool { trimmedName != nil && !members.isEmpty }

    private var footer: String {
        guard let trimmedName else { return L("先填一个组名。") }
        if members.isEmpty { return L("至少勾上一只。") }
        if trimmedName != original, Watchlist.groups(in: store.items).contains(trimmedName) {
            return L("已经有“%@”这个分组了，保存后合在一起。", trimmedName)
        }
        if name.trimmingCharacters(in: .whitespacesAndNewlines).count > WatchItem.groupNameLimit {
            return L("组名最多 %@ 个字，保存时会截断成“%@”。", WatchItem.groupNameLimit, trimmedName)
        }
        return L("列表上方的筛选里会多出“%@”，右键它可以再编辑或解散。", trimmedName)
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        name = original ?? ""
        if let original {
            members = Set(store.items.filter { $0.group == original }.map(\.symbol))
        } else if let member {
            members = [member]
        }
    }

    private func save() {
        guard isValid, let trimmedName else { return }
        store.saveGroup(trimmedName, members: members, replacing: original)
        router.route = .list
    }
}
