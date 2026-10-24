// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "FSKitHelloWorld",
    platforms: [.macOS("26.0")],
    products: [.library(name: "HelloFS", targets: ["HelloFS"])],
    targets: [.target(name: "HelloFS"), .testTarget(name: "HelloFSTests", dependencies: ["HelloFS"])],
    swiftLanguageModes: [.v5]
)
