// swift-tools-version:5.9
import PackageDescription

// StoxCore 与 stox-cli 不依赖 AppKit，可以在 Linux 上编译和测试；
// 菜单栏 App（Stox）只在 macOS 上声明。
var products: [Product] = [
    .library(name: "StoxCore", targets: ["StoxCore"]),
    .executable(name: "stox-cli", targets: ["StoxCLI"]),
]

var targets: [Target] = [
    .target(name: "StoxCore"),
    .executableTarget(name: "StoxCLI", dependencies: ["StoxCore"]),
    .testTarget(name: "StoxCoreTests", dependencies: ["StoxCore"], resources: [.copy("Fixtures")]),
]

#if os(macOS)
products.append(.executable(name: "Stox", targets: ["Stox"]))
targets.append(.executableTarget(name: "Stox", dependencies: ["StoxCore"]))
targets.append(.testTarget(name: "StoxTests", dependencies: ["Stox", "StoxCore"]))
#endif

let package = Package(
    name: "Stox",
    platforms: [.macOS(.v13)],
    products: products,
    targets: targets
)
