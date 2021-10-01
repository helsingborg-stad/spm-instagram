// swift-tools-version:5.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Instagram",
    platforms: [.iOS(.v13), .tvOS(.v13)],
    products: [
        .library(
            name: "Instagram",
            targets: ["Instagram"]),
    ],
    dependencies: [
        .package(name: "AutomatedFetcher", url: "https://github.com/helsingborg-stad/spm-automated-fetcher", from: "0.1.0"),
        .package(url: "https://github.com/kishikawakatsumi/KeychainAccess", from: "4.2.2")
    ],
    targets: [
        .target(
            name: "Instagram",
            dependencies: ["AutomatedFetcher","KeychainAccess"]),
        .testTarget(
            name: "InstagramTests",
            dependencies: ["Instagram"]),
    ]
)
