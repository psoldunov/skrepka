import Foundation
import Testing

@testable import SkrepkaCore

/// Real directories, real files and the payload that points at them.
///
/// No AppKit and no ImageIO, so this half builds on Linux and the suites that
/// only need a path — `CaptureRulesTests`, `ContentSizeTests` — run on both
/// platforms. Making a picture needs both, and lives in `Fixtures+Images.swift`.
enum Fixtures {
    static func makeDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "skrepka-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// A directory named the way an application bundle is.
    ///
    /// On macOS the file system reports it as a package, and the extension alone
    /// decides that — no `Info.plist` and no `Contents/` are needed, verified by
    /// probing `.isPackageKey` on a bare `.app` directory. Elsewhere it is an
    /// ordinary directory, which is all the callers outside `FileURLKindTests`
    /// need it to be.
    static func makePackage(named name: String) throws -> URL {
        let url = try makeDirectory().appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A file whose type is definitely not a picture, for the cases that turn on
    /// telling one from the other.
    ///
    /// Here rather than in `Fixtures+Images.swift`: it needs no imaging
    /// framework, so it is available on every platform the core tests run on.
    static func writeTextFile(_ contents: String = "hello", named name: String) throws -> URL {
        let url = try makeDirectory().appending(path: name, directoryHint: .notDirectory)
        try Data(contents.utf8).write(to: url)
        return url
    }

    static func fileURLPayload(_ url: URL) -> ClipPayload {
        ClipPayload(representations: [PasteboardType.fileURL: Data(url.absoluteString.utf8)])
    }
}
