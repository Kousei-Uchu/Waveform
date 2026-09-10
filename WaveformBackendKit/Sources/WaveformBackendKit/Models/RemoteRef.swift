import Foundation

/// Enough information to resolve-and-stream a search result that isn't
/// (yet) in the library — see spec §4. Carries no local file paths at
/// all; `Resolve.swift` turns this into a playable URL just before it's
/// actually needed, since resolved stream URLs (YouTube's
/// `googlevideo.com` links) expire and must never be cached across a
/// browsing session.
public struct RemoteRef: Identifiable, Hashable, Sendable {
    /// Stable per search result, so a `QueueEntry`/SwiftUI list can key on
    /// it even though there's no library UUID yet. Not persisted anywhere.
    public let id: String
    public let title: String
    public let author: String
    public let duration: TimeInterval
    public let source: MediaSource
    /// Whether audio, video, or both are available to resolve for this
    /// result — mirrors `MediaInfoDocument.mode` but before anything has
    /// been fetched.
    public let availableKinds: Set<TrackKind>
    /// Thumbnail URL for search-result UI, if any. Not the same as a
    /// downloaded item's `artworkFileURL` — nothing is written to disk
    /// for a remote item until Download is tapped.
    public let thumbnailURL: URL?
    /// The `album_meta`/`author_meta` blocks (§7) this reference would
    /// carry into the library if downloaded — computed once, at
    /// `SearchCandidate.remoteRef(...)` time, via `libraryAlbumMeta`/
    /// `libraryAuthorMeta`, so a Spotify-sourced search result's real
    /// album/artist data survives past the audio-matching step instead
    /// of being lost the moment it's resolved to a YouTube-backed
    /// `RemoteRef` — see `Match.swift`'s merged-candidate construction
    /// for where that data previously got dropped.
    public let albumMeta: [String: JSONValue]
    public let authorMeta: [String: JSONValue]
    /// `Match.pickAudioSource`/`pickVideoSource`'s verdict on this pick,
    /// when it went through one — `true` for anything that didn't need
    /// matching at all (a direct YouTube pick) or hasn't been matched
    /// yet. `DownloadManager`'s Conservative Matching setting (§8) reads
    /// this before committing a download: a `false` here means the
    /// weighted search never cleared `Match.qualifies`'s confidence
    /// floor, so this might be the wrong track/video.
    public let matchConfident: Bool
    /// The `match.audio`/`match.video` block (§7) this reference would
    /// contribute to `library.json` if downloaded — `nil` when nothing
    /// meaningful to record exists yet (mirrors `matchConfident`'s
    /// "hasn't been matched" case).
    public let matchNote: MatchNote?

    public init(
        id: String,
        title: String,
        author: String,
        duration: TimeInterval,
        source: MediaSource,
        availableKinds: Set<TrackKind>,
        thumbnailURL: URL? = nil,
        albumMeta: [String: JSONValue] = [:],
        authorMeta: [String: JSONValue] = [:],
        matchConfident: Bool = true,
        matchNote: MatchNote? = nil
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.duration = duration
        self.source = source
        self.availableKinds = availableKinds
        self.thumbnailURL = thumbnailURL
        self.albumMeta = albumMeta
        self.authorMeta = authorMeta
        self.matchConfident = matchConfident
        self.matchNote = matchNote
    }
}
