// swift-tools-version:5.9
import PackageDescription

// StoxCore 与 stox-cli 不依赖 AppKit，可以在 Linux 上编译和测试；
// 菜单栏 App（Stox）只在 macOS 上声明。
var products: [Product] = [
    .library(name: "StoxCore", targets: ["StoxCore"]),
    .executable(name: "stox-cli", targets: ["StoxCLI"]),
]

var targets: [Target] = [
    .target(name: "StoxCore", dependencies: [.product(name: "FritCore", package: "Frit")], resources: [.copy("DatasourceSnapshots")]),
    .executableTarget(name: "StoxCLI", dependencies: ["StoxCore", .product(name: "FritCore", package: "Frit")]),
    .testTarget(name: "StoxCoreTests", dependencies: ["StoxCore", .product(name: "FritCore", package: "Frit")], resources: [.copy("Fixtures")]),
]

#if os(macOS)
products.append(.executable(name: "Stox", targets: ["Stox"]))
targets.append(.executableTarget(name: "Stox", dependencies: ["StoxCore", .product(name: "FritUpdate", package: "Frit")]))
targets.append(.testTarget(name: "StoxTests", dependencies: ["Stox", "StoxCore", .product(name: "FritUpdate", package: "Frit")]))
#endif

let package = Package(
    name: "Stox",
    platforms: [.macOS(.v13)],
    products: products,
    dependencies: [.package(url: "https://github.com/whrss9527/Frit", exact: "0.4.2")],
    targets: targets
)
