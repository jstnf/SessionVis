// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SessionVis",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SessionVisCore", targets: ["SessionVisCore"]),
        .executable(name: "SessionVis", targets: ["SessionVis"]),
        .executable(name: "IconGen", targets: ["IconGen"]),
    ],
    targets: [
        .target(name: "SessionVisCore"),
        .executableTarget(name: "SessionVis", dependencies: ["SessionVisCore"]),
        .executableTarget(name: "IconGen", dependencies: ["SessionVisCore"]),
        .testTarget(name: "SessionVisCoreTests", dependencies: ["SessionVisCore"]),
    ],
    swiftLanguageModes: [.v6]
)
