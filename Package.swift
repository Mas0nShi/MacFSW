// swift-tools-version: 6.0

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
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.10.0"),
        .package(url: "https://github.com/Lakr233/MarkdownView", from: "3.6.0"),
    ],
    targets: [
        .target(
            name: "MacFSWCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .target(
            name: "MacFSWAnalysis",
            dependencies: ["MacFSWCore"],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ],
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
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ],
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedFramework("SystemExtensions")
            ]
        ),
        .target(
            name: "MacFSWSystemExtension",
            dependencies: ["MacFSWCore"],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ],
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedLibrary("EndpointSecurity"),
                .linkedLibrary("bsm")
            ]
        ),
        .executableTarget(
            name: "MacFSWEndpointExtension",
            dependencies: ["MacFSWSystemExtension"],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ],
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedLibrary("EndpointSecurity"),
                .linkedLibrary("bsm")
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
            name: "MacFSWSystemExtensionTests",
            dependencies: ["MacFSWSystemExtension"]
        ),
    ]
)
