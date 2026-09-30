// 从 CI 的整屏截图做一张 App Store 截图：把菜单栏按钮和面板那一块裁出来，放在 App Store 要求尺寸的画布上，
// 左边可以写一行说明。App Store 的 Mac 截图只收 1280x800、1440x900、2560x1600、2880x1800 这几种尺寸（16:10）。
//
// 用法: swift scripts/app-store-screenshot.swift <整屏.png> <输出.png> <x> <y> <w> <h> [画布宽 画布高] [说明文字]
// 坐标为屏幕点（左上角原点），由 `Stox --show-panel` 打印的 STOX_DIAG capture_frame 给出。默认画布 1440x900。
// CI 的屏幕是 1 倍的，面板按原大小放上去最清楚；2880x1800 要在 Retina 屏上截（见 docs/app-store/screenshots.md）。
import AppKit

let args = CommandLine.arguments
guard args.count >= 7,
      let x = Double(args[3]), let y = Double(args[4]), let w = Double(args[5]), let h = Double(args[6]),
      let image = NSImage(contentsOf: URL(fileURLWithPath: args[1])),
      let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
else {
    FileHandle.standardError.write("参数错误或无法读取截图\n".data(using: .utf8)!)
    exit(1)
}
let canvasWidth = args.count >= 9 ? Int(args[7]) ?? 1440 : 1440
let canvasHeight = args.count >= 9 ? Int(args[8]) ?? 900 : 900
let caption = args.count >= 10 ? args[9] : ""
let allowed = [(1280, 800), (1440, 900), (2560, 1600), (2880, 1800)]
guard allowed.contains(where: { $0 == (canvasWidth, canvasHeight) }) else {
    FileHandle.standardError.write("App Store 不收 \(canvasWidth)x\(canvasHeight) 的截图\n".data(using: .utf8)!)
    exit(1)
}

// 截图的像素和屏幕点的比例（Retina 屏是 2）。
let pointsWide = Double(NSScreen.screens.first?.frame.width ?? CGFloat(cgImage.width))
let pixelScale = Double(cgImage.width) / pointsWide
let padding = 16.0
let rect = CGRect(
    x: max(0, (x - padding) * pixelScale),
    y: 0,  // 从屏幕顶上开始裁，带上菜单栏
    width: (w + padding * 2) * pixelScale,
    height: (y + h + padding) * pixelScale
).intersection(CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
guard let cropped = cgImage.cropping(to: rect) else { exit(1) }

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: canvasWidth, pixelsHigh: canvasHeight, bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
let canvas = NSRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current?.imageInterpolation = .high

// 背景：深蓝到紫的渐变，像桌面。
NSGradient(colors: [
    NSColor(calibratedRed: 0.10, green: 0.16, blue: 0.32, alpha: 1),
    NSColor(calibratedRed: 0.36, green: 0.22, blue: 0.48, alpha: 1),
])!.draw(in: canvas, angle: -35)

// 面板：放在右边，顶上对齐画布顶边（像从菜单栏弹出来），放不下时等比缩小。
let unit = Double(canvasWidth) / 1440  // 画布相对 1440 宽的倍数
let maxHeight = Double(canvasHeight) - 40 * unit
let maxWidth = Double(canvasWidth) * 0.55
var drawWidth = Double(cropped.width) / pixelScale * unit
var drawHeight = Double(cropped.height) / pixelScale * unit
let fit = min(1, maxHeight / drawHeight, maxWidth / drawWidth)
drawWidth *= fit
drawHeight *= fit
let panelRect = NSRect(
    x: Double(canvasWidth) - drawWidth - 120 * unit,
    y: Double(canvasHeight) - drawHeight,
    width: drawWidth,
    height: drawHeight
)
NSImage(cgImage: cropped, size: .zero).draw(in: panelRect)

// 说明文字：左边竖着居中。
if !caption.isEmpty {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineSpacing = 8 * unit
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 56 * unit, weight: .bold),
        .foregroundColor: NSColor.white,
        .paragraphStyle: paragraph,
    ]
    let text = NSAttributedString(string: caption.replacingOccurrences(of: "\\n", with: "\n"), attributes: attributes)
    let textWidth = panelRect.minX - 200 * unit
    let bounds = text.boundingRect(with: NSSize(width: textWidth, height: Double(canvasHeight)), options: [.usesLineFragmentOrigin])
    text.draw(with: NSRect(x: 100 * unit, y: (Double(canvasHeight) - bounds.height) / 2, width: textWidth, height: bounds.height),
              options: [.usesLineFragmentOrigin])
}
NSGraphicsContext.restoreGraphicsState()

try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
print("已保存 \(args[2])（\(canvasWidth)x\(canvasHeight)）")
