// swift-tools-version: 6.2
import PackageDescription

/// Settings shared by every target: Swift 6 language mode, warnings are errors,
/// and the upcoming features we want on from day one.
let sharedSwiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .treatAllWarnings(as: .error),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("InferIsolatedConformances"),
]

/// The app target additionally defaults to the main actor. Per SE-0466 this
/// does not reach inside `actor` declarations, so the pasteboard poller stays
/// off the main actor without further annotation.
let appSwiftSettings: [SwiftSetting] = sharedSwiftSettings + [
    .defaultIsolation(MainActor.self)
]

let package = Package(
    name: "Clippy",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Clippy", targets: ["Clippy"]),
        .library(name: "ClippyCore", targets: ["ClippyCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "3.0.1")
    ],
    targets: [
        .target(
            name: "ClippyCore",
            swiftSettings: sharedSwiftSettings
        ),
        .executableTarget(
            name: "Clippy",
            dependencies: [
                "ClippyCore",
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
            ],
            // scripts/bundle.sh copies Resources/ straight into the .app, so
            // SwiftPM must not also process it into a resource bundle.
            exclude: ["Resources"],
            swiftSettings: appSwiftSettings
        ),
        .testTarget(
            name: "ClippyCoreTests",
            dependencies: ["ClippyCore"],
            swiftSettings: sharedSwiftSettings
        ),
    ]
)
