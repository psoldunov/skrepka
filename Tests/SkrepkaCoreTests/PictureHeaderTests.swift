import Foundation
import Testing

@testable import SkrepkaCore

@Suite("Reading a picture's format and size from its header")
struct PictureHeaderTests {
    typealias Pictures = Fixtures.Pictures

    static let threeByTwo = ClipItem.ImageSize(width: 3, height: 2)

    @Test(
        "every format is recognised, and sized where its header says",
        arguments: [
            (Pictures.png, PictureFormat.png, threeByTwo),
            (Pictures.jpeg, .jpeg, threeByTwo),
            (Pictures.gif, .gif, threeByTwo),
            (Pictures.bmp, .bmp, threeByTwo),
            (Pictures.bmpVersion5, .bmp, threeByTwo),
            (Pictures.webPLossy, .webp, threeByTwo),
            (Pictures.webPLossless, .webp, threeByTwo),
            (Pictures.webPExtended, .webp, threeByTwo),
            (Pictures.tiff, .tiff, nil),
        ] as [(Data, PictureFormat, ClipItem.ImageSize?)]
    )
    func formatsAndSizes(bytes: Data, format: PictureFormat, size: ClipItem.ImageSize?) throws {
        let header = try #require(PictureHeader(bytes))
        #expect(header.format == format)
        #expect(header.displaySize == size)
    }

    @Test("a JPEG turned a quarter either way is shown with its sides swapped")
    func quarterTurnsTranspose() throws {
        let transposed = ClipItem.ImageSize(width: 2, height: 3)
        #expect(try #require(PictureHeader(Pictures.jpegRotatedRight)).displaySize == transposed)
        #expect(try #require(PictureHeader(Pictures.jpegRotatedLeft)).displaySize == transposed)
    }

    @Test("a JPEG turned upside down keeps its sides")
    func halfTurnDoesNotTranspose() throws {
        #expect(try #require(PictureHeader(Pictures.jpegUpsideDown)).displaySize == Self.threeByTwo)
    }

    @Test("the EXIF orientation is read in either byte order, and absent is absent")
    func orientationValues() {
        #expect(JPEGOrientation.value(in: [UInt8](Pictures.jpegRotatedRight)) == 6)
        #expect(JPEGOrientation.value(in: [UInt8](Pictures.jpegRotatedLeft)) == 8)
        #expect(JPEGOrientation.value(in: [UInt8](Pictures.jpegUpsideDown)) == 3)
        #expect(JPEGOrientation.value(in: [UInt8](Pictures.jpeg)) == nil)
    }

    @Test("each format is named by the media type the daemon has always sent")
    func mediaTypes() {
        #expect(
            PictureFormat.allCases.map(\.mediaType) == [
                "image/png", "image/jpeg", "image/gif", "image/bmp", "image/tiff", "image/webp",
            ])
    }

    @Test(
        "what is not a picture is not taken for one",
        arguments: [
            Data("hello, world".utf8),
            // "BM" and nothing a BMP would hold after it.
            Data("BMW service history, 2019 to 2026".utf8),
            Data("RIFF\u{0}\u{0}\u{0}\u{0}WAVEfmt ".utf8),
            Data(),
        ]
    )
    func nonPictures(bytes: Data) {
        #expect(PictureHeader(bytes) == nil)
    }

    @Test(
        "a header cut short is still recognised, and unsized unless the part left says",
        arguments: [
            (Pictures.png, nil),
            (Pictures.jpeg, nil),
            (Pictures.bmp, nil),
            (Pictures.webPLossy, nil),
            // The logical screen size sits in bytes 6 to 9, well inside.
            (Pictures.gif, threeByTwo),
        ] as [(Data, ClipItem.ImageSize?)]
    )
    func truncatedHeaders(bytes: Data, size: ClipItem.ImageSize?) throws {
        let header = try #require(PictureHeader(bytes.prefix(PictureFormat.sniffedLength)))
        #expect(header.displaySize == size)
    }
}
