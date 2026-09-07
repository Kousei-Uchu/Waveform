import Foundation

/// One slot in the `PlaybackQueue` — a `Playable` (library item or remote
/// stream reference, §4) plus which track (`audio`/`video`) of it this
/// slot represents.
public struct QueueEntry: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let playable: Playable
    public let kind: TrackKind

    public init(playable: Playable, kind: TrackKind, id: UUID = UUID()) {
        self.id = id
        self.playable = playable
        self.kind = kind
    }
}

public enum RepeatMode: Hashable, Sendable, CaseIterable {
    case off
    case one
    case all
}
