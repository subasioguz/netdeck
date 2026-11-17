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
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.99.0"),
        .package(url: "https://github.com/apple/swift-nio-ssh.git", from: "0.15.1"),
    ],
    targets: [
        .target(
            name: "NetdeckCore",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
            ],
            resources: [.process("Resources")]
        ),
        .executableTarget(name: "Netdeck", dependencies: ["NetdeckCore"]),
        .executableTarget(name: "netdeck-probe", dependencies: ["NetdeckCore"]),
        .testTarget(
            name: "NetdeckCoreTests",
            dependencies: [
                "NetdeckCore",
                // An in-process SSH server for the embedded client's tests.
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
            ],
            resources: [.copy("Fixtures")]
        ),
    ]
)
