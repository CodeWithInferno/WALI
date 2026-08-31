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
            name: "WALIEngine",
            type: .static,
            targets: ["WALIEngine"]
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
            name: "WALIEngine",
            dependencies: ["WALIModel"],
            path: "Sources/WALIEngine"
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
            name: "WALIEngineTests",
            dependencies: ["WALIEngine"],
            path: "Tests/WALIEngineTests"
        )
    ],
    swiftLanguageModes: [.v6]
)

