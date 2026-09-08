import Foundation

/// What `skrepkad --version` and `skrepka doctor` report.
///
/// A constant rather than a bundle read, because a Linux executable has no
/// `Info.plist` to read one from — `Bundle.main.infoDictionary` on
/// swift-corelibs-foundation answers nil for a bare executable, which is what
/// `DiagnosticsGatherer.appVersion` on macOS depends on.
///
/// **It must be bumped alongside `Info.plist`'s `CFBundleShortVersionString`.**
/// Two version numbers that can disagree is exactly the shape of bug that ships
/// — so `DaemonVersionTests.matchesTheBundleVersion` reads that file and fails
/// this build if they ever do. A release that bumps one and not the other is a
/// red gate rather than a Linux daemon claiming to be a version older than
/// itself.
public enum DaemonVersion {
    public static let current = "0.1.4"
}
