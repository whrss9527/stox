import AppKit
import SwiftUI
import StoxCore

/// 快捷键录制框：点一下，再按下新的组合键；按 Esc 取消。
struct HotkeyRecorder: NSViewRepresentable {
    @Binding var binding: HotkeyBinding

    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView()
        view.onChange = { binding = $0 }
        view.binding = binding
        return view
    }

    func updateNSView(_ view: RecorderView, context: Context) {
        view.binding = binding
        view.onChange = { binding = $0 }
    }

    final class RecorderView: NSView {
        var onChange: ((HotkeyBinding) -> Void)?
        var binding: HotkeyBinding? {
            didSet { needsDisplay = true }
        }
        private var recording = false {
            didSet { needsDisplay = true }
        }

        override var acceptsFirstResponder: Bool { true }

        override func becomeFirstResponder() -> Bool {
            recording = true
            return super.becomeFirstResponder()
        }

        override func resignFirstResponder() -> Bool {
            recording = false
            return super.resignFirstResponder()
        }

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
        }

        override func keyDown(with event: NSEvent) {
            guard recording else {
                super.keyDown(with: event)
                return
            }
            if event.keyCode == 53 {  // Esc：取消
                window?.makeFirstResponder(nil)
                return
            }
            let modifiers = KeyNames.carbonModifiers(from: event.modifierFlags)
            // 至少带一个修饰键，否则平时打字就会触发。
            guard modifiers != 0 else {
                NSSound.beep()
                return
            }
            let keyCode = UInt32(event.keyCode)
            onChange?(HotkeyBinding(keyCode: keyCode, modifiers: modifiers, display: KeyNames.display(keyCode: keyCode, modifiers: modifiers)))
            window?.makeFirstResponder(nil)
        }

        override func draw(_ dirtyRect: NSRect) {
            let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
            let path = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
            (recording ? NSColor.controlAccentColor.withAlphaComponent(0.15) : NSColor.textBackgroundColor.withAlphaComponent(0.6)).setFill()
            path.fill()
            (recording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
            path.lineWidth = recording ? 1.5 : 1
            path.stroke()
            let text = recording ? L("按下组合键…") : (binding?.display ?? L("点击设置"))
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: recording ? NSColor.controlAccentColor : NSColor.labelColor,
                .paragraphStyle: paragraph,
            ]
            let size = (text as NSString).size(withAttributes: attributes)
            let textRect = NSRect(x: 0, y: (bounds.height - size.height) / 2, width: bounds.width, height: size.height)
            (text as NSString).draw(in: textRect, withAttributes: attributes)
        }
    }
}
