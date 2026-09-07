import Foundation

public struct Playlist: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var itemIDs: [String]
    public var createdAt: Date

    public init(id: UUID = UUID(), name: String, itemIDs: [String] = [], createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.itemIDs = itemIDs
        self.createdAt = createdAt
    }
}

/// Persists user-created playlists and "liked" items to a small JSON file
/// on disk. Playlists reference items by `MediaItem.id` — a stable UUID
/// assigned once at import/download time (§6/§7) and stored in
/// `library.json`, so entries keep resolving even if the library folder
/// moves, unlike the old path-derived identity this replaced.
@MainActor
public final class PlaylistStore: ObservableObject {
    @Published public private(set) var playlists: [Playlist] = []
    @Published public private(set) var likedItemIDs: Set<String> = []

    private let fileURL: URL

    private struct Storage: Codable {
        var playlists: [Playlist]
        var likedItemIDs: Set<String>
    }
    
    public func playlist(withID id: UUID) -> Playlist? {
        playlists.first { $0.id == id }
    }

    public init(storageDirectory: URL? = nil) {
        let directory = storageDirectory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WaveformBackendKit", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.fileURL = directory.appendingPathComponent("playlists.json")
        load()
    }

    @discardableResult
    public func createPlaylist(name: String) -> Playlist {
        let playlist = Playlist(name: name)
        playlists.append(playlist)
        persist()
        return playlist
    }

    public func rename(_ playlist: Playlist, to name: String) {
        guard let index = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        playlists[index].name = name
        persist()
    }

    public func delete(_ playlist: Playlist) {
        playlists.removeAll { $0.id == playlist.id }
        persist()
    }

    public func addItem(_ item: MediaItem, to playlist: Playlist) {
        guard let index = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        guard !playlists[index].itemIDs.contains(item.id) else { return }
        playlists[index].itemIDs.append(item.id)
        persist()
    }

    public func removeItem(_ itemID: String, from playlist: Playlist) {
        guard let index = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        playlists[index].itemIDs.removeAll { $0 == itemID }
        persist()
    }

    public func moveItems(in playlist: Playlist, fromOffsets: IndexSet, toOffset: Int) {
        guard let index = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        var ids = playlists[index].itemIDs
        let moving = fromOffsets.map { ids[$0] }
        for i in fromOffsets.sorted(by: >) { ids.remove(at: i) }
        let removedBeforeTarget = fromOffsets.filter { $0 < toOffset }.count
        let insertionIndex = min(max(0, toOffset - removedBeforeTarget), ids.count)
        ids.insert(contentsOf: moving, at: insertionIndex)
        playlists[index].itemIDs = ids
        persist()
    }

    public func toggleLiked(_ item: MediaItem) {
        if likedItemIDs.contains(item.id) {
            likedItemIDs.remove(item.id)
        } else {
            likedItemIDs.insert(item.id)
        }
        persist()
    }

    public func isLiked(_ item: MediaItem) -> Bool {
        likedItemIDs.contains(item.id)
    }

    public func items(in playlist: Playlist, library: LibraryStore) -> [MediaItem] {
        playlist.itemIDs.compactMap { library.item(withID: $0) }
    }

    public func likedItems(library: LibraryStore) -> [MediaItem] {
        library.items.filter { likedItemIDs.contains($0.id) }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        guard let storage = try? JSONDecoder().decode(Storage.self, from: data) else { return }
        playlists = storage.playlists
        likedItemIDs = storage.likedItemIDs
    }

    private func persist() {
        let storage = Storage(playlists: playlists, likedItemIDs: likedItemIDs)
        guard let data = try? JSONEncoder().encode(storage) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
