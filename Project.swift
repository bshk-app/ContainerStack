import ProjectDescription

let teamID = "Q8H6GWJ658"
let commonSettings: SettingsDictionary = [
    "CODE_SIGN_STYLE": "Automatic",
    "CODE_SIGN_IDENTITY": "Apple Development",
    "DEVELOPMENT_TEAM": .string(teamID),
    "MACOSX_DEPLOYMENT_TARGET": "26.0",
    "SWIFT_VERSION": "6.0",
]

let appBundleSupportScript = """
    set -euo pipefail
    helpers="$TARGET_BUILD_DIR/$WRAPPER_NAME/Contents/Helpers"
    agents="$TARGET_BUILD_DIR/$WRAPPER_NAME/Contents/Library/LaunchAgents"
    mkdir -p "$helpers" "$agents"
    cp "$BUILT_PRODUCTS_DIR/ContainerStackRuntime" "$helpers/ContainerStackRuntime"
    cp "$SRCROOT/Packaging/com.containerstack.runtime.plist.in" "$agents/com.containerstack.runtime.plist"
    if [ -n "${CONTAINERSTACK_SOCKTAINER_BINARY:-}" ]; then
        cp "$CONTAINERSTACK_SOCKTAINER_BINARY" "$helpers/socktainer"
    elif [ -x "$HOME/.local/bin/socktainer" ]; then
        cp "$HOME/.local/bin/socktainer" "$helpers/socktainer"
    else
        echo "warning: Socktainer binary was not staged; set CONTAINERSTACK_SOCKTAINER_BINARY before building the app"
    fi
    """

let project = Project(
    name: "ContainerStack",
    settings: .settings(
        base: commonSettings,
        configurations: [
            .debug(name: "Debug"),
            .release(name: "Release"),
        ],
        defaultSettings: .recommended
    ),
    targets: [
        .target(
            name: "ContainerStackCore",
            destinations: .macOS,
            product: .staticFramework,
            bundleId: "com.containerstack.core",
            sources: ["Sources/ContainerStackCore/**"]
        ),
        .target(
            name: "ContainerStack",
            destinations: .macOS,
            product: .app,
            bundleId: "app.bshk.containerstack",
            infoPlist: .extendingDefault(with: [
                "CFBundleDisplayName": "ContainerStack",
                "LSUIElement": false,
                "LSMultipleInstancesProhibited": true,
                "NSHighResolutionCapable": true,
            ]),
            sources: ["Sources/ContainerStackApp/**"],
            resources: ["Resources/**", "Sources/ContainerStackApp/Resources/**"],
            scripts: [
                .post(
                    script: appBundleSupportScript,
                    name: "Stage runtime helper and LaunchAgent",
                    inputPaths: [
                        "Packaging/com.containerstack.runtime.plist.in"
                    ],
                    basedOnDependencyAnalysis: false
                )
            ],
            dependencies: [
                .target(name: "ContainerStackCore"),
                .target(name: "ContainerStackRuntime"),
            ]
        ),
        .target(
            name: "cstack",
            destinations: .macOS,
            product: .commandLineTool,
            bundleId: "com.containerstack.cli",
            sources: ["Sources/CStackCLI/**"],
            dependencies: [.target(name: "ContainerStackCore")]
        ),
        .target(
            name: "ContainerStackRuntime",
            destinations: .macOS,
            product: .commandLineTool,
            bundleId: "com.containerstack.runtime",
            sources: ["Sources/ContainerStackRuntime/**"],
            dependencies: [.target(name: "ContainerStackCore")]
        ),
        .target(
            name: "ContainerStackCoreTests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "com.containerstack.core-tests",
            sources: ["Tests/ContainerStackCoreTests/**"],
            dependencies: [.target(name: "ContainerStackCore")]
        ),
    ],
    schemes: [
        .scheme(
            name: "ContainerStackTests",
            shared: true,
            buildAction: .buildAction(targets: ["ContainerStackCore"]),
            testAction: .targets(["ContainerStackCoreTests"])
        )
    ]
)
