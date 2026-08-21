// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ContainerStack",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .library(
            name: "ContainerStackCore",
            targets: ["ContainerStackCore"]
        ),
        .executable(
            name: "ContainerStack",
            targets: ["ContainerStackApp"]
        ),
        .executable(
            name: "cstack",
            targets: ["CStackCLI"]
        ),
        .executable(
            name: "ContainerStackRuntime",
            targets: ["ContainerStackRuntime"]
        ),
    ],
    targets: [
        .target(name: "ContainerStackCore"),
        .executableTarget(
            name: "ContainerStackApp",
            dependencies: ["ContainerStackCore"],
            resources: [.copy("Resources/Lucide")]
        ),
        .executableTarget(
            name: "CStackCLI",
            dependencies: ["ContainerStackCore"]
        ),
        .executableTarget(
            name: "ContainerStackRuntime",
            dependencies: ["ContainerStackCore"]
        ),
        .testTarget(
            name: "ContainerStackCoreTests",
            dependencies: ["ContainerStackCore"]
        ),
        .testTarget(
            name: "ContainerStackAppTests",
            dependencies: ["ContainerStackApp"],
            path: "Tests/ContainerStackAppTests"
        ),
    ]
)
