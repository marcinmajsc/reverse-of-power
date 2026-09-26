// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ReverseOfPowerCore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "ReverseOfPowerCore", targets: ["ReverseOfPowerCore"])],
    targets: [
        .target(name: "ReverseOfPowerCore", path: "Sources/Core"),
        .testTarget(name: "ReverseOfPowerCoreTests", dependencies: ["ReverseOfPowerCore"], path: "Tests")
    ]
)
