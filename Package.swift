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
    name: "Skrepka",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "SkrepkaCore", targets: ["SkrepkaCore"]),
        .library(name: "SkrepkaSync", targets: ["SkrepkaSync"]),
        // The Linux build surface. A bare `swift build` on Linux tries to build
        // the app target and its macOS-only KeyboardShortcuts dependency, so the
        // Linux gate builds this product instead.
        //
        // `type:` is not decoration. An automatic library product is refused by
        // `swift build --product` — "'--product' cannot be used with the
        // automatic product 'SkrepkaLinux'; building the default target
        // instead" — and the fallback is exactly the everything-build this
        // product exists to avoid, KeyboardShortcuts and all.
        .library(name: "SkrepkaLinux", type: .static, targets: ["SkrepkaCore", "SkrepkaSync"]),
        .executable(name: "skrepka-sync-probe", targets: ["skrepka-sync-probe"]),
    ],
    dependencies: [
        // SHA-256 for device identity and the short authentication string.
        // Source-identical to CryptoKit on Apple platforms; the only reason it
        // is here is that Linux has no CryptoKit.
        .package(url: "https://github.com/apple/swift-crypto", from: "4.5.2"),
        // `os.Logger` has no Linux equivalent. Linux-only, so the macOS build
        // keeps logging through the platform's own facility.
        .package(url: "https://github.com/apple/swift-log", from: "1.15.0"),
        // One transport on both platforms. Network framework is the native
        // answer on macOS and D-9 would normally insist on it, but writing
        // pinned-certificate verification twice is the worst duplication
        // available: a callback that silently verifies nothing looks identical
        // to one that works. macOS keeps the native half that actually differs
        // — NWPathMonitor for sleep, wake, Wi-Fi and VPN transitions — over one
        // NIO transport underneath.
        .package(url: "https://github.com/apple/swift-nio", from: "2.102.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl", from: "2.37.4"),
        // Self-signed P-256 device certificates. SyncDeviceID is SHA-256 over
        // the DER encoding, so this package decides the device's identity.
        .package(url: "https://github.com/apple/swift-certificates", from: "1.20.0"),
    ],
    targets: [
        // The system SQLite, for the Linux history store (D-3). macOS ships a
        // `SQLite3` module in its SDK and never resolves this one — SkrepkaCore
        // depends on it only `.when(platforms: [.linux])` — so no macOS build
        // asks pkg-config for a `sqlite3.pc` Apple does not ship.
        //
        // `providers:` is what turns a missing package into a message naming it
        // rather than a link failure. docker/Dockerfile.linux installs
        // libsqlite3-dev so the containerised gate needs neither.
        .systemLibrary(
            name: "CSQLite",
            pkgConfig: "sqlite3",
            providers: [.apt(["libsqlite3-dev"]), .yum(["sqlite-devel"])]
        ),
        .target(
            name: "SkrepkaCore",
            dependencies: [
                .target(name: "CSQLite", condition: .when(platforms: [.linux])),
                // The store's sync surface speaks SyncClipMeta, MergeAction and
                // Tombstone. The edge only points this way — SkrepkaSync
                // deliberately depends on nothing here, which is what keeps it
                // compiling on Linux ahead of SkrepkaCore.
                "SkrepkaSync",
                .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux])),
                .product(name: "Logging", package: "swift-log", condition: .when(platforms: [.linux])),
            ],
            swiftSettings: sharedSwiftSettings
        ),
        // The portable protocol core: model, wire codec, merge engine. Must
        // compile on Linux from the day it was created, which is why it depends
        // on nothing platform-specific and — deliberately — not on SkrepkaCore.
        .target(
            name: "SkrepkaSync",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "X509", package: "swift-certificates"),
            ],
            swiftSettings: sharedSwiftSettings
        ),
        .testTarget(
            name: "SkrepkaCoreTests",
            dependencies: [
                "SkrepkaCore", "SkrepkaSync",
                // `ProbeContentHashTests` is the one test that links the probe
                // and the real store, because the probe reproduces
                // `ClipItem.contentHash` without being able to see it.
                "SkrepkaProbe",
                // `ClipItemTests` pins `contentHash` to literal digests on both
                // platforms, so it needs the same SHA-256 `ClipItem` linked.
                .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux])),
            ],
            swiftSettings: sharedSwiftSettings
        ),
        // A headless second peer, for exercising sync by hand. Depends on
        // `SkrepkaSync` and deliberately *not* on `SkrepkaCore`, so it stays
        // buildable on Linux and becomes the Phase 6 smoke-test binary for
        // free — and so it can never accidentally reach a pasteboard, which is
        // the whole point of it.
        //
        // A library plus a thin executable rather than one executable target:
        // `swift test` cannot import an executable, and `ProbeStore` is the
        // second `HistoryStoring` conformance the shared contract suite runs
        // against.
        .target(
            name: "SkrepkaProbe",
            dependencies: [
                "SkrepkaSync",
                // The probe reproduces `ClipItem`'s content hash, which is
                // SHA-256, so it needs the same implementation linked.
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            swiftSettings: sharedSwiftSettings
        ),
        .executableTarget(
            name: "skrepka-sync-probe",
            dependencies: ["SkrepkaProbe"],
            swiftSettings: sharedSwiftSettings
        ),
        .testTarget(
            name: "SkrepkaSyncTests",
            dependencies: ["SkrepkaSync", "SkrepkaProbe"],
            swiftSettings: sharedSwiftSettings
        ),
    ]
)

// The app target is fenced out of the manifest on Linux rather than left in and
// skipped, because `swift test` has neither `--product` nor `--target`: it
// builds the whole package or nothing. Leaving `Skrepka` declared means every
// Linux test run compiles its KeyboardShortcuts dependency and dies on
// `no such module 'SwiftUI'`, and no command-line flag can avoid it.
//
// `Package.swift` is Swift evaluated on the build host, so `#if os(macOS)` here
// asks about the machine running SwiftPM — which is the right question.
// It has to be an append after the `Package(...)` call rather than a `#if`
// inside the array literals: `#if` is not valid as a container-literal element
// ("error: expected expression in container literal").
#if os(macOS)

    package.products.append(.executable(name: "Skrepka", targets: ["Skrepka"]))
    package.dependencies.append(
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "3.0.1")
    )
    package.targets.append(
        .executableTarget(
            name: "Skrepka",
            dependencies: [
                "SkrepkaCore",
                "SkrepkaSync",
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
            ],
            // scripts/bundle.sh copies Resources/ straight into the .app, so
            // SwiftPM must not also process it into a resource bundle.
            exclude: ["Resources"],
            swiftSettings: appSwiftSettings
        )
    )

#endif
