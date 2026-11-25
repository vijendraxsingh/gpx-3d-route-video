// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "GPXRouteVideo",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "GPXRouteVideo", targets: ["GPXRouteVideo"])
    ],
    targets: [
        .executableTarget(name: "GPXRouteVideo"),
        .testTarget(name: "GPXRouteVideoTests", dependencies: ["GPXRouteVideo"])
    ]
)
