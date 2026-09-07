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

    public init(
        id: String,
        title: String,
        author: String,
        duration: TimeInterval,
        source: MediaSource,
        availableKinds: Set<TrackKind>,
        thumbnailURL: URL? = nil
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.duration = duration
        self.source = source
        self.availableKinds = availableKinds
        self.thumbnailURL = thumbnailURL
    }
}
