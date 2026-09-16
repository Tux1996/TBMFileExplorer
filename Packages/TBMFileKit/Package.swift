// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "TBMFileKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TBMFileKit", targets: ["TBMFileKit"])
    ],
    targets: [
        .target(name: "TBMFileKit"),
        .testTarget(name: "TBMFileKitTests", dependencies: ["TBMFileKit"])
    ]
)
