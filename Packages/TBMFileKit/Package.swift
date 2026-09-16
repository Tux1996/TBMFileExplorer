// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "TBMFileKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TBMFileKit", targets: ["TBMFileKit"])
    ],
    dependencies: [
        .package(url: "https://github.com/orlandos-nl/Citadel.git", from: "0.8.0")
    ],
    targets: [
        .target(name: "TBMFileKit", dependencies: ["Citadel"]),
        .testTarget(name: "TBMFileKitTests", dependencies: ["TBMFileKit"])
    ]
)
