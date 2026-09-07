import Foundation

/// The `source` block in `library.json` — where the originally-selected
/// item came from. `spotifyID`/`isrc` are only ever populated for
/// `origin == "spotify"`; `youtubeID` is populated whenever it's known
/// regardless of origin. This is what `LibraryStore`'s source-ID dedup
/// (§5) compares against before any resolve/fetch work starts.
public struct MediaSource: Codable, Hashable, Sendable {
    public var origin: String
    public var url: String?
    public var spotifyID: String?
    public var youtubeID: String?
    public var isrc: String?

    enum CodingKeys: String, CodingKey {
        case origin, url
        case spotifyID = "spotify_id"
        case youtubeID = "youtube_id"
        case isrc
    }

    public init(
        origin: String,
        url: String? = nil,
        spotifyID: String? = nil,
        youtubeID: String? = nil,
        isrc: String? = nil
    ) {
        self.origin = origin
        self.url = url
        self.spotifyID = spotifyID
        self.youtubeID = youtubeID
        self.isrc = isrc
    }

    /// Whether `other` refers to the same underlying track as this source,
    /// for source-ID-first dedup (§5) — a match on *any* shared, non-empty
    /// id is enough; the two sources don't need to agree on every field.
    public func matchesSameTrack(as other: MediaSource) -> Bool {
        if let a = spotifyID, !a.isEmpty, let b = other.spotifyID, !b.isEmpty, a == b { return true }
        if let a = youtubeID, !a.isEmpty, let b = other.youtubeID, !b.isEmpty, a == b { return true }
        if let a = isrc, !a.isEmpty, let b = other.isrc, !b.isEmpty, a == b { return true }
        return false
    }
}
