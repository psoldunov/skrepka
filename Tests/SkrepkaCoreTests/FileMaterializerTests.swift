import Foundation
import SkrepkaSync
import Testing

@testable import SkrepkaCore

@Suite("Writing a peer's files to disk")
struct FileMaterializerTests {
    static let hash = String(repeating: "c", count: 64)

    @Test(
        "A hostile name lands inside the item's directory",
        arguments: [
            ("../../x", "x"),
            ("/etc/passwd", "passwd"),
            ("..\\..\\boot.ini", "boot.ini"),
            ("..", SafeFileName.fallback),
            ("", SafeFileName.fallback),
            ("a/", "a"),
            ("tab\there", "tabhere"),
        ]
    )
    func hostileNames(name: String, expected: String) throws {
        let cache = FileCache(root: try Fixtures.makeDirectory())
        let bundle = FileBundle(files: [FileBundle.File(name: name, bytes: Data("x".utf8))])

        let urls = try FileMaterializer.materialize(bundle, contentHash: Self.hash, in: cache)
        let directory = try #require(cache.directory(for: Self.hash))
        #expect(urls.map(\.lastPathComponent) == [expected])
        #expect(urls.first?.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL)
        #expect(try Data(contentsOf: try #require(urls.first)) == Data("x".utf8))
    }

    @Test("Duplicate names are numbered, the way Finder numbers them")
    func duplicates() throws {
        #expect(
            SafeFileName.names(for: ["a.txt", "A.TXT", "a.txt", ".env", ".env", "noext", "noext"])
                == ["a.txt", "A 2.TXT", "a 3.txt", ".env", ".env 2", "noext", "noext 2"]
        )
    }

    @Test("A name longer than the file system allows is cut on a character boundary")
    func longNames() {
        let name = SafeFileName.sanitized(String(repeating: "é", count: 200))
        #expect(name.utf8.count <= SafeFileName.maximumBytes)
        #expect(name.allSatisfy { $0 == "é" })
    }

    @Test("A hash that is not one names no directory")
    func hostileHash() throws {
        let cache = FileCache(root: try Fixtures.makeDirectory())
        let bundle = FileBundle(files: [FileBundle.File(name: "a", bytes: Data())])
        let hostile = [
            "../../Library", String(repeating: "C", count: 64), "", String(repeating: "c", count: 63),
        ]
        for hash in hostile {
            #expect(cache.directory(for: hash) == nil)
            #expect(throws: FileMaterializer.Failure.notAContentHash(hash)) {
                try FileMaterializer.materialize(bundle, contentHash: hash, in: cache)
            }
        }
    }

    @Test("Materialising twice writes once and answers the same files")
    func idempotent() throws {
        let cache = FileCache(root: try Fixtures.makeDirectory())
        let bundle = FileBundle(files: [
            FileBundle.File(name: "one.txt", bytes: Data("1".utf8)),
            FileBundle.File(name: "two.txt", bytes: Data("22".utf8)),
        ])
        let first = try FileMaterializer.materialize(bundle, contentHash: Self.hash, in: cache)
        let stamp = try Self.modified(first[0])

        let second = try FileMaterializer.materialize(bundle, contentHash: Self.hash, in: cache)
        #expect(second == first)
        #expect(try Self.modified(first[0]) == stamp)
        #expect(try Data(contentsOf: second[1]) == Data("22".utf8))
    }

    @Test("A file cut short is written again")
    func repairsATruncatedFile() throws {
        let cache = FileCache(root: try Fixtures.makeDirectory())
        let bundle = FileBundle(files: [FileBundle.File(name: "one.txt", bytes: Data("full".utf8))])
        let written = try FileMaterializer.materialize(bundle, contentHash: Self.hash, in: cache)
        let url = try #require(written.first)
        try Data("f".utf8).write(to: url)

        _ = try FileMaterializer.materialize(bundle, contentHash: Self.hash, in: cache)
        #expect(try Data(contentsOf: url) == Data("full".utf8))
    }

    @Test("A sweep removes every item's files but the live ones, and strays")
    func sweep() throws {
        let cache = FileCache(root: try Fixtures.makeDirectory())
        let bundle = FileBundle(files: [FileBundle.File(name: "a", bytes: Data("a".utf8))])
        let live = String(repeating: "1", count: 64)
        let dead = String(repeating: "2", count: 64)
        _ = try FileMaterializer.materialize(bundle, contentHash: live, in: cache)
        _ = try FileMaterializer.materialize(bundle, contentHash: dead, in: cache)
        try Data().write(to: cache.filesDirectory.appending(path: "stray"))

        #expect(cache.sweep(keeping: [live]) == 2)
        #expect(cache.entries() == [live])
        #expect(FileCache(root: try Fixtures.makeDirectory()).sweep(keeping: []) == 0)
    }

    private static func modified(_ url: URL) throws -> Date? {
        try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    }

    @Test("Two duplicate names at the length limit are both kept, not looped on")
    func duplicatesAtTheLimit() {
        let long = String(repeating: "x", count: SafeFileName.maximumBytes)
        let withExtension = String(repeating: "y", count: SafeFileName.maximumBytes - 4) + ".png"
        let names = SafeFileName.names(for: [long, long, withExtension, withExtension])
        #expect(Set(names.map { $0.lowercased() }).count == 4)
        #expect(names.allSatisfy { $0.utf8.count <= SafeFileName.maximumBytes })
        #expect(names[1].hasSuffix(" 2"))
        #expect(names[3].hasSuffix(" 2.png"))
    }

    @Test("A hash directory planted as a symlink is refused, and nothing is written through it")
    func symlinkedHashDirectory() throws {
        let cache = FileCache(root: try Fixtures.makeDirectory())
        let elsewhere = try Fixtures.makeDirectory()
        try FileManager.default.createDirectory(at: cache.filesDirectory, withIntermediateDirectories: true)
        let directory = try #require(cache.directory(for: Self.hash))
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: elsewhere)

        let bundle = FileBundle(files: [FileBundle.File(name: "authorized_keys", bytes: Data("x".utf8))])
        #expect(throws: FileMaterializer.Failure.untrustedDirectory(directory.path)) {
            try FileMaterializer.materialize(bundle, contentHash: Self.hash, in: cache)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path).isEmpty)
    }

    @Test("A files directory planted as a symlink is refused")
    func symlinkedFilesDirectory() throws {
        let cache = FileCache(root: try Fixtures.makeDirectory())
        try FileManager.default.createSymbolicLink(
            at: cache.filesDirectory, withDestinationURL: try Fixtures.makeDirectory())
        let bundle = FileBundle(files: [FileBundle.File(name: "a", bytes: Data())])
        #expect(throws: FileMaterializer.Failure.untrustedDirectory(cache.filesDirectory.path)) {
            try FileMaterializer.materialize(bundle, contentHash: Self.hash, in: cache)
        }
    }

    @Test("A symlink standing where a file goes is replaced, not written through")
    func symlinkAtFileIsReplaced() throws {
        let cache = FileCache(root: try Fixtures.makeDirectory())
        let bundle = FileBundle(files: [FileBundle.File(name: "a.txt", bytes: Data("new".utf8))])
        let url = try #require(
            try FileMaterializer.materialize(bundle, contentHash: Self.hash, in: cache).first)
        let victim = try Fixtures.writeTextFile("victim", named: "victim.txt")
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: victim)

        _ = try FileMaterializer.materialize(bundle, contentHash: Self.hash, in: cache)
        #expect(try Data(contentsOf: victim) == Data("victim".utf8))
        #expect(try Data(contentsOf: url) == Data("new".utf8))
    }

    @Test("A cache made from nothing is private to this user")
    func cacheIsPrivate() throws {
        let root = try Fixtures.makeDirectory().appending(path: "cache", directoryHint: .isDirectory)
        let cache = FileCache(root: root)
        let bundle = FileBundle(files: [FileBundle.File(name: "a", bytes: Data())])
        _ = try FileMaterializer.materialize(bundle, contentHash: Self.hash, in: cache)
        for url in [root, cache.filesDirectory] {
            let mode =
                try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
            #expect(mode?.intValue == 0o700)
        }
    }
}
