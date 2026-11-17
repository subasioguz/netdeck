// swift-tools-version: 6.1
//
// SwiftNIO SSH 0.15.1 (https://github.com/apple/swift-nio-ssh, commit d1985926494b624e751b379009dc83f3395fd88a),
// vendored with the patches listed in PATCHES.md so the embedded client can reach older network gear.
// Licensed under Apache License v2.0 (LICENSE.txt).
import PackageDescription

let package = Package(
    name: "swift-nio-ssh",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "NIOSSH", targets: ["NIOSSH"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", "1.0.0"..<"6.0.0"),
        .package(url: "https://github.com/apple/swift-atomics.git", from: "1.0.2"),
    ],
    targets: [
        .target(
            name: "NIOSSH",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "Atomics", package: "swift-atomics"),
            ],
            swiftSettings: [
                .enableUpcomingFeature("MemberImportVisibility"),
                // Optimised in debug builds too: key exchange arithmetic is ~20x slower unoptimised.
                .unsafeFlags(["-O"], .when(configuration: .debug)),
            ]
        )
    ]
)
