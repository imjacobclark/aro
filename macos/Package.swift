// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "AroMac",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(
            name: "Aro",
            targets: ["Aro"]
        )
    ],
    dependencies: [
        .package(path: "../common"),
        .package(
            url: "https://github.com/sbooth/SFBAudioEngine.git",
            exact: "0.13.0"
        ),
        .package(
            url: "https://github.com/acumen-dev/matter-swift.git",
            exact: "1.0.0-beta.3"
        )
    ],
    targets: [
        .executableTarget(
            name: "Aro",
            dependencies: [
                "AroStreamingInput",
                .product(
                    name: "AroCommon",
                    package: "common"
                ),
                .product(
                    name: "SFBAudioEngine",
                    package: "SFBAudioEngine"
                ),
                .product(
                    name: "MatterController",
                    package: "matter-swift"
                )
            ],
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .target(
            name: "AroStreamingInput",
            dependencies: [
                .product(
                    name: "SFBAudioEngine",
                    package: "SFBAudioEngine"
                )
            ],
            publicHeadersPath: "include"
        ),
        .testTarget(
            name: "AroTests",
            dependencies: [
                "Aro",
                "AroStreamingInput",
                .product(
                    name: "AroCommon",
                    package: "common"
                )
            ]
        )
    ]
)
