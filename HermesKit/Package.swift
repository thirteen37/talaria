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
    targets: [
        .target(
            name: "HermesKit",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
        .testTarget(
            name: "HermesKitTests",
            dependencies: ["HermesKit"],
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
