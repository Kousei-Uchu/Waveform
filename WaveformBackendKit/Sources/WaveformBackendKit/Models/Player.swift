import Foundation

/// Anything that can sit in the `PlaybackQueue` — a real library entry, or
/// a not-yet-downloaded remote search result (§4). The queue, mini player,
/// and Now Playing screen all work against this type and don't need to
/// know which kind they have; only `MediaPlayerController` (when it
/// actually needs bytes to hand to the engine) and the UI's
/// streaming/downloaded badge care about the distinction.
public enum Playable: Identifiable, Hashable, Sendable {
    case library(MediaItem)
    case remote(RemoteRef)

    public var id: String {
        switch self {
        case .library(let item): item.id
        case .remote(let ref): "remote:\(ref.id)"
        }
    }

    public var title: String {
        switch self {
        case .library(let item): item.title
        case .remote(let ref): ref.title
        }
    }

    public var author: String {
        switch self {
        case .library(let item): item.author
        case .remote(let ref): ref.author
        }
    }

    public var duration: TimeInterval {
        switch self {
        case .library(let item): item.duration
        case .remote(let ref): ref.duration
        }
    }

    public var albumName: String? {
        switch self {
        case .library(let item): item.albumName
        case .remote: nil
        }
    }

    public func hasKind(_ kind: TrackKind) -> Bool {
        switch self {
        case .library(let item):
            switch kind {
            case .audio: item.hasAudio
            case .video: item.hasVideo
            }
        case .remote(let ref):
            ref.availableKinds.contains(kind)
        }
    }

    public var hasAudio: Bool { hasKind(.audio) }
    public var hasVideo: Bool { hasKind(.video) }

    /// Whether this track already exists in the permanent library.
    /// Playback prefers the local copy automatically once this is true —
    /// see `MediaPlayerController.loadCurrent()` — same as Spotify
    /// preferring an offline copy over re-streaming.
    public var isDownloaded: Bool {
        if case .library = self { return true }
        return false
    }

    /// The underlying `MediaItem`, if this is a library entry — a
    /// convenience for call sites (playlists, "add to playlist", Shrink)
    /// that only make sense for already-downloaded tracks.
    public var libraryItem: MediaItem? {
        if case .library(let item) = self { return item }
        return nil
    }

    /// The underlying `RemoteRef`, if this hasn't been downloaded yet.
    public var remoteRef: RemoteRef? {
        if case .remote(let ref) = self { return ref }
        return nil
    }
}
