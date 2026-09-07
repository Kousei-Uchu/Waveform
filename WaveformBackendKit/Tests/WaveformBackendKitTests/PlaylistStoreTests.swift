import XCTest
@testable import WaveformBackendKit

@MainActor
final class PlaylistStoreTests: XCTestCase {
    func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func makeItem(title: String, author: String = "Artist") -> MediaItem {
        let info = MediaInfoDocument(
            itemTitle: title,
            itemAuthor: author,
            source: MediaSource(origin: "ytdlp"),
            packedAt: "2026-01-01T00:00:00.000Z",
            mode: "audio",
            audioMedia: MediaFile(codec: "opus", container: "opus")
        )
        return MediaItem(
            info: info,
            audioFileURL: URL(fileURLWithPath: "/tmp/fake-library/Audio/\(title).opus")
        )
    }

    func testCreateRenameDeletePlaylist() {
        let store = PlaylistStore(storageDirectory: makeTempDir())
        let playlist = store.createPlaylist(name: "Road Trip")
        XCTAssertEqual(store.playlists.count, 1)

        store.rename(playlist, to: "Summer Road Trip")
        XCTAssertEqual(store.playlists.first?.name, "Summer Road Trip")

        store.delete(playlist)
        XCTAssertTrue(store.playlists.isEmpty)
    }

    func testAddAndRemoveItems() {
        let store = PlaylistStore(storageDirectory: makeTempDir())
        let playlist = store.createPlaylist(name: "Favorites")
        let item = makeItem(title: "Song A")

        store.addItem(item, to: playlist)
        XCTAssertEqual(store.playlists.first?.itemIDs, [item.id])

        // Adding the same item twice should be a no-op, not a duplicate entry.
        store.addItem(item, to: playlist)
        XCTAssertEqual(store.playlists.first?.itemIDs.count, 1)

        store.removeItem(item.id, from: playlist)
        XCTAssertEqual(store.playlists.first?.itemIDs, [])
    }

    func testMoveItemsReorders() {
        let store = PlaylistStore(storageDirectory: makeTempDir())
        var playlist = store.createPlaylist(name: "Mix")
        let a = makeItem(title: "A"), b = makeItem(title: "B"), c = makeItem(title: "C")
        store.addItem(a, to: playlist)
        store.addItem(b, to: playlist)
        store.addItem(c, to: playlist)
        playlist = store.playlists[0]

        // Move "A" (index 0) to after "C" (index 2 conceptually -> end)
        store.moveItems(in: playlist, fromOffsets: IndexSet(integer: 0), toOffset: 3)
        XCTAssertEqual(store.playlists.first?.itemIDs, [b.id, c.id, a.id])
    }

    func testLikedSongsToggle() {
        let store = PlaylistStore(storageDirectory: makeTempDir())
        let item = makeItem(title: "Liked Track")
        XCTAssertFalse(store.isLiked(item))

        store.toggleLiked(item)
        XCTAssertTrue(store.isLiked(item))

        store.toggleLiked(item)
        XCTAssertFalse(store.isLiked(item))
    }

    func testPersistenceSurvivesReload() {
        let dir = makeTempDir()
        let item = makeItem(title: "Persisted Track")

        do {
            let store = PlaylistStore(storageDirectory: dir)
            let playlist = store.createPlaylist(name: "Keepers")
            store.addItem(item, to: playlist)
            store.toggleLiked(item)
        }

        // A fresh store pointed at the same directory should reload
        // exactly what was written, proving persist()/load() round-trip.
        let reloaded = PlaylistStore(storageDirectory: dir)
        XCTAssertEqual(reloaded.playlists.count, 1)
        XCTAssertEqual(reloaded.playlists.first?.name, "Keepers")
        XCTAssertEqual(reloaded.playlists.first?.itemIDs, [item.id])
        XCTAssertTrue(reloaded.isLiked(item))
    }

    func testItemsInPlaylistResolvesThroughLibrary() throws {
        let dir = makeTempDir()
        let library = LibraryStore(rootURL: dir.appendingPathComponent("Library", isDirectory: true))
        library.load()

        let audioTempURL = dir.appendingPathComponent(UUID().uuidString)
        try Data("bytes".utf8).write(to: audioTempURL)
        let write = LibraryWrite(
            title: "Resolvable Track",
            author: "Artist",
            source: MediaSource(origin: "ytdlp"),
            audioFile: (url: audioTempURL, media: MediaFile(codec: "opus", container: "opus"))
        )
        let item = try library.addOrUpdate(write)

        let store = PlaylistStore(storageDirectory: dir.appendingPathComponent("store", isDirectory: true))
        let playlist = store.createPlaylist(name: "From Library")
        store.addItem(item, to: playlist)

        let resolved = store.items(in: playlist, library: library)
        XCTAssertEqual(resolved.map(\.title), ["Resolvable Track"])
    }
}
