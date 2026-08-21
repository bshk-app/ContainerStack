// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ContainerizationSpike",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/apple/containerization.git", exact: "0.40.2")
    ],
    targets: [
        .executableTarget(
            name: "Spike",
            dependencies: [
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerizationOCI", package: "containerization"),
                .product(name: "ContainerizationEXT4", package: "containerization"),
            ]
        )
    ]
)
