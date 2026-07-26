// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "SonoraMac",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(
            name: "Sonora",
            targets: ["Sonora"]
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
            name: "Sonora",
            dependencies: [
                .product(
                    name: "SonoraCommon",
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
        .testTarget(
            name: "SonoraTests",
            dependencies: [
                "Sonora",
                .product(
                    name: "SonoraCommon",
                    package: "common"
                )
            ]
        )
    ]
)
