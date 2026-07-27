// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "AroCommon",
    platforms: [
        .macOS(.v13),
        .iOS(.v16)
    ],
    products: [
        .library(
            name: "AroCommon",
            targets: ["AroCommon"]
        )
    ],
    targets: [
        .target(name: "AroCommon"),
        .testTarget(
            name: "AroCommonTests",
            dependencies: ["AroCommon"]
        )
    ]
)
