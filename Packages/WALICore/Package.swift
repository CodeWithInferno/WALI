// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "WALICore",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "WALIModel",
            type: .static,
            targets: ["WALIModel"]
        ),
        .library(
            name: "WALIWire",
            type: .static,
            targets: ["WALIWire"]
        ),
        .library(
            name: "WALILockScreenWire",
            type: .static,
            targets: ["WALILockScreenWire"]
        ),
        .library(
            name: "WALIEngine",
            type: .static,
            targets: ["WALIEngine"]
        ),
        .library(
            name: "WALICatalog",
            type: .static,
            targets: ["WALICatalog"]
        )
    ],
    targets: [
        .target(
            name: "WALIModel",
            path: "Sources/WALIModel"
        ),
        .target(
            name: "WALIWire",
            dependencies: ["WALIModel"],
            path: "Sources/WALIWire"
        ),
        .target(
            name: "WALILockScreenWire",
            path: "Sources/WALILockScreenWire"
        ),
        .target(
            name: "WALIEngine",
            dependencies: ["WALIModel"],
            path: "Sources/WALIEngine"
        ),
        .target(
            name: "WALICatalog",
            dependencies: ["WALIModel"],
            path: "Sources/WALICatalog"
        ),
        .testTarget(
            name: "WALIModelTests",
            dependencies: ["WALIModel"],
            path: "Tests/WALIModelTests",
            resources: [
                .process("Fixtures")
            ]
        ),
        .testTarget(
            name: "WALIWireTests",
            dependencies: ["WALIWire"],
            path: "Tests/WALIWireTests"
        ),
        .testTarget(
            name: "WALILockScreenWireTests",
            dependencies: ["WALILockScreenWire"],
            path: "Tests/WALILockScreenWireTests"
        ),
        .testTarget(
            name: "WALIEngineTests",
            dependencies: ["WALIEngine"],
            path: "Tests/WALIEngineTests"
        ),
        .testTarget(
            name: "WALICatalogTests",
            dependencies: ["WALICatalog"],
            path: "Tests/WALICatalogTests"
        )
    ],
    swiftLanguageModes: [.v6]
)
