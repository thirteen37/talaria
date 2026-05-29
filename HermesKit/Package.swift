// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "HermesKit",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(
            name: "HermesKit",
            targets: ["HermesKit"]
        ),
    ],
    dependencies: [
        // Pure-Swift SSH client. Required so HermesKit can talk to a remote
        // Hermes host on platforms (iOS) that have neither `/usr/bin/ssh` nor
        // `Process`. Snapshot transfer reuses the same SSH channel via an
        // `exec cat` request — no separate SFTP dependency.
        .package(url: "https://github.com/apple/swift-nio-ssh.git", from: "0.10.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        // YAML parser used by `HermesConfigDocument` to parse each profile's
        // `config.yaml` while preserving mapping order (so sections/keys render
        // in the same order Hermes emits them). Only HermesKit's parsing logic
        // depends on it; the app target reaches it transitively.
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0"),
    ],
    targets: [
        .target(
            name: "HermesKit",
            dependencies: [
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "Yams", package: "Yams"),
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
        .testTarget(
            name: "HermesKitTests",
            dependencies: [
                "HermesKit",
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
            ],
            resources: [
                .copy("Fixtures"),
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
