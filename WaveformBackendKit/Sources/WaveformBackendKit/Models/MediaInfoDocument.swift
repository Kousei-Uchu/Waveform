import Foundation

/// The `paths` block: `audio`/`video` are single nullable *relative* paths
/// into `Audio/`/`Video/` (unlike the old `.cmf` zip-entry paths, these
/// point at real files on disk — see `LibraryStore`), `assets` is 0–2
/// entries into `Artwork/`.
public struct MediaPaths: Codable, Hashable, Sendable {
    public var audio: String?
    public var video: String?
    public var assets: [String]

    public init(audio: String? = nil, video: String? = nil, assets: [String] = []) {
        self.audio = audio
        self.video = video
        self.assets = assets
    }
}

/// What's actually on disk for a downloaded item — added in the v3
/// (stream-copy) rewrite, since a download is no longer guaranteed to be a
/// single fixed codec/container. Absent (`nil`) for `.remote` items that
/// haven't been downloaded yet.
public struct MediaFile: Codable, Hashable, Sendable {
    /// e.g. "av1", "vp9", "h264" (video) or "opus", "aac" (audio), as
    /// reported by the resolved stream variant at fetch time.
    public var codec: String
    /// The container/file extension actually written — "webm", "mp4",
    /// "m4a", etc. Matches `MediaPaths.audio`/`.video`'s extension.
    public var container: String
    /// Whether this file has been through the explicit "Shrink" re-encode
    /// action (§3 of the spec). Starts `false` — a download that happened
    /// to already be AV1/Opus can stay `false`, since nothing ran.
    public var shrunk: Bool
    /// The resolution/bitrate cap (if any) in effect when this file was
    /// fetched, kept for reference only — e.g. "1080p", "128kbps".
    public var downloadCap: String?

    public init(codec: String, container: String, shrunk: Bool = false, downloadCap: String? = nil) {
        self.codec = codec
        self.container = container
        self.shrunk = shrunk
        self.downloadCap = downloadCap
    }

    enum CodingKeys: String, CodingKey {
        case codec, container, shrunk
        case downloadCap = "download_cap"
    }
}

/// A 1:1 mirror of `library.json`'s per-item shape — a direct descendant
/// of the old `.cmf` pipeline's `info.json` (see `BACKEND_README.md` for
/// the full field-by-field rationale), carried forward with the v3
/// changes: `paths` point at real files instead of zip entries, `id` is a
/// stable UUID assigned once at import/download time instead of being
/// re-derived from source fields on every read, and `media` records what
/// codec/container actually ended up on disk for each track (since
/// downloads are stream-copied rather than normalized to one codec).
public struct MediaInfoDocument: Codable, Hashable, Sendable {
    /// Assigned once, at import/download time, and never recomputed —
    /// this is what playlists/liked-songs reference (§6), and what
    /// survives the file moving on disk.
    public var id: UUID
    public var itemTitle: String
    public var itemAuthor: String
    /// Shape varies by source: full Spotify Album object, a slim fallback,
    /// or `{}` for non-Spotify sources. Left open-ended deliberately.
    public var albumMeta: [String: JSONValue]
    /// Same three-tier shape as `albumMeta`, but for the primary artist —
    /// full Spotify Artist object, slim fallback, or `{ "name": ... }`.
    public var authorMeta: [String: JSONValue]
    public var paths: MediaPaths
    public var source: MediaSource
    /// Duration of the *originally selected* item, in milliseconds — not
    /// measured on the downloaded file. `durationSeconds` below converts it.
    public var durationMS: Double?
    public var match: MediaMatch
    /// ISO-8601 timestamp this specific item finished processing.
    public var packedAt: String
    public var mode: String // "audio" | "video" | "both"
    /// What's on disk for the audio file, if any. `nil` if this item has
    /// no audio track (video-only) — not to be confused with a
    /// `.remote(RemoteRef)` `Playable`, which has no `MediaInfoDocument`
    /// at all yet.
    public var audioMedia: MediaFile?
    public var videoMedia: MediaFile?

    enum CodingKeys: String, CodingKey {
        case id
        case itemTitle = "item_title"
        case itemAuthor = "item_author"
        case albumMeta = "album_meta"
        case authorMeta = "author_meta"
        case paths
        case source
        case durationMS = "duration_ms"
        case match
        case packedAt = "packed_at"
        case mode
        case audioMedia = "audio_media"
        case videoMedia = "video_media"
    }

    public init(
        id: UUID = UUID(),
        itemTitle: String,
        itemAuthor: String,
        albumMeta: [String: JSONValue] = [:],
        authorMeta: [String: JSONValue] = [:],
        paths: MediaPaths = MediaPaths(),
        source: MediaSource,
        durationMS: Double? = nil,
        match: MediaMatch = MediaMatch(),
        packedAt: String,
        mode: String,
        audioMedia: MediaFile? = nil,
        videoMedia: MediaFile? = nil
    ) {
        self.id = id
        self.itemTitle = itemTitle
        self.itemAuthor = itemAuthor
        self.albumMeta = albumMeta
        self.authorMeta = authorMeta
        self.paths = paths
        self.source = source
        self.durationMS = durationMS
        self.match = match
        self.packedAt = packedAt
        self.mode = mode
        self.audioMedia = audioMedia
        self.videoMedia = videoMedia
    }

    public var durationSeconds: TimeInterval {
        guard let durationMS else { return 0 }
        return durationMS / 1000
    }

    public var packedAtDate: Date? {
        ISO8601DateFormatter().date(from: packedAt)
    }
}
