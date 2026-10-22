// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "preowned",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "preowned", targets: ["preowned"]),
        .library(name: "PreownedKit", targets: ["PreownedKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.6.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird", from: "2.16.0"),
    ],
    targets: [
        .target(
            name: "PreownedKit",
            dependencies: [
                .product(name: "Hummingbird", package: "hummingbird")
            ]
        ),
        .executableTarget(
            name: "preowned",
            dependencies: [
                "PreownedKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Hummingbird", package: "hummingbird"),
            ]
        ),
        .testTarget(
            name: "PreownedKitTests",
            dependencies: [
                "PreownedKit",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdTesting", package: "hummingbird"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
