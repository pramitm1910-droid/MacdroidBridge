// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MTPProbe",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "MTPProbeLib", targets: ["MTPProbeLib"]),
        .library(name: "MTPMetadataContracts", targets: ["MTPMetadataContracts"])
    ],
    targets: [
        .target(name: "MTPMetadataContracts", path: "Sources/MTPMetadataContracts"),
        // The runnable CLI tool
        .executableTarget(
            name: "MTPProbe",
            dependencies: ["MTPProbeLib"],
            path: "Sources/MTPProbe",
            linkerSettings: [
                .linkedFramework("IOUSBHost"),
                .linkedFramework("IOKit"),
                .linkedFramework("Foundation"),
            ]
        ),
        // Pure-Swift MTP packet construction/parsing — no USB hardware dependency.
        // Imported by MTPProbe and independently unit-testable.
        .target(
            name: "MTPProbeLib",
            dependencies: ["MTPMetadataContracts"],
            path: "Sources/MTPProbeLib"
        ),
        .testTarget(
            name: "MTPProbeTests",
            dependencies: ["MTPProbeLib", "MTPMetadataContracts"],
            path: "Tests/MTPProbeTests"
        ),
    ]
)
