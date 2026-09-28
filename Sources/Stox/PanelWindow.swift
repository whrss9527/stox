import AppKit

/// 无边框、不激活程序的浮动面板：像菜单一样出现在菜单栏图标下面，点到别处或按 Esc 时关闭。
/// 不激活程序，所以打开面板不会抢走正在使用的 App 的焦点。
final class PanelWindow: NSPanel {
    /// 失去焦点（点到别处）时调用。钉住时由调用方决定不关闭。
    var onResignKey: (() -> Void)?
    /// 按 Esc 并且面板内部没有处理时调用，钉住时也关闭。
    var onClose: (() -> Void)?
    /// 按 Esc 时先交给面板处理（清空搜索、返回列表）；返回 true 表示已处理，不关闭面板。
    var onEscape: (() -> Bool)?

    /// 钉住：可以拖动，浮在普通窗口上面但不挡菜单；没钉住时像菜单一样在最上层。
    var pinned = false {
        didSet {
            isMovable = pinned
            isMovableByWindowBackground = pinned
            level = pinned ? .floating : .popUpMenu
        }
    }

    init(contentView: NSView) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 300),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovable = false
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow
        self.contentView = contentView
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }

    override func cancelOperation(_ sender: Any?) {
        if onEscape?() != true {
            onClose?()
        }
    }

    /// 面板不激活程序，主菜单收不到编辑快捷键；这里把 ⌘X / ⌘C / ⌘V / ⌘A / ⌘Z 直接交给文本框。
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        var action: Selector?
        if flags == .command {
            switch key {
            case "x": action = #selector(NSText.cut(_:))
            case "c": action = #selector(NSText.copy(_:))
            case "v": action = #selector(NSText.paste(_:))
            case "a": action = #selector(NSText.selectAll(_:))
            case "z": action = Selector(("undo:"))
            default: break
            }
        } else if flags == [.command, .shift], key == "z" {
            action = Selector(("redo:"))
        }
        if let action, NSApp.sendAction(action, to: nil, from: self) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
