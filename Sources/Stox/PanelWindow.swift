import AppKit
import Carbon.HIToolbox

/// 面板里用到的导航键。
enum PanelKey: String {
    case up, down, left, right, enter

    /// 不带 ⌘ ⌥ ⌃ ⇧ 的方向键和回车；组合键（比如 ⇧← 选中文字）照常交给文本框。
    init?(event: NSEvent) {
        guard event.type == .keyDown,
              event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
        else { return nil }
        switch Int(event.keyCode) {
        case kVK_UpArrow: self = .up
        case kVK_DownArrow: self = .down
        case kVK_LeftArrow: self = .left
        case kVK_RightArrow: self = .right
        case kVK_Return, kVK_ANSI_KeypadEnter: self = .enter
        default: return nil
        }
    }

    /// 造一个按键事件，CI 里用来模拟键盘操作。
    @MainActor
    func event(for window: NSWindow) -> NSEvent? {
        let code: Int
        let character: Int
        switch self {
        case .up: code = kVK_UpArrow; character = NSUpArrowFunctionKey
        case .down: code = kVK_DownArrow; character = NSDownArrowFunctionKey
        case .left: code = kVK_LeftArrow; character = NSLeftArrowFunctionKey
        case .right: code = kVK_RightArrow; character = NSRightArrowFunctionKey
        case .enter: code = kVK_Return; character = 0x0D
        }
        let scalar = UnicodeScalar(UInt16(character)) ?? " "
        let text = String(Character(scalar))
        let flags: NSEvent.ModifierFlags = self == .enter ? [] : [.numericPad, .function]
        return NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text,
            isARepeat: false, keyCode: UInt16(code)
        )
    }
}

/// 无边框、不激活程序的浮动面板：像菜单一样出现在菜单栏图标下面，点到别处或按 Esc 时关闭。
/// 不激活程序，所以打开面板不会抢走正在使用的 App 的焦点。
final class PanelWindow: NSPanel {
    /// 失去焦点（点到别处）时调用。钉住时由调用方决定不关闭。
    var onResignKey: (() -> Void)?
    /// 按 Esc 并且面板内部没有处理时调用，钉住时也关闭。
    var onClose: (() -> Void)?
    /// 按 Esc 时先交给面板处理（清空搜索、返回列表）；返回 true 表示已处理，不关闭面板。
    var onEscape: (() -> Bool)?
    /// 方向键和回车先交给面板（在搜索结果、自选列表里上下选择）；返回 true 表示已处理，文本框就收不到了。
    var onNavigate: ((PanelKey) -> Bool)?

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

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, !isComposingText, let key = PanelKey(event: event), onNavigate?(key) == true {
            return
        }
        super.sendEvent(event)
    }

    /// 输入法正在组字（拼音还没选字）时，方向键和回车是给输入法用的，不能拦。
    private var isComposingText: Bool {
        (firstResponder as? NSTextView)?.hasMarkedText() == true
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
