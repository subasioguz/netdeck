// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Netdeck",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Netdeck", targets: ["Netdeck"]),
        .executable(name: "netdeck-probe", targets: ["netdeck-probe"]),
        .library(name: "NetdeckCore", targets: ["NetdeckCore"]),
    ],
    targets: [
        .target(name: "NetdeckCore", resources: [.process("Resources")]),
        .executableTarget(name: "Netdeck", dependencies: ["NetdeckCore"]),
        .executableTarget(name: "netdeck-probe", dependencies: ["NetdeckCore"]),
        .testTarget(
            name: "NetdeckCoreTests",
            dependencies: ["NetdeckCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
