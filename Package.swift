// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "MacFSW",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "MacFSWCore", targets: ["MacFSWCore"]),
        .library(name: "MacFSWAnalysis", targets: ["MacFSWAnalysis"]),
        .library(name: "MacFSWSystemExtension", targets: ["MacFSWSystemExtension"]),
        .executable(name: "MacFSWApp", targets: ["MacFSWApp"]),
        .executable(name: "MacFSWEndpointExtension", targets: ["MacFSWEndpointExtension"]),
        .executable(name: "macfsw", targets: ["MacFSWCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.10.0"),
        .package(url: "https://github.com/Lakr233/MarkdownView", from: "3.6.0"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", .upToNextMinor(from: "0.12.1")),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.0"),
    ],
    targets: [
        .target(
            name: "MacFSWCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .target(
            name: "MacFSWAnalysis",
            dependencies: ["MacFSWCore"],
            linkerSettings: [
                .linkedFramework("Security")
            ]
        ),
        .executableTarget(
            name: "MacFSWApp",
            dependencies: [
                "MacFSWCore",
                "MacFSWAnalysis",
                .product(name: "MarkdownView", package: "MarkdownView"),
            ],
            resources: [
                .process("Resources/MacFSW-AppIcon.icns"),
            ],
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedFramework("SystemExtensions")
            ]
        ),
        .target(
            name: "MacFSWSystemExtension",
            dependencies: ["MacFSWCore"],
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedLibrary("EndpointSecurity"),
                .linkedLibrary("bsm")
            ]
        ),
        .executableTarget(
            name: "MacFSWEndpointExtension",
            dependencies: ["MacFSWSystemExtension"],
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedLibrary("EndpointSecurity"),
                .linkedLibrary("bsm")
            ]
        ),
        .target(
            name: "MacFSWCommands",
            dependencies: ["MacFSWCore"]
        ),
        .executableTarget(
            name: "MacFSWCLI",
            dependencies: [
                "MacFSWCommands",
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "MacFSWCoreTests",
            dependencies: ["MacFSWCore"]
        ),
        .testTarget(
            name: "MacFSWAnalysisTests",
            dependencies: ["MacFSWAnalysis"]
        ),
        .testTarget(
            name: "MacFSWAppTests",
            dependencies: ["MacFSWApp"]
        ),
        .testTarget(
            name: "MacFSWCommandsTests",
            dependencies: ["MacFSWCommands"]
        ),
        .testTarget(
            name: "MacFSWCLITests",
            dependencies: [
                "MacFSWCLI",
                .product(name: "MCP", package: "swift-sdk"),
            ]
        ),
        .testTarget(
            name: "MacFSWSystemExtensionTests",
            dependencies: ["MacFSWSystemExtension"]
        ),
    ]
)
