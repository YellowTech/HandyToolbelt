// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HandyToolbelt",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "HandyToolbeltApp", targets: ["HandyToolbeltApp"]), .executable(name: "handytoolbelt", targets: ["HandyToolbeltCLI"])],
    targets: [
        .target(name: "HandyToolbeltCore"),
        .target(name: "HandyToolbeltControl", dependencies: ["HandyToolbeltCore"]),
        .executableTarget(name: "HandyToolbeltCLI", dependencies: ["HandyToolbeltControl"]),
        .testTarget(name: "HandyToolbeltControlTests", dependencies: ["HandyToolbeltControl", "HandyToolbeltCLI"]),
        .executableTarget(name: "HandyToolbeltApp", dependencies: ["HandyToolbeltCore", "HandyToolbeltControl"], resources: [.copy("Resources/Toolbelt.pdf")]),
        .testTarget(name: "HandyToolbeltCoreTests", dependencies: ["HandyToolbeltCore"])
    ],
    swiftLanguageModes: [.v5]
)
