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
            name: "HermesKit"
        ),
        .testTarget(
            name: "HermesKitTests",
            dependencies: ["HermesKit"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
