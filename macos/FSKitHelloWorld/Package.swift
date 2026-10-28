// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "FSKitHelloWorld",
    platforms: [.macOS("26.0")],
    products: [.library(name: "HelloFS", targets: ["HelloFS"])],
    dependencies: [.package(path: "../MTPProbe")],
    targets: [
        .target(name: "HelloFS", dependencies: [.product(name: "MTPMetadataContracts", package: "MTPProbe")]),
        .testTarget(name: "HelloFSTests", dependencies: ["HelloFS", .product(name: "MTPMetadataContracts", package: "MTPProbe")])
    ],
    swiftLanguageModes: [.v5]
)
