import XCTest
@testable import WaveformBackendKit

/// Replaces the old `.cmf`-era `CMFRoundTripTests` (§10): the format
/// being round-tripped is now the unified `library.json` + `Audio/`/
/// `Video/`/`Artwork/` folder tree (§6), written and read entirely
/// through `LibraryStore` rather than a zip archive.
@MainActor
final class LibraryRoundTripTests: XCTestCase {
    func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func makeTempFile(containing string: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(UUID().uuidString)
        try Data(string.utf8).write(to: url)
        return url
    }

    func testWriteThenReadRoundTrip() throws {
        let parentDir = makeTempDir()
        let library = LibraryStore(rootURL: parentDir.appendingPathComponent("Library", isDirectory: true))
        library.load()

        let audioURL = try makeTempFile(containing: "fake opus bytes", in: parentDir)
        let artworkURL = try makeTempFile(containing: "fake jpg bytes", in: parentDir)

        let written = try library.addOrUpdate(LibraryWrite(
            title: "Test Track",
            author: "Test Artist",
            durationMS: 123_000,
            source: MediaSource(origin: "youtube", url: "https://example.com/watch?v=abc123", youtubeID: "abc123"),
            audioFile: (url: audioURL, media: MediaFile(codec: "opus", container: "opus")),
            artworkFile: artworkURL
        ))

        // A fresh store pointed at the same root should read back exactly
        // what was written — proving persist()/load() round-trip, not
        // just the in-memory state right after addOrUpdate.
        let reopened = LibraryStore(rootURL: parentDir.appendingPathComponent("Library", isDirectory: true))
        reopened.load()

        XCTAssertEqual(reopened.items.count, 1)
        let read = try XCTUnwrap(reopened.items.first)
        XCTAssertEqual(read.title, "Test Track")
        XCTAssertEqual(read.author, "Test Artist")
        XCTAssertEqual(read.duration, 123, accuracy: 0.001)
        XCTAssertTrue(read.hasAudio)
        XCTAssertFalse(read.hasVideo)
        XCTAssertEqual(read.info.mode, "audio")
        XCTAssertEqual(read.id, written.id)

        let readAudioURL = try XCTUnwrap(read.audioFileURL)
        XCTAssertEqual(try Data(contentsOf: readAudioURL), Data("fake opus bytes".utf8))

        let readArtworkURL = try XCTUnwrap(read.artworkFileURL)
        XCTAssertEqual(try Data(contentsOf: readArtworkURL), Data("fake jpg bytes".utf8))
    }

    /// The source-ID-first dedup contract (§5): a second write for a
    /// track sharing a source id with an existing entry must return the
    /// *existing* item rather than creating a duplicate, and must not
    /// touch the filesystem for the "new" file it was handed.
    func testAddOrUpdateSkipsWhenSourceIDAlreadyExists() throws {
        let parentDir = makeTempDir()
        let library = LibraryStore(rootURL: parentDir.appendingPathComponent("Library", isDirectory: true))
        library.load()

        let source = MediaSource(origin: "spotify", spotifyID: "sp-42", youtubeID: "yt-42")
        let firstAudioURL = try makeTempFile(containing: "one", in: parentDir)
        let first = try library.addOrUpdate(LibraryWrite(
            title: "First Pull",
            author: "Artist",
            source: source,
            audioFile: (url: firstAudioURL, media: MediaFile(codec: "opus", container: "opus"))
        ))

        // A different (but matching-source) write attempt — e.g. the user
        // tapped Download twice — should be recognized as the same track
        // even though the title differs and the "new" file is never moved.
        let secondAudioURL = try makeTempFile(containing: "two", in: parentDir)
        let second = try library.addOrUpdate(LibraryWrite(
            title: "First Pull (duplicate attempt)",
            author: "Artist",
            source: MediaSource(origin: "spotify", spotifyID: "sp-42"),
            audioFile: (url: secondAudioURL, media: MediaFile(codec: "opus", container: "opus"))
        ))

        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(library.items.count, 1)
        // The second write's source file should never have been consumed —
        // addOrUpdate bails out before touching the filesystem for it.
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondAudioURL.path))
    }

    func testDistinctSourcesProduceDistinctEntries() throws {
        let parentDir = makeTempDir()
        let library = LibraryStore(rootURL: parentDir.appendingPathComponent("Library", isDirectory: true))
        library.load()

        let firstAudioURL = try makeTempFile(containing: "one", in: parentDir)
        try library.addOrUpdate(LibraryWrite(
            title: "Track One",
            author: "Artist",
            source: MediaSource(origin: "ytdlp", youtubeID: "yt-1"),
            audioFile: (url: firstAudioURL, media: MediaFile(codec: "opus", container: "opus"))
        ))
        let secondAudioURL = try makeTempFile(containing: "two", in: parentDir)
        try library.addOrUpdate(LibraryWrite(
            title: "Track Two",
            author: "Artist",
            source: MediaSource(origin: "ytdlp", youtubeID: "yt-2"),
            audioFile: (url: secondAudioURL, media: MediaFile(codec: "opus", container: "opus"))
        ))

        XCTAssertEqual(library.items.count, 2)
    }

    /// Artwork is content-hash deduped (§5/§6) even across two otherwise
    /// distinct items — the one place hashing still applies post-v2.
    func testArtworkIsContentHashDedupedAcrossItems() throws {
        let parentDir = makeTempDir()
        let library = LibraryStore(rootURL: parentDir.appendingPathComponent("Library", isDirectory: true))
        library.load()

        let sharedArtworkBytes = "shared cover bytes"

        let firstAudioURL = try makeTempFile(containing: "one", in: parentDir)
        let firstArtworkURL = try makeTempFile(containing: sharedArtworkBytes, in: parentDir)
        let first = try library.addOrUpdate(LibraryWrite(
            title: "Track One",
            author: "Artist",
            source: MediaSource(origin: "spotify", spotifyID: "sp-1"),
            audioFile: (url: firstAudioURL, media: MediaFile(codec: "opus", container: "opus")),
            artworkFile: firstArtworkURL
        ))

        let secondAudioURL = try makeTempFile(containing: "two", in: parentDir)
        let secondArtworkURL = try makeTempFile(containing: sharedArtworkBytes, in: parentDir)
        let second = try library.addOrUpdate(LibraryWrite(
            title: "Track Two",
            author: "Artist",
            source: MediaSource(origin: "spotify", spotifyID: "sp-2"),
            audioFile: (url: secondAudioURL, media: MediaFile(codec: "opus", container: "opus")),
            artworkFile: secondArtworkURL
        ))

        XCTAssertEqual(first.info.paths.assets.first, second.info.paths.assets.first, "identical bytes should hash to the same Artwork/ path")
    }
}
