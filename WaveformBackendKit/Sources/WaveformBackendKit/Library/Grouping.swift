import Foundation

public struct AlbumGroup: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let author: String
    public let items: [MediaItem]

    public init(id: String, title: String, author: String, items: [MediaItem]) {
        self.id = id
        self.title = title
        self.author = author
        self.items = items
    }
}

public struct ArtistGroup: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let items: [MediaItem]

    public init(id: String, name: String, items: [MediaItem]) {
        self.id = id
        self.name = name
        self.items = items
    }
}

/// Album/artist grouping heuristic — unchanged from the `.cmf` era (§1),
/// just moved out of `MediaLibrary` into standalone functions `LibraryStore`
/// calls, since there's no longer a multi-archive object to hang them off.
public enum Grouping {
    /// Items grouped by album — Spotify album id when available, otherwise
    /// a same-author/same-album-name fallback (see `MediaItem.albumGroupKey`).
    public static func albums(from items: [MediaItem]) -> [AlbumGroup] {
        Dictionary(grouping: items, by: \.albumGroupKey)
            .map { key, groupItems -> AlbumGroup in
                let sorted = groupItems.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
                let representative = sorted.first
                return AlbumGroup(
                    id: key,
                    title: representative?.albumName ?? representative?.title ?? "Unknown Album",
                    author: representative?.author ?? "",
                    items: sorted
                )
            }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// Items grouped by artist — Spotify artist id when available,
    /// otherwise the cleaned author string (see `MediaItem.artistGroupKey`).
    public static func artists(from items: [MediaItem]) -> [ArtistGroup] {
        Dictionary(grouping: items, by: \.artistGroupKey)
            .map { key, groupItems -> ArtistGroup in
                let sorted = groupItems.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
                return ArtistGroup(id: key, name: sorted.first?.author ?? "Unknown Artist", items: sorted)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
