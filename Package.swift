// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "DisplayAnchor",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .executable(name: "DisplayAnchor", targets: ["DisplayAnchor"])
    ],
    targets: [
        .target(name: "DisplayAnchorCore"),
        .executableTarget(
            name: "DisplayAnchor",
            dependencies: ["DisplayAnchorCore"]
        ),
        .testTarget(
            name: "DisplayAnchorCoreTests",
            dependencies: ["DisplayAnchorCore"]
        )
    ]
)
