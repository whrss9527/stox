// CI 辅助脚本：从整屏截图中裁出菜单栏按钮和面板所在区域，缩小后保存为 JPEG。
// 用法: swift scripts/ci-screenshot.swift <整屏.png> <输出.jpg> <x> <y> <w> <h> [最大宽度]
// 坐标为屏幕点（左上角原点），由 `Stox --show-panel` 打印的 STOX_DIAG 行给出。
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
let maxWidth = args.count >= 8 ? Double(args[7]) ?? 480 : 480

let pointsWide = Double(NSScreen.screens.first?.frame.width ?? CGFloat(cgImage.width))
let scale = Double(cgImage.width) / pointsWide
let padding = 12.0
let rect = CGRect(
    x: max(0, (x - padding) * scale),
    y: max(0, (y - padding) * scale),
    width: (w + padding * 2) * scale,
    height: (h + padding * 2) * scale
).intersection(CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
guard let cropped = cgImage.cropping(to: rect) else { exit(1) }

let outWidth = min(maxWidth, Double(cropped.width))
let outHeight = Double(cropped.height) * outWidth / Double(cropped.width)
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(outWidth), pixelsHigh: Int(outHeight), bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current?.imageInterpolation = .high
NSImage(cgImage: cropped, size: .zero).draw(in: NSRect(x: 0, y: 0, width: outWidth, height: outHeight))
NSGraphicsContext.restoreGraphicsState()
let quality = args.count >= 9 ? Double(args[8]) ?? 0.5 : 0.5
try rep.representation(using: .jpeg, properties: [.compressionFactor: quality])!.write(to: URL(fileURLWithPath: args[2]))
print("已保存 \(args[2])（\(Int(outWidth))x\(Int(outHeight))）")
