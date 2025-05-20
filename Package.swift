// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "OutspeedSwift",
    platforms: [
        .iOS(.v18),
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "OutspeedSwift",
            targets: ["OutspeedSwift"]),
    ],
    dependencies: [
        .package(url: "https://github.com/stasel/WebRTC.git", from: "130.0.0"),
        .package(url: "https://github.com/devicekit/DeviceKit.git", from: "5.0.0"),
        .package(url: "https://github.com/SwiftyJSON/SwiftyJSON", from: "5.0.2"),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "OutspeedSwift",
            dependencies: ["WebRTC", "DeviceKit"]
        ),
        .testTarget(
            name: "OutspeedSwiftTests",
            dependencies: ["OutspeedSwift"]
        ),
    ]
)
