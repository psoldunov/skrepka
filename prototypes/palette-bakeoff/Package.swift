// swift-tools-version: 6.2
import PackageDescription

// Phase 7 bake-off prototype C: raw GTK4 through C interop, no third-party
// Swift GUI framework. Mirrors the repository's own CWaylandClient / CX11
// idiom, and uses the same language mode and warnings-as-errors the real
// package does — a prototype that compiles under laxer settings proves nothing
// about whether the real target can adopt it.
let strict: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .treatAllWarnings(as: .error),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("InferIsolatedConformances"),
]

let package = Package(
    name: "PaletteProto",
    targets: [
        // gtk4-layer-shell-0.pc lists `Requires.private: gtk4`, which pkg-config
        // expands for --cflags but not for --libs, so this one target carries the
        // headers for both and the Swift target links gtk-4 explicitly. Exactly
        // the shape Sources/CX11 already has for Xfixes/X11.
        .systemLibrary(
            name: "CGtk",
            path: "Sources/CGtk",
            pkgConfig: "gtk4-layer-shell-0",
            providers: [.apt(["libgtk-4-dev"])]
        ),
        .executableTarget(
            name: "palette",
            dependencies: ["CGtk"],
            swiftSettings: strict,
            linkerSettings: [
                .linkedLibrary("gtk-4"),
                .linkedLibrary("gobject-2.0"),
                .linkedLibrary("glib-2.0"),
                .linkedLibrary("gio-2.0"),
            ]
        ),
    ]
)
