// 生成 App 图标的 .iconset 目录，再由 iconutil 转成 .icns。
// 用法: swift scripts/make-icon.swift <输出目录>/AppIcon.iconset
import AppKit

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write("用法: swift make-icon.swift <AppIcon.iconset>\n".data(using: .utf8)!)
    exit(2)
}
let output = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.restoreGraphicsState() }

    let size = CGFloat(pixels)
    // macOS 图标网格：内容区约占 80%，四周留白。
    let rect = NSRect(x: size * 0.1, y: size * 0.1, width: size * 0.8, height: size * 0.8)
    let background = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGradient(
        starting: NSColor(calibratedRed: 0.16, green: 0.17, blue: 0.24, alpha: 1),
        ending: NSColor(calibratedRed: 0.06, green: 0.07, blue: 0.11, alpha: 1)
    )!.draw(in: background, angle: -90)

    // 淡淡的网格线
    NSColor(white: 1, alpha: 0.07).setStroke()
    for i in 1...3 {
        let y = rect.minY + rect.height * CGFloat(i) / 4
        let line = NSBezierPath()
        line.move(to: NSPoint(x: rect.minX + rect.width * 0.1, y: y))
        line.line(to: NSPoint(x: rect.maxX - rect.width * 0.1, y: y))
        line.lineWidth = max(1, size * 0.006)
        line.stroke()
    }

    // 上涨折线（红涨）
    let values: [CGFloat] = [0.28, 0.40, 0.34, 0.52, 0.45, 0.63, 0.57, 0.76]
    let chart = NSBezierPath()
    for (index, value) in values.enumerated() {
        let point = NSPoint(
            x: rect.minX + rect.width * (0.14 + 0.72 * CGFloat(index) / CGFloat(values.count - 1)),
            y: rect.minY + rect.height * value
        )
        if index == 0 {
            chart.move(to: point)
        } else {
            chart.line(to: point)
        }
    }
    chart.lineWidth = max(1.5, size * 0.045)
    chart.lineCapStyle = .round
    chart.lineJoinStyle = .round
    NSColor(calibratedRed: 0.98, green: 0.30, blue: 0.27, alpha: 1).setStroke()
    chart.stroke()

    return rep.representation(using: .png, properties: [:])!
}

let variants: [(Int, String)] = [
    (16, "16x16"), (32, "16x16@2x"), (32, "32x32"), (64, "32x32@2x"), (128, "128x128"),
    (256, "128x128@2x"), (256, "256x256"), (512, "256x256@2x"), (512, "512x512"), (1024, "512x512@2x"),
]
for (pixels, name) in variants {
    try render(pixels: pixels).write(to: output.appendingPathComponent("icon_\(name).png"))
}
print("已生成 \(output.path)")
