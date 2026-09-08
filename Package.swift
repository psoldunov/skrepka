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

/// What the `SkrepkaLinux` product covers.
///
/// A `Product`'s target list cannot be amended after it is constructed, so the
/// Linux-only platform target has to be chosen here rather than appended below
/// with the target itself. Computed before the `Package(...)` call for the same
/// reason the app target is fenced after it: `#if` is not valid as a
/// container-literal element.
///
/// It has to be *in* the product, not merely declared: `doctor-linux.sh` builds
/// this product and nothing else, so a platform target left out of it is a
/// target the Linux gate never compiles.
#if os(Linux)
    let linuxProductTargets = [
        "SkrepkaCore", "SkrepkaSync", "SkrepkaLinuxPlatform",
        // Phase 6. Libraries rather than the two executables on purpose: a
        // `.executableTarget` cannot be a member of a library product, and the
        // gate needs to compile the daemon and the CLI rather than only the
        // twenty lines of `main.swift` that call into them.
        "SkrepkaIPC", "SkrepkaDaemon", "SkrepkaCLI", "SkrepkaLinuxUI",
    ]
#else
    let linuxProductTargets = ["SkrepkaCore", "SkrepkaSync"]
#endif

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
        .library(name: "SkrepkaLinux", type: .static, targets: linuxProductTargets),
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

// The Linux clipboard backends, fenced out of the manifest on macOS for the
// mirror image of the reason the app target is fenced out on Linux: they are C
// interop over libwayland-client, libX11 and libXfixes, and macOS ships none of
// the three. Left declared, every `swift build` on a Mac would ask pkg-config
// for a `wayland-client.pc` that is not there and fail at manifest resolution,
// before compiling a line.
//
// `#if os(Linux)` here asks about the machine running SwiftPM, which is the
// right question — `Package.swift` is Swift evaluated on the build host.
#if os(Linux)

    // A pure-Swift NIO implementation of the D-Bus wire protocol, needing
    // neither `libdbus-1` nor a system-library target. Two things in Phase 6
    // speak D-Bus and both are Linux-only: `AvahiDiscovery` calls
    // `org.freedesktop.Avahi` on the system bus, and the daemon exports
    // `dev.soldunov.Skrepka1` on the session bus — the same connection type
    // serves both, since `DBusClient.Connection` conforms to
    // `DBusServerConnection`.
    //
    // Appended here rather than in the shared `dependencies:` list, and that is
    // the D-9 rule rather than tidiness: the package resolves on macOS
    // perfectly well, so leaving it unconditional would pull D-Bus,
    // swift-nio-extras and swift-algorithms into the Mac app's dependency graph
    // to compile nothing. A Linux-only dependency is one `Package.resolved`
    // never carries on macOS — which `doctor-linux.sh` already handles, since it
    // saves and restores that file around every containerised run.
    //
    // The product is spelled `DBUS`; asking for `DBus` fails resolution with
    // "product 'DBus' … not found in package 'dbus'". The package identity is
    // the URL's last component, `dbus`.
    //
    // `.upToNextMinor` rather than `from:`, and the reason is the save/restore
    // above rather than caution. `from: "0.4.1"` means `0.4.1 ..< 1.0.0` —
    // SwiftPM does not give a 0.x major the narrower reading some other package
    // managers do, confirmed by dumping a manifest rather than from memory. A
    // Linux-only dependency can never appear in the checked-in
    // `Package.resolved`, which is resolved on macOS, and `doctor-linux.sh`
    // restores that file around every containerised run — so nothing anywhere
    // in the repository records which version of this package ever worked, and
    // every Linux build re-resolves to the newest tag in range. A pre-1.0
    // package promises nothing across a minor, and this one is load-bearing for
    // both peer discovery and the whole IPC surface, so the range is the only
    // place that pin can live.
    package.dependencies.append(
        .package(url: "https://github.com/wendylabsinc/dbus.git", .upToNextMinor(from: "0.4.1"))
    )

    package.products.append(.executable(name: "skrepka-clip-probe", targets: ["skrepka-clip-probe"]))
    package.products.append(.executable(name: "skrepkad", targets: ["skrepkad"]))
    package.products.append(.executable(name: "skrepka", targets: ["skrepka"]))
    package.targets.append(contentsOf: [
        // libwayland-client itself. `providers:` is what turns a missing
        // package into a message naming it rather than a link failure;
        // docker/Dockerfile.linux installs it so the containerised gate needs
        // neither.
        .systemLibrary(
            name: "CWaylandClient",
            pkgConfig: "wayland-client",
            providers: [.apt(["libwayland-dev"]), .yum(["wayland-devel"])]
        ),
        // The two data-control protocols, as C generated by wayland-scanner
        // from the XML vendored in protocol-xml/ and checked in beside it.
        // scripts/regenerate-wayland-protocols.sh reproduces every file here
        // and explains why the output rather than the tool is what ships.
        //
        // `exclude:` because SwiftPM treats an unrecognised file inside a
        // target directory as an unhandled resource and warns — which this
        // package compiles as an error.
        .target(
            name: "CWaylandProtocols",
            dependencies: ["CWaylandClient"],
            exclude: ["protocol-xml"],
            publicHeadersPath: "include"
        ),
        // Xlib and XFIXES. One target rather than two because Xfixes.h is
        // meaningless without Xlib.h and two module maps covering the same
        // headers collide. -lX11 is not in `pkg-config --libs xfixes` — see
        // Sources/CX11/shim.h — so SkrepkaLinuxPlatform links it
        // explicitly below.
        .systemLibrary(
            name: "CX11",
            pkgConfig: "xfixes",
            providers: [
                .apt(["libx11-dev", "libxfixes-dev"]),
                .yum(["libX11-devel", "libXfixes-devel"]),
            ]
        ),
        // GTK4 and gtk4-layer-shell behind the one C module Phase 7's picker
        // imports. `pkgConfig` names the layer-shell package because that is
        // the dependency a normal desktop may lack; GTK itself is a transitive
        // cflags requirement of its .pc file. Noble has no development package
        // for it, so docker/Dockerfile.linux builds it from source instead.
        .systemLibrary(
            name: "CGtk4",
            pkgConfig: "gtk4-layer-shell-0",
            providers: [
                .apt(["libgtk4-layer-shell-dev"]),
                .yum(["gtk4-layer-shell-devel"]),
            ]
        ),
        // Phase 5: the two `ClipboardSource` conformances Linux has —
        // `DataControlReader` for Wayland, driving both data-control protocols
        // behind one engine, and `XFixesReader` for X11 — the probe that
        // decides between them, and the representation mapping and diagnostics
        // that go with them.
        //
        // Phase 6 added `Discovery/`: the `PeerDiscovery` conformance that talks
        // to `org.freedesktop.Avahi`. It lives here rather than beside
        // `BonjourDiscovery` in `SkrepkaSync` because the dependency, not the
        // code, is the problem — see the `dbus` dependency above.
        .target(
            name: "SkrepkaLinuxPlatform",
            dependencies: [
                "SkrepkaCore", "SkrepkaSync", "CWaylandClient", "CWaylandProtocols", "CX11",
                // For `BusSession` alone — the parked-connection plumbing every
                // Skrepka process that holds a bus connection needs, and which
                // would otherwise be written twice.
                "SkrepkaIPC",
                .product(name: "DBUS", package: "dbus"),
            ],
            swiftSettings: sharedSwiftSettings,
            // xfixes.pc lists x11 under `Requires.private`, which pkg-config
            // expands only for `--static`, so the CX11 target contributes
            // -lXfixes and nothing else. Without this every Xlib symbol is an
            // undefined reference at link time.
            linkerSettings: [.linkedLibrary("X11")]
        ),
        // The headless proof. Logs every clipboard change and can write a
        // selection back, with no GUI and no history store — the Linux
        // counterpart of skrepka-sync-probe, and the binary Phase 5's "done
        // when" is written against.
        .executableTarget(
            name: "skrepka-clip-probe",
            dependencies: ["SkrepkaLinuxPlatform", "SkrepkaCore"],
            swiftSettings: sharedSwiftSettings
        ),
        .testTarget(
            name: "SkrepkaLinuxPlatformTests",
            dependencies: ["SkrepkaLinuxPlatform", "SkrepkaCore", "SkrepkaSync", "CX11"],
            swiftSettings: sharedSwiftSettings
        ),
        // Phase 7: the Linux view layer. `gtk4-layer-shell-0.pc` lists GTK and
        // Wayland under Requires.private, which pkg-config expands for
        // `--cflags` but for `--libs` only under `--static`, so CGtk4
        // contributes -lgtk4-layer-shell and nothing else. Link the GTK/GLib
        // symbols used by the Swift and inline-C code explicitly.
        .target(
            name: "SkrepkaLinuxUI",
            dependencies: ["SkrepkaCore", "CGtk4"],
            swiftSettings: sharedSwiftSettings,
            linkerSettings: [
                .linkedLibrary("gtk-4"),
                .linkedLibrary("gio-2.0"),
                .linkedLibrary("gobject-2.0"),
                .linkedLibrary("glib-2.0"),
            ]
        ),
        .testTarget(
            name: "SkrepkaLinuxUITests",
            dependencies: ["SkrepkaLinuxUI", "SkrepkaCore"],
            swiftSettings: sharedSwiftSettings
        ),
        // Phase 6: the daemon's D-Bus surface, and nothing else.
        //
        // Its own target because it has two consumers that must not link each
        // other. `skrepkad` exports the interface and `skrepka` calls it, and
        // folding the shared half into the daemon would have every CLI
        // invocation link SQLite, libwayland and Xlib to print a list. It is
        // also the half a third client reimplements: the Phase 8 GNOME Shell
        // extension is JavaScript and mirrors exactly what is declared here.
        .target(
            name: "SkrepkaIPC",
            dependencies: [.product(name: "DBUS", package: "dbus")],
            swiftSettings: sharedSwiftSettings
        ),
        // Phase 6: the daemon, as a library so it can be tested.
        //
        // The split `SkrepkaProbe`/`skrepka-sync-probe` already makes: `swift
        // test` cannot import an executable target, and everything worth
        // asserting about a composition root is inside it.
        .target(
            name: "SkrepkaDaemon",
            dependencies: [
                "SkrepkaCore", "SkrepkaSync", "SkrepkaLinuxPlatform", "SkrepkaIPC",
                .product(name: "DBUS", package: "dbus"),
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: sharedSwiftSettings
        ),
        // Phase 6: the CLI, split from its executable for the same reason.
        //
        // Depends on `SkrepkaIPC` and not on `SkrepkaDaemon`: the CLI is a D-Bus
        // client of a daemon in another process, and a CLI that could reach the
        // daemon's types directly would eventually reach its database too.
        .target(
            name: "SkrepkaCLI",
            dependencies: ["SkrepkaIPC", .product(name: "DBUS", package: "dbus")],
            swiftSettings: sharedSwiftSettings
        ),
        .executableTarget(
            name: "skrepkad",
            dependencies: ["SkrepkaDaemon"],
            swiftSettings: sharedSwiftSettings
        ),
        // The CLI's entry point, and the one target in this package that needs
        // an explicit `path:`.
        //
        // Its sources cannot live in `Sources/skrepka`, because the app target
        // already owns `Sources/Skrepka` and macOS filesystems are
        // case-insensitive by default — the two are one directory there, so
        // `main.swift` lands inside the app target and SwiftPM reports it as an
        // unhandled file. The *target* is still called `skrepka`, because that
        // is what the built binary is named and what the user types.
        //
        // No collision in the manifest itself: `Skrepka` exists only on macOS
        // and `skrepka` only on Linux, so the two names are never resolved
        // together.
        .executableTarget(
            name: "skrepka",
            dependencies: ["SkrepkaCLI"],
            path: "Sources/skrepka-cli",
            swiftSettings: sharedSwiftSettings
        ),
        .testTarget(
            name: "SkrepkaDaemonTests",
            dependencies: [
                "SkrepkaDaemon", "SkrepkaIPC", "SkrepkaCLI",
                "SkrepkaCore", "SkrepkaSync", "SkrepkaLinuxPlatform",
            ],
            swiftSettings: sharedSwiftSettings
        ),
    ])

#endif
