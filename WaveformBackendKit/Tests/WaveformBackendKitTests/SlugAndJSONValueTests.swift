import XCTest
@testable import WaveformBackendKit

final class SlugTests: XCTestCase {
    func testBasicSlug() {
        XCTAssertEqual(Slug.make("Hello World"), "Hello_World")
    }

    func testStripsPunctuation() {
        XCTAssertEqual(Slug.make("Song (Live) [Remaster]!"), "Song_Live_Remaster")
    }

    func testEmptyInputFallsBackToUntitled() {
        XCTAssertEqual(Slug.make("!!!"), "untitled")
    }

    func testTruncatesLongInput() {
        let long = String(repeating: "a", count: 200)
        XCTAssertEqual(Slug.make(long).count, 80)
    }
}

final class JSONValueTests: XCTestCase {
    func testRoundTripThroughInfoDocument() throws {
        let doc = MediaInfoDocument(
            itemTitle: "T",
            itemAuthor: "A",
            albumMeta: ["track_count": .number(12), "explicit": .bool(false)],
            authorMeta: ["source_url": .string("https://example.com")],
            source: MediaSource(origin: "spotify", spotifyID: "abc"),
            durationMS: 42_000,
            match: MediaMatch(audio: MatchNote(strategy: "provided_youtube_id")),
            packedAt: "2026-01-01T00:00:00.000Z",
            mode: "audio"
        )
        let data = try JSONEncoder().encode(doc)
        let decoded = try JSONDecoder().decode(MediaInfoDocument.self, from: data)

        XCTAssertEqual(decoded.itemTitle, "T")
        XCTAssertEqual(decoded.albumMeta["track_count"]?.numberValue, 12)
        XCTAssertEqual(decoded.albumMeta["explicit"]?.boolValue, false)
        XCTAssertEqual(decoded.authorMeta["source_url"]?.stringValue, "https://example.com")
        XCTAssertEqual(decoded.durationSeconds, 42, accuracy: 0.001)
        XCTAssertEqual(decoded.match.audio?.strategy, "provided_youtube_id")
        XCTAssertNil(decoded.match.audio?.score) // null in JSON, per the provided_youtube_id shape
    }
}
