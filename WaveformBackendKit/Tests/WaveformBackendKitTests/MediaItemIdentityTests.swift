import XCTest
@testable import WaveformBackendKit

/// `MediaItem.id` is now a stable UUID assigned once at import/download
/// time and stored in `library.json` (§6/§7) — replacing the old
/// `.cmf`-era content/source-derived id, whose whole reason for existing
/// was to survive a `.cmf` file moving on disk. That failure mode doesn't
/// exist anymore: `LibraryStore` is the only thing that ever moves a
/// library file, and it does so in place without touching `id`. This
/// suite checks that guarantee directly, via `LibraryStore.replaceFile`
/// (the same code path Shrink uses, §3) and via a raw on-disk move
/// followed by a fresh `load()`.
@MainActor
final class MediaItemIdentityTests: XCTestCase {
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

    func testIDIsStableAcrossReplaceFile() throws {
        let dir = makeTempDir()
        let library = LibraryStore(rootURL: dir.appendingPathComponent("Library", isDirectory: true))
        library.load()

        let audioURL = try makeTempFile(containing: "original bytes", in: dir)
        let item = try library.addOrUpdate(LibraryWrite(
            title: "Track",
            author: "Artist",
            source: MediaSource(origin: "ytdlp"),
            audioFile: (url: audioURL, media: MediaFile(codec: "h264", container: "mp4"))
        ))
        let originalID = item.id

        // Simulates Shrink: rewrites the audio file in place with a new
        // codec/container.
        let shrunkURL = try makeTempFile(containing: "shrunk bytes", in: dir)
        try library.replaceFile(
            forItemID: item.info.id,
            kind: .audio,
            newFileURL: shrunkURL,
            newMedia: MediaFile(codec: "opus", container: "opus", shrunk: true)
        )

        let reloaded = try XCTUnwrap(library.item(withID: originalID))
        XCTAssertEqual(reloaded.id, originalID, "id must survive Shrink rewriting the file in place")
        XCTAssertEqual(reloaded.info.audioMedia?.codec, "opus")
        XCTAssertTrue(reloaded.info.audioMedia?.shrunk ?? false)
    }

    func testIDIsStableAcrossLibraryFolderMoving() throws {
        let parentDir = makeTempDir()
        let originalRoot = parentDir.appendingPathComponent("Library-original", isDirectory: true)

        let library = LibraryStore(rootURL: originalRoot)
        library.load()
        let audioURL = try makeTempFile(containing: "bytes", in: parentDir)
        let item = try library.addOrUpdate(LibraryWrite(
            title: "Movable Track",
            author: "Artist",
            source: MediaSource(origin: "ytdlp"),
            audioFile: (url: audioURL, media: MediaFile(codec: "opus", container: "opus"))
        ))
        let originalID = item.id

        // Move the whole library folder on disk (e.g. a fresh app install
        // restoring from an iCloud/Files backup at a new container path)
        // and re-open a LibraryStore pointed at the new location.
        let movedRoot = parentDir.appendingPathComponent("Library-moved", isDirectory: true)
        try FileManager.default.moveItem(at: originalRoot, to: movedRoot)

        let reopened = LibraryStore(rootURL: movedRoot)
        reopened.load()
        let reloaded = try XCTUnwrap(reopened.item(withID: originalID))
        XCTAssertEqual(reloaded.id, originalID)
        XCTAssertEqual(reloaded.title, "Movable Track")
        XCTAssertNotNil(reloaded.audioFileURL)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: reloaded.audioFileURL!.path),
            "the resolved file URL should point at the file's new on-disk location, not the old one"
        )
    }
}
