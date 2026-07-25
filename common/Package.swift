// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "SonoraCommon",
    platforms: [
        .macOS(.v13),
        .iOS(.v16)
    ],
    products: [
        .library(
            name: "SonoraCommon",
            targets: ["SonoraCommon"]
        )
    ],
    targets: [
        .target(name: "SonoraCommon"),
        .testTarget(
            name: "SonoraCommonTests",
            dependencies: ["SonoraCommon"]
        )
    ]
)
