// App Store 截图：从整屏截图做一张 16:10 的图。顶上是一条菜单栏（右边是截图里真实的那一段，带着 Stox 的行情和时钟），
// 面板按原大小挂在它的菜单栏图标下面，按玻璃底的圆角裁出来，带阴影；左边是一行标题和两三行说明；底下是渐变的“桌面”。
// App Store 的 Mac 截图只收 1280x800、1440x900、2560x1600、2880x1800 这几种尺寸（16:10），不能有透明。
//
// 用法:
//   swift scripts/app-store-screenshot.swift <整屏.png> <输出.png> <x> <y> <w> <h>
//         [--size 1280x800] [--theme 1] [--title "标题"] [--subtitle "说明"]
//   swift scripts/app-store-screenshot.swift --wallpaper [--size 1280x800] [--theme 1] [图片.png]
//
// x y w h 是面板在屏幕上的位置（点，左上角原点），即 `Stox --show-panel` 打印的 STOX_DIAG panel_frame 的前四个数。
// 1280x800、1440x900 按 1 倍画（CI 的屏幕是 1 倍的，面板是原大小），2560x1600、2880x1800 按 2 倍画，要在 Retina 屏上截。
// --theme 选背景渐变（1 到 5，同一个色系，色相不同）。--wallpaper 把这种渐变设成桌面（截图前用）：面板的毛玻璃
// 透出来的就是同样的颜色，菜单栏也跟着变色，和合成的背景接得上。
import AppKit
import ImageIO

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

// MARK: - 参数

var positional: [String] = []
var canvasWidth = 1280
var canvasHeight = 800
var themeIndex = 1
var title = ""
var subtitle = ""
var wallpaperMode = false
var arguments = CommandLine.arguments.dropFirst().makeIterator()
func value(for option: String) -> String {
    guard let value = arguments.next() else { fail("\(option) 后面要跟一个值") }
    return value
}
while let argument = arguments.next() {
    switch argument {
    case "--size":
        let parts = value(for: argument).lowercased().split(separator: "x").compactMap { Int($0) }
        guard parts.count == 2 else { fail("--size 要写成 1280x800") }
        canvasWidth = parts[0]
        canvasHeight = parts[1]
    case "--theme":
        guard let index = Int(value(for: argument)), index >= 1 else { fail("--theme 是从 1 开始的数") }
        themeIndex = index
    case "--title":
        title = value(for: argument)
    case "--subtitle":
        subtitle = value(for: argument)
    case "--wallpaper":
        wallpaperMode = true
    default:
        if argument.hasPrefix("--") { fail("不认识的选项 \(argument)") }
        positional.append(argument)
    }
}
let allowed = [(1280, 800), (1440, 900), (2560, 1600), (2880, 1800)]
guard allowed.contains(where: { $0 == (canvasWidth, canvasHeight) }) else {
    fail("App Store 不收 \(canvasWidth)x\(canvasHeight) 的截图")
}

// 都用 CGFloat 算（和 Double 混用时运算符会有歧义）。
let width = CGFloat(canvasWidth)
let height = CGFloat(canvasHeight)
/// 1 个屏幕点画成几个像素：1280、1440 宽的是 1 倍，2560、2880 宽的是 2 倍。
let unit: CGFloat = canvasWidth >= 2560 ? 2 : 1
/// 字号、边距按 1280 宽的画布定，别的尺寸等比放大。
let textScale = width / 1280
/// 画布有多少个屏幕点宽、高。
let canvasPoints = NSSize(width: width / unit, height: height / unit)

// MARK: - 背景

/// 背景渐变：同一个色系（深色、饱和度一样），每张换一个色相。
struct Theme {
    let start: NSColor
    let end: NSColor
    let glow: NSColor

    init(_ index: Int) {
        let hues: [CGFloat] = [226, 210, 188, 244, 266]
        let hue = hues[(index - 1) % hues.count] / 360
        func wrap(_ value: CGFloat) -> CGFloat { value.truncatingRemainder(dividingBy: 1) }
        start = NSColor(hue: hue, saturation: 0.72, brightness: 0.20, alpha: 1)
        end = NSColor(hue: wrap(hue + 0.05), saturation: 0.62, brightness: 0.46, alpha: 1)
        glow = NSColor(hue: wrap(hue + 0.02), saturation: 0.45, brightness: 0.95, alpha: 1)
    }
}
let theme = Theme(themeIndex)

/// 在 rect（整张画布在当前坐标系里的位置，左下角原点）里画背景：左上深、右下亮的渐变，
/// 右上方面板后面一团柔和的光，左下角再暗一点，给左边的字压一压底。
func drawBackground(_ rect: NSRect) {
    NSGradient(starting: theme.start, ending: theme.end)!.draw(in: rect, angle: -55)
    let glowCenter = NSPoint(x: rect.minX + rect.width * 0.74, y: rect.minY + rect.height * 0.62)
    NSGradient(colors: [theme.glow.withAlphaComponent(0.30), theme.glow.withAlphaComponent(0.10), theme.glow.withAlphaComponent(0)],
               atLocations: [0, 0.45, 1], colorSpace: .sRGB)!
        .draw(fromCenter: glowCenter, radius: 0, toCenter: glowCenter, radius: rect.width * 0.55, options: [])
    let shadeCenter = NSPoint(x: rect.minX + rect.width * 0.05, y: rect.minY + rect.height * 0.05)
    NSGradient(colors: [NSColor.black.withAlphaComponent(0.28), NSColor.black.withAlphaComponent(0)])!
        .draw(fromCenter: shadeCenter, radius: 0, toCenter: shadeCenter, radius: rect.width * 0.6, options: [])
}

/// 不带透明通道的位图（noneSkipLast）。
func makeContext(width: Int, height: Int) -> CGContext {
    guard let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else { fail("建不了 \(width)x\(height) 的画布") }
    return context
}

func writePNG(_ context: CGContext, to path: String) {
    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil)
    else { fail("写不了 \(path)") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fail("写不了 \(path)") }
}

// MARK: - 设成桌面

// 屏幕右上角对着画布右上角（合成时菜单栏的右端和屏幕右边对齐，面板也就落在同样的位置上），
// 所以屏幕上每一点的桌面颜色和合成后那一点的背景一样。
if wallpaperMode {
    guard let mainScreen = NSScreen.screens.first else { fail("没有屏幕") }
    let scale = mainScreen.backingScaleFactor
    let size = mainScreen.frame.size
    let path = positional.first ?? NSTemporaryDirectory() + "stox-wallpaper-\(themeIndex).png"
    let wallpaper = makeContext(width: Int(size.width * scale), height: Int(size.height * scale))
    wallpaper.scaleBy(x: scale, y: scale)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: wallpaper, flipped: false)
    drawBackground(NSRect(
        x: size.width - canvasPoints.width, y: size.height - canvasPoints.height,
        width: canvasPoints.width, height: canvasPoints.height
    ))
    NSGraphicsContext.restoreGraphicsState()
    writePNG(wallpaper, to: path)
    do {
        try NSWorkspace.shared.setDesktopImageURL(URL(fileURLWithPath: path), for: mainScreen, options: [:])
    } catch {
        fail("设不了桌面：\(error.localizedDescription)")
    }
    print("桌面换成了第 \(themeIndex) 种渐变（\(path)）")
    exit(0)
}

// MARK: - 截图

guard positional.count == 6,
      let panelX = Double(positional[2]), let panelY = Double(positional[3]),
      let panelW = Double(positional[4]), let panelH = Double(positional[5]),
      let image = NSImage(contentsOf: URL(fileURLWithPath: positional[0])),
      let screenshot = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
else { fail("参数错误或无法读取截图（用法见文件开头）") }
let outputPath = positional[1]

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

// 菜单栏：从面板左边到屏幕右边这一段（Stox 的行情、右边的图标和时钟）。右边太宽时截掉一些，免得面板挤到画布左边。
let rightGap = min(max(0, screenWidth - panelX - panelW), 420)
let stripLeft = panelX
let stripRight = panelX + panelW + rightGap
let strip = crop(x: stripLeft, y: 0, width: stripRight - stripLeft, height: menuBar)
let panel = crop(x: panelX, y: panelY, width: panelW, height: panelH)
/// 屏幕上的点挪到画布上要加多少（点）：菜单栏这一段的右端对着画布右边。
let offsetX = Double(canvasPoints.width) - stripRight
let barHeight = CGFloat(menuBar) * unit
guard panelY + panelH + 8 <= Double(canvasPoints.height) else {
    fail("面板太高（\(Int(panelY + panelH)) 点），\(canvasWidth)x\(canvasHeight) 的画布放不下")
}
guard panelX + offsetX > 0 else { fail("面板太宽，放不进画布") }

let context = makeContext(width: canvasWidth, height: canvasHeight)
context.interpolationQuality = .high
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)

drawBackground(NSRect(x: 0, y: 0, width: width, height: height))

// 菜单栏：右边贴上真实的那一段；左边空着的部分用这一段最左边的一列铺满（菜单栏上下的深浅也照着来）。
let stripWidth = CGFloat(strip.width) / CGFloat(pixelScale) * unit
let stripRect = NSRect(x: width - stripWidth, y: height - barHeight, width: stripWidth, height: barHeight)
if let column = strip.cropping(to: CGRect(x: Int(2 * pixelScale), y: 0, width: 1, height: strip.height)) {
    context.interpolationQuality = .none
    context.draw(column, in: CGRect(x: 0, y: height - barHeight, width: stripRect.minX + 2 * unit, height: barHeight))
    context.interpolationQuality = .high
}
context.draw(strip, in: stripRect)

// 面板：原大小，挂在菜单栏图标下面；只留玻璃底（窗口比玻璃底每边大 8 点，见 PanelView 的 .padding(8)，
// 圆角 20 点，多裁半点免得露出截到的背景），整块投一层柔和的阴影。
let panelRect = NSRect(
    x: CGFloat(panelX + offsetX) * unit,
    y: height - CGFloat(panelY + panelH) * unit,
    width: CGFloat(panelW) * unit,
    height: CGFloat(panelH) * unit
)
let glassRect = panelRect.insetBy(dx: 8.5 * unit, dy: 8.5 * unit)
let radius = 20 * unit
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -16 * unit), blur: 44 * unit, color: NSColor.black.withAlphaComponent(0.42).cgColor)
context.beginTransparencyLayer(auxiliaryInfo: nil)
context.addPath(CGPath(roundedRect: glassRect, cornerWidth: radius, cornerHeight: radius, transform: nil))
context.clip()
context.draw(panel, in: panelRect)
context.endTransparencyLayer()
context.restoreGState()

// 标题和说明：左对齐，在菜单栏下面的区域里竖着居中，右边离面板留出一段。
let left = 80 * textScale
let right = glassRect.minX - 64 * textScale
let textWidth = right - left
guard textWidth > 240 * textScale else { fail("面板左边放不下文字（只有 \(Int(textWidth)) 像素宽）") }
func attributed(_ text: String, font: NSFont, color: NSColor, lineSpacing: CGFloat, kern: CGFloat) -> NSAttributedString {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineSpacing = lineSpacing
    paragraph.lineBreakMode = .byWordWrapping
    return NSAttributedString(string: text.replacingOccurrences(of: "\\n", with: "\n"), attributes: [
        .font: font, .foregroundColor: color, .paragraphStyle: paragraph, .kern: kern,
    ])
}
let titleText = attributed(title, font: .systemFont(ofSize: 50 * textScale, weight: .bold), color: .white,
                           lineSpacing: 2 * textScale, kern: -0.6 * textScale)
let subtitleText = attributed(subtitle, font: .systemFont(ofSize: 22 * textScale, weight: .regular),
                              color: NSColor.white.withAlphaComponent(0.8), lineSpacing: 7 * textScale, kern: 0)
let subtitleWidth = min(textWidth, 500 * textScale)
func measure(_ text: NSAttributedString, _ width: CGFloat) -> CGFloat {
    text.length == 0 ? 0 : ceil(text.boundingRect(with: NSSize(width: width, height: height), options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
}
let titleHeight = measure(titleText, textWidth)
let subtitleHeight = measure(subtitleText, subtitleWidth)
let gap: CGFloat = titleHeight > 0 && subtitleHeight > 0 ? 18 * textScale : 0
let block = titleHeight + gap + subtitleHeight
// 菜单栏下面那块的正中，稍微往上提一点，看起来才是居中。
let blockTop = (height - barHeight) / 2 + block / 2 + 10 * textScale
titleText.draw(with: NSRect(x: left, y: blockTop - titleHeight, width: textWidth, height: titleHeight),
               options: [.usesLineFragmentOrigin, .usesFontLeading])
subtitleText.draw(with: NSRect(x: left, y: blockTop - titleHeight - gap - subtitleHeight, width: subtitleWidth, height: subtitleHeight),
                  options: [.usesLineFragmentOrigin, .usesFontLeading])
NSGraphicsContext.restoreGraphicsState()

writePNG(context, to: outputPath)
print("已保存 \(outputPath)（\(canvasWidth)x\(canvasHeight)，面板 \(Int(panelW))x\(Int(panelH)) 点，文字 \(Int(textWidth)) 像素宽）")
