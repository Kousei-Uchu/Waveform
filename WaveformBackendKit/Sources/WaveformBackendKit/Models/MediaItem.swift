import Foundation

/// One item in the unified library folder (§6): the decoded
/// `library.json` entry plus absolute file URLs for whichever of
/// audio/video/artwork it actually has.
///
/// Unlike the old `.cmf`-backed `MediaItem`, this never needs a
/// companion archive object to resolve a file — `LibraryStore` hands out
/// `MediaItem`s with `audioFileURL`/`videoFileURL`/`artworkFileURL`
/// already pointing at real files on disk (or `nil` if that track/asset
/// doesn't exist), computed once against the library root at read time.
public struct MediaItem: Identifiable, Hashable, Sendable {
    public let info: MediaInfoDocument
    public let audioFileURL: URL?
    public let videoFileURL: URL?
    public let artworkFileURL: URL?

    public init(
        info: MediaInfoDocument,
        audioFileURL: URL? = nil,
        videoFileURL: URL? = nil,
        artworkFileURL: URL? = nil
    ) {
        self.info = info
        self.audioFileURL = audioFileURL
        self.videoFileURL = videoFileURL
        self.artworkFileURL = artworkFileURL
    }

    /// The stable identity playlists/liked-songs/the queue reference —
    /// `info.id`, assigned once at import/download time (§6/§7). Exposed
    /// as a `String` since `Playable`/`QueueEntry` want one identity type
    /// that also covers `.remote` items, which have no `UUID` yet.
    public var id: String { "library:\(info.id.uuidString)" }

    public var title: String { info.itemTitle }
    public var author: String { info.itemAuthor }
    public var duration: TimeInterval { info.durationSeconds }
    public var hasAudio: Bool { audioFileURL != nil }
    public var hasVideo: Bool { videoFileURL != nil }

    public func fileURL(for kind: TrackKind) -> URL? {
        switch kind {
        case .audio: audioFileURL
        case .video: videoFileURL
        }
    }

    /// What's on disk for a given kind — codec/container/shrunk state
    /// (§7). `nil` if that kind isn't downloaded.
    public func media(for kind: TrackKind) -> MediaFile? {
        switch kind {
        case .audio: info.audioMedia
        case .video: info.videoMedia
        }
    }

    // MARK: - Album/artist grouping

    /// Spotify album id when `album_meta` is Spotify-shaped; `nil` for
    /// non-Spotify sources or when enrichment failed and only the slim/empty
    /// shape is present without an id.
    public var albumID: String? { info.albumMeta["id"]?.stringValue }
    public var albumName: String? { info.albumMeta["name"]?.stringValue }

    public var artistID: String? { info.authorMeta["id"]?.stringValue }

    /// Grouping key for "same album": the Spotify album id when available,
    /// otherwise `author + album name` (or the item's own title if there's
    /// no album name at all), so non-Spotify items still group sensibly by
    /// artist instead of every track becoming its own singleton "album".
    public var albumGroupKey: String {
        albumID ?? "\(author.lowercased())::\(albumName?.lowercased() ?? title.lowercased())"
    }

    /// Grouping key for "same artist": the Spotify artist id when
    /// available, otherwise the cleaned author string.
    public var artistGroupKey: String {
        artistID ?? author.lowercased()
    }
}
