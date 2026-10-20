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
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.6")
    ],
    targets: [
        .target(name: "ContainerStackCore"),
        .executableTarget(
            name: "ContainerStackApp",
            dependencies: [
                "ContainerStackCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            resources: [.copy("Resources/Lucide")],
            linkerSettings: [
                // SwiftPM links the XCFramework from its build cache, which does
                // not exist on a user's machine. The staged bundle carries the
                // framework in Contents/Frameworks, so the shipped binary has to
                // look there; stage-containerstack-app.sh asserts it arrived.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        ),
        .executableTarget(
            name: "CStackCLI",
            dependencies: ["ContainerStackCore"]
        ),
        .executableTarget(
            name: "ContainerStackRuntime",
            dependencies: ["ContainerStackCore"]
        ),
        // Fakes both test targets share: SwiftPM lets no test target import another.
        // No product lists it, so it never ships; only the test targets build it.
        .target(
            name: "DiagnosticTestSupport",
            dependencies: ["ContainerStackCore"],
            path: "Tests/DiagnosticTestSupport"
        ),
        .testTarget(
            name: "ContainerStackCoreTests",
            dependencies: ["ContainerStackCore", "DiagnosticTestSupport"]
        ),
        .testTarget(
            name: "ContainerStackAppTests",
            dependencies: ["ContainerStackApp", "DiagnosticTestSupport"],
            path: "Tests/ContainerStackAppTests"
        ),
    ]
)
