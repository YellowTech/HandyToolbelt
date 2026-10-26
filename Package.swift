// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SuperTrackpad",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "SuperTrackpad", targets: ["SuperTrackpad"]), .executable(name: "supertools", targets: ["supertools"])],
    targets: [
        .target(name: "SuperTrackpadCore"),
        .target(name: "SuperToolsControl", dependencies: ["SuperTrackpadCore"]),
        .executableTarget(name: "supertools", dependencies: ["SuperToolsControl"]),
        .testTarget(name: "SuperToolsControlTests", dependencies: ["SuperToolsControl", "supertools"]),
        .executableTarget(name: "SuperTrackpad", dependencies: ["SuperTrackpadCore", "SuperToolsControl"], resources: [.copy("Resources/Toolbelt.pdf")]),
        .testTarget(name: "SuperTrackpadCoreTests", dependencies: ["SuperTrackpadCore"])
    ],
    swiftLanguageModes: [.v5]
)
