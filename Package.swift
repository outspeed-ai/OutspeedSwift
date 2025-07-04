// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "OutspeedSwift",
    platforms: [
        .iOS(.v15),
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "OutspeedSDK",
            targets: ["OutspeedSDK"]),
    ],
    dependencies: [
        .package(url: "https://github.com/stasel/WebRTC.git", from: "130.0.0"),
        .package(url: "https://github.com/devicekit/DeviceKit.git", from: "5.0.0"),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "OutspeedSDK",
            dependencies: ["WebRTC", "DeviceKit"]
        ),
        .testTarget(
            name: "OutspeedSDKTests",
            dependencies: ["OutspeedSDK"]
        ),
    ]
)
