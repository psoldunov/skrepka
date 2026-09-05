// The half of Fixtures that needs AppKit and ImageIO to make a picture. The
// files-and-payloads half is in Fixtures.swift and builds on Linux, which is
// what lets CaptureRulesTests and ContentSizeTests run there too.
#if canImport(AppKit)

    import AppKit
    import Foundation
    import ImageIO
    import Testing
    import UniformTypeIdentifiers

    @testable import SkrepkaCore

    /// Real image bytes rather than placeholders: ImageIO is the thing under test
    /// in the suites that ask for these, and it will not be fooled by a stand-in.
    extension Fixtures {
        static func png(width: Int, height: Int) throws -> Data {
            let rep = try #require(bitmap(width: width, height: height, hasAlpha: true))
            rep.size = CGSize(width: width, height: height)
            return try #require(rep.representation(using: .png, properties: [:]))
        }

        static func writePNG(width: Int, height: Int, named name: String) throws -> URL {
            let url = try makeDirectory().appending(path: name, directoryHint: .notDirectory)
            try png(width: width, height: height).write(to: url)
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

#endif
