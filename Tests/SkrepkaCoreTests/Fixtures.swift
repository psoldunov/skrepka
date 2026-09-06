import AppKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import SkrepkaCore

/// Real image bytes and real files on disk, shared by the store and thumbnail
/// suites.
///
/// Real rather than placeholder because ImageIO is the thing under test in both
/// and it will not be fooled by a stand-in.
enum Fixtures {
    static func png(width: Int, height: Int) throws -> Data {
        let rep = try #require(bitmap(width: width, height: height, hasAlpha: true))
        rep.size = CGSize(width: width, height: height)
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    static func makeDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "skrepka-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// A directory the file system reports as a package, which is what an
    /// application bundle is. The extension alone decides it — no `Info.plist`
    /// and no `Contents/` are needed, verified by probing `.isPackageKey` on a
    /// bare `.app` directory.
    static func makePackage(named name: String) throws -> URL {
        let url = try makeDirectory().appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func writePNG(width: Int, height: Int, named name: String) throws -> URL {
        let url = try makeDirectory().appending(path: name, directoryHint: .notDirectory)
        try png(width: width, height: height).write(to: url)
        return url
    }

    /// A file whose type is definitely not a picture, for the cases that turn on
    /// telling one from the other.
    static func writeTextFile(_ contents: String = "hello", named name: String) throws -> URL {
        let url = try makeDirectory().appending(path: name, directoryHint: .notDirectory)
        try Data(contents.utf8).write(to: url)
        return url
    }

    /// A JPEG carrying an EXIF orientation, for the rotated-photo cases.
    ///
    /// JPEG rather than PNG because EXIF orientation is what a camera writes and
    /// what ImageIO reads back; `width` and `height` are the dimensions *stored*
    /// on disk, which an orientation of 5 through 8 asks a reader to transpose.
    static func writeJPEG(
        width: Int,
        height: Int,
        orientation: Int,
        named name: String
    ) throws -> URL {
        let url = try makeDirectory().appending(path: name, directoryHint: .notDirectory)
        // JPEG carries no alpha channel, so the bitmap must not offer one.
        let rep = try #require(bitmap(width: width, height: height, hasAlpha: false))
        let image = try #require(rep.cgImage)
        let destination = try #require(
            CGImageDestinationCreateWithURL(
                url as CFURL,
                UTType.jpeg.identifier as CFString,
                1,
                nil
            )
        )
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImagePropertyOrientation: orientation] as CFDictionary
        )
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    static func fileURLPayload(_ url: URL) -> ClipPayload {
        ClipPayload(representations: [PasteboardType.fileURL: Data(url.absoluteString.utf8)])
    }

    private static func bitmap(width: Int, height: Int, hasAlpha: Bool) -> NSBitmapImageRep? {
        NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: hasAlpha ? 4 : 3,
            hasAlpha: hasAlpha,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
    }
}
