import Foundation
import Testing

/// Real picture files, as bytes, for the header readers.
///
/// Written by real encoders rather than assembled here — ImageMagick 7 for
/// PNG, JPEG, GIF, BMP and TIFF, `cwebp` for the three kinds of WebP — so the
/// readers are checked against what a copied file actually holds, not against
/// this file's idea of the formats. Every one is 3 × 2 pixels, wider than it is
/// tall, so a width and a height read the wrong way round cannot pass.
///
/// No AppKit and no ImageIO, unlike `Fixtures+Images.swift`: the readers are
/// the Linux daemon's, and these run on both platforms.
extension Fixtures {
    enum Pictures {
        static let png = decode(
            "iVBORw0KGgoAAAANSUhEUgAAAAMAAAACCAIAAAASFvFNAAAAEElEQVQI12P8zwAFTDAGAwATKQEDO7FpHgAAAABJRU5ErkJggg=="
        )

        /// A baseline JPEG with a JFIF header and no EXIF.
        static let jpeg = decode(
            "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAYEBQYFBAYGBQYHBwYIChAKCgkJChQODwwQFxQYGBcUFhYaHSUfGhsjHBYWICwgIyYn"
                + "KSopGR8tMC0oMCUoKSj/2wBDAQcHBwoIChMKChMoGhYaKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgo"
                + "KCgoKCgoKCj/wAARCAACAAMDASIAAhEBAxEB/8QAFQABAQAAAAAAAAAAAAAAAAAAAAf/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/8QA"
                + "FQEBAQAAAAAAAAAAAAAAAAAABgj/xAAUEQEAAAAAAAAAAAAAAAAAAAAA/9oADAMBAAIRAxEAPwCdABykX//Z")

        /// ``jpeg`` with an `Exif` segment after its JFIF one, in Motorola
        /// byte order, saying orientation 6 — stored 3 × 2, shown 2 × 3.
        /// ImageMagick reads the tag back as `RightTop`.
        static let jpegRotatedRight = decode(
            "/9j/4AAQSkZJRgABAQAAAQABAAD/4QAiRXhpZgAATU0AKgAAAAgAAQESAAMAAAABAAYAAAAAAAD/2wBDAAYEBQYFBAYGBQYHBwYI"
                + "ChAKCgkJChQODwwQFxQYGBcUFhYaHSUfGhsjHBYWICwgIyYnKSopGR8tMC0oMCUoKSj/2wBDAQcHBwoIChMKChMoGhYaKCgoKCgo"
                + "KCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCj/wAARCAACAAMDASIAAhEBAxEB/8QAFQABAQAAAAAA"
                + "AAAAAAAAAAAAAAf/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/8QAFQEBAQAAAAAAAAAAAAAAAAAABgj/xAAUEQEAAAAAAAAAAAAAAAAA"
                + "AAAA/9oADAMBAAIRAxEAPwCdABykX//Z")

        /// ``jpeg`` with an Intel-order `Exif` segment *before* its JFIF one,
        /// saying orientation 8 — `LeftBottom`, also shown 2 × 3.
        static let jpegRotatedLeft = decode(
            "/9j/4QAiRXhpZgAASUkqAAgAAAABABIBAwABAAAACAAAAAAAAAD/4AAQSkZJRgABAQAAAQABAAD/2wBDAAYEBQYFBAYGBQYHBwYI"
                + "ChAKCgkJChQODwwQFxQYGBcUFhYaHSUfGhsjHBYWICwgIyYnKSopGR8tMC0oMCUoKSj/2wBDAQcHBwoIChMKChMoGhYaKCgoKCgo"
                + "KCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCj/wAARCAACAAMDASIAAhEBAxEB/8QAFQABAQAAAAAA"
                + "AAAAAAAAAAAAAAf/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/8QAFQEBAQAAAAAAAAAAAAAAAAAABgj/xAAUEQEAAAAAAAAAAAAAAAAA"
                + "AAAA/9oADAMBAAIRAxEAPwCdABykX//Z")

        /// ``jpeg`` saying orientation 3 — upside down, so not transposed.
        static let jpegUpsideDown = decode(
            "/9j/4AAQSkZJRgABAQAAAQABAAD/4QAiRXhpZgAATU0AKgAAAAgAAQESAAMAAAABAAMAAAAAAAD/2wBDAAYEBQYFBAYGBQYHBwYI"
                + "ChAKCgkJChQODwwQFxQYGBcUFhYaHSUfGhsjHBYWICwgIyYnKSopGR8tMC0oMCUoKSj/2wBDAQcHBwoIChMKChMoGhYaKCgoKCgo"
                + "KCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCj/wAARCAACAAMDASIAAhEBAxEB/8QAFQABAQAAAAAA"
                + "AAAAAAAAAAAAAAf/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/8QAFQEBAQAAAAAAAAAAAAAAAAAABgj/xAAUEQEAAAAAAAAAAAAAAAAA"
                + "AAAA/9oADAMBAAIRAxEAPwCdABykX//Z")

        static let gif = decode("R0lGODlhAwACAPAAAP8AAAAAACH5BAAAAAAALAAAAAADAAIAAAIChF8AOw==")

        /// `BITMAPINFOHEADER`, the 40-byte DIB header ImageMagick writes as BMP3.
        static let bmp = decode(
            "Qk1OAAAAAAAAADYAAAAoAAAAAwAAAAIAAAABABgAAAAAABgAAAAAAAAAAAAAAAAAAAAAAAAAAAD/AAD/AAD/AAAAAAD/AAD/AAD/"
                + "AAAA")

        /// `BITMAPV5HEADER`, the 124-byte one ImageMagick writes by default.
        static let bmpVersion5 = decode(
            "Qk2iAAAAAAAAAIoAAAB8AAAAAwAAAAIAAAABABgAAAAAABgAAAAAAAAAAAAAAAAAAAAAAAAAAAD/AAD/AAD/AAAAAAAA/0JHUnOP"
                + "wvUoUbgeFR6F6wEzMzMTZmZmJmZmZgaZmZkJPQrXAyhcjzIAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAD/AAD/AAD/AAAA"
                + "AAD/AAD/AAD/AAAA")

        /// Little-endian, uncompressed.
        static let tiff = decode(
            "SUkqACwAAAD//wAAAAD//wAAAAD//wAAAAD//wAAAAD//wAAAAD//wAAAAAPAAABAwABAAAAAwAAAAEBAwABAAAAAgAAAAIBAwAD"
                + "AAAA5gAAAAMBAwABAAAAAQAAAAYBAwABAAAAAgAAAAoBAwABAAAAAQAAABEBBAABAAAACAAAABIBAwABAAAAAQAAABUBAwABAAAA"
                + "AwAAABYBAwABAAAAAgAAABcBBAABAAAAJAAAABwBAwABAAAAAQAAACkBAwACAAAAAAABAD4BBQACAAAAHAEAAD8BBQAGAAAA7AAA"
                + "AAAAAAAQABAAEACF61EAAACAAMP1qAAAAAACzcxMAAAAAAHNzEwAAACAAM3MTAAAAAACj8L1AAAAABA3GqAAAAAAAiuHCgAAACAA"
        )

        /// A lossy WebP: a bare `VP8 ` chunk.
        static let webPLossy = decode(
            "UklGRjwAAABXRUJQVlA4IDAAAADQAQCdASoDAAIAAUAmJaACdLoB+AADsAD+8ut//NgVzXPv9//S4P0uD9Lg/9KQAAA=")

        /// A lossless WebP: a bare `VP8L` chunk.
        static let webPLossless = decode("UklGRhwAAABXRUJQVlA4TA8AAAAvAkAAAAcQ/Y/+ByKi/wEA")

        /// An extended WebP — lossy with an alpha channel — led by `VP8X`.
        static let webPExtended = decode(
            "UklGRl4AAABXRUJQVlA4WAoAAAAQAAAAAgAAAQAAQUxQSAcAAAAAgICAgICAAFZQOCAwAAAA0AEAnQEqAwACAAFAJiWgAnS6AfgA"
                + "A7AA/vLrf/zYFc1z7/f/0uD9Lg/S4P/SkAAA")

        private static func decode(_ base64: String) -> Data {
            // A literal in this file; a typo in one is a broken fixture, and
            // every test that uses it fails on the empty data it gets.
            Data(base64Encoded: base64) ?? Data()
        }

        static func write(_ bytes: Data, named name: String) throws -> URL {
            let url = try Fixtures.makeDirectory().appending(path: name, directoryHint: .notDirectory)
            try bytes.write(to: url)
            return url
        }
    }
}
