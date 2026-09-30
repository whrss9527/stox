// 从整屏截图做一张 App Store 截图：画布顶上是一条菜单栏（右边是截图里真实的那一段，带着 Stox 的行情和时钟），
// 下面是按圆角裁出来的面板，放在渐变的“桌面”上；左边可以写一句说明。
// App Store 的 Mac 截图只收 1280x800、1440x900、2560x1600、2880x1800 这几种尺寸（16:10），不能有透明。
//
// 用法: swift scripts/app-store-screenshot.swift <整屏.png> <输出.png> <x> <y> <w> <h> [画布宽 画布高] [说明文字]
// x y w h 是面板在屏幕上的位置（点，左上角原点），即 `Stox --show-panel` 打印的 STOX_DIAG panel_frame 的前四个数。
// 默认画布 1440x900。CI 的屏幕是 1 倍的，1440x900 里面板是原大小；2880x1800 要在 Retina 屏上截（见 docs/app-store/screenshots.md）。
import AppKit
import ImageIO

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

let args = CommandLine.arguments
guard args.count >= 7,
      let panelX = Double(args[3]), let panelY = Double(args[4]), let panelW = Double(args[5]), let panelH = Double(args[6]),
      let image = NSImage(contentsOf: URL(fileURLWithPath: args[1])),
      let screenshot = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
else { fail("参数错误或无法读取截图") }
let canvasWidth = args.count >= 9 ? Int(args[7]) ?? 1440 : 1440
let canvasHeight = args.count >= 9 ? Int(args[8]) ?? 900 : 900
let caption = args.count >= 10 ? args[9] : ""
let allowed = [(1280, 800), (1440, 900), (2560, 1600), (2880, 1800)]
guard allowed.contains(where: { $0 == (canvasWidth, canvasHeight) }) else {
    fail("App Store 不收 \(canvasWidth)x\(canvasHeight) 的截图")
}

// 截图的像素和屏幕点的比例（Retina 屏是 2），以及菜单栏的高度。
let screen = NSScreen.screens.first
let screenWidth = Double(screen?.frame.width ?? CGFloat(screenshot.width))
let pixelScale = Double(screenshot.width) / screenWidth
let menuBar = max(22, Double(screen.map { $0.frame.maxY - $0.visibleFrame.maxY } ?? 24))

/// 按屏幕点裁一块（左上角原点）。
func crop(x: Double, y: Double, width: Double, height: Double) -> CGImage {
    let rect = CGRect(x: x * pixelScale, y: y * pixelScale, width: width * pixelScale, height: height * pixelScale)
        .integral
        .intersection(CGRect(x: 0, y: 0, width: screenshot.width, height: screenshot.height))
    guard let image = screenshot.cropping(to: rect) else { fail("裁剪失败：\(rect)") }
    return image
}

// 面板右边到屏幕右边的距离（菜单栏上 Stox 右边的图标和时钟），太宽时截掉一些，免得面板挤到画布左边。
let rightGap = min(max(0, screenWidth - panelX - panelW), 420)
let stripLeft = max(0, panelX - 60)
let strip = crop(x: stripLeft, y: 0, width: panelX + panelW + rightGap - stripLeft, height: menuBar)
let panel = crop(x: panelX, y: panelY, width: panelW, height: panelH)

// 菜单栏的底色：取这段菜单栏最左边一列中间的颜色，铺满画布顶上。
let barColor: NSColor = {
    let rep = NSBitmapImageRep(cgImage: strip)
    return rep.colorAt(x: 1, y: rep.pixelsHigh / 2) ?? NSColor(white: 0.92, alpha: 1)
}()

// 不带透明通道：用 noneSkipLast 的位图画。
guard let context = CGContext(
    data: nil, width: canvasWidth, height: canvasHeight, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
) else { fail("建不了画布") }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
NSGraphicsContext.current?.imageInterpolation = .high

// 都用 CGFloat 算（和 Double 混用时运算符会有歧义）。画布坐标是左下角原点。
let width = CGFloat(canvasWidth)
let height = CGFloat(canvasHeight)
let unit = width / 1440  // 画布相对 1440 宽的倍数：1 个屏幕点画成 unit 个像素
let barHeight = CGFloat(menuBar) * unit

// 桌面：深蓝到紫的渐变。
NSGradient(colors: [
    NSColor(calibratedRed: 0.10, green: 0.16, blue: 0.32, alpha: 1),
    NSColor(calibratedRed: 0.36, green: 0.22, blue: 0.48, alpha: 1),
])!.draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: -35)

// 菜单栏：整条铺底色，右边贴上真实的那一段。
barColor.setFill()
NSRect(x: 0, y: height - barHeight, width: width, height: barHeight).fill()
let stripWidth = CGFloat(strip.width) / CGFloat(pixelScale) * unit
NSImage(cgImage: strip, size: .zero).draw(in: NSRect(x: width - stripWidth, y: height - barHeight, width: stripWidth, height: barHeight))

// 面板：和菜单栏上的位置对齐，按面板的圆角裁掉截到的背景，底下加一点阴影。放不下时等比缩小。
var drawWidth = CGFloat(panelW) * unit
var drawHeight = CGFloat(panelH) * unit
let top = CGFloat(panelY) * unit
let fit = min(1, (height - top - 20 * unit) / drawHeight)
drawWidth *= fit
drawHeight *= fit
let panelRect = NSRect(
    x: width - stripWidth + CGFloat(panelX - stripLeft) * unit,
    y: height - top - drawHeight,
    width: drawWidth,
    height: drawHeight
)
// 面板窗口比玻璃底每边大 8 点（PanelView 的 .padding(8)），玻璃底的圆角是 20 点：只留玻璃底，多裁半点免得露出截到的背景。
let glassInset = 8.5 * unit * fit
let glassRect = panelRect.insetBy(dx: glassInset, dy: glassInset)
let radius = 20 * unit * fit
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
shadow.shadowBlurRadius = 30 * unit
shadow.shadowOffset = NSSize(width: 0, height: -10 * unit)
shadow.set()
NSColor.black.setFill()
NSBezierPath(roundedRect: glassRect, xRadius: radius, yRadius: radius).fill()
NSGraphicsContext.restoreGraphicsState()
NSGraphicsContext.saveGraphicsState()
NSBezierPath(roundedRect: glassRect, xRadius: radius, yRadius: radius).addClip()
NSImage(cgImage: panel, size: .zero).draw(in: panelRect)
NSGraphicsContext.restoreGraphicsState()

// 说明文字：面板左边，竖着居中。
if !caption.isEmpty {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineSpacing = 8 * unit
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 56 * unit, weight: .bold),
        .foregroundColor: NSColor.white,
        .paragraphStyle: paragraph,
    ]
    let text = NSAttributedString(string: caption.replacingOccurrences(of: "\\n", with: "\n"), attributes: attributes)
    let textWidth = max(200 * unit, glassRect.minX - 180 * unit)
    let bounds = text.boundingRect(with: NSSize(width: textWidth, height: height), options: [.usesLineFragmentOrigin])
    text.draw(with: NSRect(x: 90 * unit, y: (height - barHeight - bounds.height) / 2, width: textWidth, height: bounds.height),
              options: [.usesLineFragmentOrigin])
}
NSGraphicsContext.restoreGraphicsState()

guard let output = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[2]) as CFURL, "public.png" as CFString, 1, nil)
else { fail("写不了 \(args[2])") }
CGImageDestinationAddImage(destination, output, nil)
guard CGImageDestinationFinalize(destination) else { fail("写不了 \(args[2])") }
print("已保存 \(args[2])（\(canvasWidth)x\(canvasHeight)）")
