import Foundation
import Testing

@testable import SkrepkaLinuxPlatform

@Suite("URI lists")
struct URIListTests {
    @Test("RFC 2483 CRLF separators")
    func parsesCRLF() {
        let urls = URIList.parse(Data("file:///tmp/a.txt\r\nfile:///tmp/b.txt\r\n".utf8))
        #expect(urls.map(\.path) == ["/tmp/a.txt", "/tmp/b.txt"])
    }

    /// Verified against `src/nautilus-clipboard.c`: the verb is written first
    /// and `\n` is appended before each URI, so a well-formed body has no
    /// trailing newline.
    @Test("GNOME's verb line and bare newlines")
    func parsesGNOMEForm() {
        let urls = URIList.parse(Data("copy\nfile:///tmp/a.txt\nfile:///tmp/b.txt".utf8))
        #expect(urls.map(\.path) == ["/tmp/a.txt", "/tmp/b.txt"])
    }

    @Test("cut is parsed the same as copy — the verb has no macOS equivalent")
    func ignoresVerb() {
        #expect(URIList.parse(Data("cut\nfile:///tmp/a.txt".utf8)).count == 1)
    }

    /// Nautilus emits neither, but Thunar, Nemo and Dolphin all write this
    /// target and none of them was read. The format has no specification to
    /// appeal to, so tolerating both is cheap insurance against losing a whole
    /// copy to one stray byte.
    @Test("a trailing newline or NUL from another file manager is tolerated")
    func toleratesTrailingBytes() {
        #expect(URIList.parse(Data("copy\nfile:///tmp/a.txt\n".utf8)).count == 1)
        #expect(URIList.parse(Data("copy\nfile:///tmp/a.txt\0".utf8)).count == 1)
        #expect(URIList.parse(Data("copy\nfile:///tmp/a.txt\n\0".utf8)).count == 1)
    }

    @Test("RFC 2483 comment lines are skipped")
    func skipsComments() {
        let urls = URIList.parse(Data("# a comment\r\nfile:///tmp/a.txt".utf8))
        #expect(urls.map(\.path) == ["/tmp/a.txt"])
    }

    /// Any application may put anything under this target, so a row claiming a
    /// file it has not got is worse than a row with one fewer file.
    @Test("anything that is not a file URL is skipped rather than guessed at")
    func skipsNonFileURLs() {
        let urls = URIList.parse(
            Data("https://example.com/a\nnot a url at all\nfile:///tmp/a.txt".utf8)
        )
        #expect(urls.map(\.path) == ["/tmp/a.txt"])
    }

    @Test("percent-encoded names survive the round trip")
    func percentEncoding() {
        let urls = URIList.parse(Data("file:///tmp/my%20file.txt".utf8))
        #expect(urls.first?.lastPathComponent == "my file.txt")
    }

    @Test("an empty or unparseable body yields nothing")
    func emptyBody() {
        #expect(URIList.parse(Data()).isEmpty)
        #expect(URIList.parse(Data([0xFF, 0xFE, 0xFD])).isEmpty)
    }

    @Test("formatting a URI list uses CRLF and no verb")
    func formatsURIList() {
        let body = URIList.formatURIList([
            URL(fileURLWithPath: "/tmp/a.txt"), URL(fileURLWithPath: "/tmp/b.txt"),
        ])
        #expect(String(bytes: body, encoding: .utf8) == "file:///tmp/a.txt\r\nfile:///tmp/b.txt")
    }

    @Test("formatting GNOME's spelling leads with the verb and no trailing newline")
    func formatsGNOMEForm() {
        let body = URIList.formatGNOMECopiedFiles([URL(fileURLWithPath: "/tmp/a.txt")])
        #expect(String(bytes: body, encoding: .utf8) == "copy\nfile:///tmp/a.txt")
    }

    @Test("what this formats, it parses")
    func roundTrips() {
        let urls = [URL(fileURLWithPath: "/tmp/a b.txt"), URL(fileURLWithPath: "/tmp/c.png")]
        #expect(URIList.parse(URIList.formatURIList(urls)) == urls)
        #expect(URIList.parse(URIList.formatGNOMECopiedFiles(urls)) == urls)
    }
}
