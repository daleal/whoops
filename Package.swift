// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "Whoops",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Whoops", targets: ["Whoops"])
    ],
    targets: [
        .executableTarget(
            name: "Whoops",
            path: "Sources/Whoops"
        ),
        .testTarget(
            name: "WhoopsTests",
            dependencies: ["Whoops"],
            path: "Tests/WhoopsTests"
        )
    ],
    swiftLanguageVersions: [.v5]
)
