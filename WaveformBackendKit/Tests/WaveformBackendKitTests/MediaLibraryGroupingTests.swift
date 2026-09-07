import XCTest
@testable import WaveformBackendKit

/// Album/artist grouping is unchanged behaviorally from the `.cmf` era
/// (spec §1) but no longer lives behind a multi-archive `MediaLibrary` —
/// it's the standalone `Grouping.albums`/`Grouping.artists` functions
/// `LibraryStore` calls (see `Library/Grouping.swift`). This suite drives
/// them directly against hand-built `MediaItem`s, which is both simpler
/// and a closer match to what `Grouping` actually takes as input than
/// round-tripping through a store.
@MainActor
final class MediaLibraryGroupingTests: XCTestCase {
    func makeItem(
        title: String,
        author: String,
        albumMeta: [String: JSONValue] = [:],
        authorMeta: [String: JSONValue] = [:]
    ) -> MediaItem {
        let info = MediaInfoDocument(
            itemTitle: title,
            itemAuthor: author,
            albumMeta: albumMeta,
            authorMeta: authorMeta,
            source: MediaSource(origin: "ytdlp"),
            packedAt: "2026-01-01T00:00:00.000Z",
            mode: "audio"
        )
        return MediaItem(info: info)
    }

    func testAlbumsGroupBySpotifyAlbumID() {
        let album: [String: JSONValue] = ["id": .string("album-1"), "name": .string("Greatest Hits")]
        let items = [
            makeItem(title: "Track One", author: "Artist", albumMeta: album),
            makeItem(title: "Track Two", author: "Artist", albumMeta: album),
        ]

        let albums = Grouping.albums(from: items)
        XCTAssertEqual(albums.count, 1)
        XCTAssertEqual(albums.first?.title, "Greatest Hits")
        XCTAssertEqual(albums.first?.items.count, 2)
    }

    func testAlbumsFallBackToAuthorAndNameWithoutSpotifyID() {
        let items = [
            makeItem(title: "Solo Track", author: "Bedroom Artist"),
            makeItem(title: "Another Track", author: "Different Artist"),
        ]

        // No shared album id and no shared author -> two distinct groups.
        XCTAssertEqual(Grouping.albums(from: items).count, 2)
    }

    func testArtistsGroupAcrossAlbums() {
        let artist: [String: JSONValue] = ["id": .string("artist-1"), "name": .string("Someone")]
        let items = [
            makeItem(title: "Album A Track", author: "Someone", albumMeta: ["id": .string("album-a")], authorMeta: artist),
            makeItem(title: "Album B Track", author: "Someone", albumMeta: ["id": .string("album-b")], authorMeta: artist),
        ]

        let artists = Grouping.artists(from: items)
        XCTAssertEqual(artists.count, 1)
        XCTAssertEqual(artists.first?.items.count, 2)
        // ...but they're still two distinct albums under that one artist.
        XCTAssertEqual(Grouping.albums(from: items).count, 2)
    }

    func testDistinctTracksWithNoSharedKeyDoNotFalselyGroup() {
        let items = [
            makeItem(title: "Track One", author: "Artist"),
            makeItem(title: "Track Two", author: "Artist"),
        ]

        // No album meta and no album name on either -> each falls back to
        // its own title, so they land in distinct groups despite sharing
        // an author.
        XCTAssertEqual(Grouping.albums(from: items).count, 2)
        // Artists still group correctly by the shared cleaned author string.
        XCTAssertEqual(Grouping.artists(from: items).count, 1)
    }
}
