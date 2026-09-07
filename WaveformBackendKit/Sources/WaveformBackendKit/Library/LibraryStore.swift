import Foundation
import os

public enum LibraryError: Error, LocalizedError, Sendable {
    case decodeFailed(String)
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .decodeFailed(let message): "Couldn't read your library: \(message)"
        case .writeFailed(let message): "Couldn't save to your library: \(message)"
        }
    }
}

/// A completed write into the library folder — the result of the
/// resolve→fetch (stream-copy) path in `Fetch.swift`, or of importing a
/// track some other way. `LibraryStore.addOrUpdate` turns this into a
/// `library.json` entry and returns the resulting `MediaItem`.
public struct LibraryWrite: Sendable {
    public var title: String
    public var author: String
    public var durationMS: Double?
    public var source: MediaSource
    public var match: MediaMatch
    public var albumMeta: [String: JSONValue]
    public var authorMeta: [String: JSONValue]
    /// Local temp-file URL for the fetched audio, if any — moved (not
    /// copied) into `Audio/{Artist}/{Title}.{ext}` by the store.
    public var audioFile: (url: URL, media: MediaFile)?
    public var videoFile: (url: URL, media: MediaFile)?
    /// Local temp-file URL for artwork, if any — content-hashed into
    /// `Artwork/{sha256}.jpg` (§5/§6), deduped against what's already there.
    public var artworkFile: URL?

    public init(
        title: String,
        author: String,
        durationMS: Double? = nil,
        source: MediaSource,
        match: MediaMatch = MediaMatch(),
        albumMeta: [String: JSONValue] = [:],
        authorMeta: [String: JSONValue] = [:],
        audioFile: (url: URL, media: MediaFile)? = nil,
        videoFile: (url: URL, media: MediaFile)? = nil,
        artworkFile: URL? = nil
    ) {
        self.title = title
        self.author = author
        self.durationMS = durationMS
        self.source = source
        self.match = match
        self.albumMeta = albumMeta
        self.authorMeta = authorMeta
        self.audioFile = audioFile
        self.videoFile = videoFile
        self.artworkFile = artworkFile
    }
}

/// Owns the unified library folder (§6): `library.json` plus the
/// `Audio/`/`Video/`/`Artwork/` tree beneath `rootURL`. This is the one
/// object that reads and writes that folder — `Fetch.swift` and `Shrink.swift`
/// both go through it rather than touching the filesystem directly, which
/// is what keeps dedup (§5) and the "never a dangling `paths.*` reference"
/// guarantee (§6) centralized in one place.
@MainActor
public final class LibraryStore: ObservableObject {
    @Published public private(set) var items: [MediaItem] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var lastError: String?

    public let rootURL: URL
    private var manifestFileURL: URL { rootURL.appendingPathComponent("library.json") }
    private var audioDirectory: URL { rootURL.appendingPathComponent("Audio", isDirectory: true) }
    private var videoDirectory: URL { rootURL.appendingPathComponent("Video", isDirectory: true) }
    private var artworkDirectory: URL { rootURL.appendingPathComponent("Artwork", isDirectory: true) }

    private var documents: [MediaInfoDocument] = []

    public init(rootURL: URL) {
        self.rootURL = rootURL
        try? FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: videoDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: artworkDirectory, withIntermediateDirectories: true)
    }

    /// Loads `library.json` from disk (creating an empty one if it doesn't
    /// exist yet — e.g. first launch, §2 "empty library, no migration").
    public func load() {
        isLoading = true
        defer { isLoading = false }

        guard let data = try? Data(contentsOf: manifestFileURL) else {
            documents = []
            rebuildItems()
            return
        }
        do {
            documents = try JSONDecoder().decode([MediaInfoDocument].self, from: data)
        } catch {
            WFLog.library.error("Couldn't decode library.json: \(error.localizedDescription, privacy: .public)")
            lastError = "Couldn't read library.json: \(error.localizedDescription)"
            documents = []
        }
        rebuildItems()
    }

    // MARK: - Dedup (§5)

    /// Source-ID-first dedup: looks for an existing entry that matches
    /// `source` *before* any resolve/fetch work starts for a download. A
    /// match means the caller should skip immediately — no network calls,
    /// no fetch — and surface "already in your library" pointing at the
    /// returned item.
    public func existingItem(matching source: MediaSource) -> MediaItem? {
        guard let doc = documents.first(where: { $0.source.matchesSameTrack(as: source) }) else { return nil }
        return makeItem(from: doc)
    }

    // MARK: - Writing

    /// Commits a `LibraryWrite` into the library: moves audio/video files
    /// into `Audio/`/`Video/`, content-hashes artwork into `Artwork/`
    /// (deduped against whatever's already there), and appends/updates the
    /// `library.json` entry. Always re-checks source-ID dedup first, so a
    /// caller that raced past the earlier `existingItem` check (e.g. two
    /// downloads of the same track kicked off close together) still can't
    /// end up with two entries for the same track.
    @discardableResult
    public func addOrUpdate(_ write: LibraryWrite) throws -> MediaItem {
        if let existing = existingItem(matching: write.source) {
            return existing
        }

        let id = UUID()
        let slugBase = "\(Slug.make(write.author))/\(Slug.make(write.title))"

        var paths = MediaPaths()
        var audioMedia: MediaFile?
        var videoMedia: MediaFile?

        if let audio = write.audioFile {
            let filename = "\(slugBase).\(audio.media.container)"
            try moveFile(from: audio.url, into: audioDirectory, relativePath: filename)
            paths.audio = filename
            audioMedia = audio.media
        }
        if let video = write.videoFile {
            let filename = "\(slugBase).\(video.media.container)"
            try moveFile(from: video.url, into: videoDirectory, relativePath: filename)
            paths.video = filename
            videoMedia = video.media
        }
        if let artworkURL = write.artworkFile {
            if let relativeArtworkPath = try storeArtworkDeduped(artworkURL) {
                paths.assets = [relativeArtworkPath]
            }
        }

        let mode: String
        switch (paths.audio != nil, paths.video != nil) {
        case (true, true): mode = "both"
        case (false, true): mode = "video"
        default: mode = "audio"
        }

        let doc = MediaInfoDocument(
            id: id,
            itemTitle: write.title,
            itemAuthor: write.author,
            albumMeta: write.albumMeta,
            authorMeta: write.authorMeta,
            paths: paths,
            source: write.source,
            durationMS: write.durationMS,
            match: write.match,
            packedAt: ISO8601DateFormatter().string(from: Date()),
            mode: mode,
            audioMedia: audioMedia,
            videoMedia: videoMedia
        )
        documents.append(doc)
        try persist()
        rebuildItems()
        return makeItem(from: doc)
    }

    /// Rewrites a single item's on-disk file for `kind` in place (used by
    /// the Shrink action, §3) and updates its `media` metadata — a
    /// mutation of the existing entry, not a new one; `id`/playlist
    /// references are untouched.
    public func replaceFile(
        forItemID id: UUID,
        kind: TrackKind,
        newFileURL: URL,
        newMedia: MediaFile
    ) throws {
        guard let index = documents.firstIndex(where: { $0.id == id }) else { return }
        var doc = documents[index]
        let directory = kind == .audio ? audioDirectory : videoDirectory
        let slugBase = "\(Slug.make(doc.itemAuthor))/\(Slug.make(doc.itemTitle))"
        let filename = "\(slugBase).\(newMedia.container)"

        // Remove whatever file used to be there for this kind before
        // writing the replacement, so Shrink never leaves an orphaned
        // pre-shrink file behind under a stale extension.
        if let oldRelative = (kind == .audio ? doc.paths.audio : doc.paths.video) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(oldRelative))
        }
        try moveFile(from: newFileURL, into: directory, relativePath: filename)

        switch kind {
        case .audio:
            doc.paths.audio = filename
            doc.audioMedia = newMedia
        case .video:
            doc.paths.video = filename
            doc.videoMedia = newMedia
        }
        documents[index] = doc
        try persist()
        rebuildItems()
    }

    public func remove(_ item: MediaItem) throws {
        guard let index = documents.firstIndex(where: { $0.id == item.info.id }) else { return }
        let doc = documents[index]
        if let audio = doc.paths.audio {
            try? FileManager.default.removeItem(at: audioDirectory.appendingPathComponent(audio))
        }
        if let video = doc.paths.video {
            try? FileManager.default.removeItem(at: videoDirectory.appendingPathComponent(video))
        }
        // Artwork is deliberately left alone — it may be shared with
        // other items via content-hash dedup (§5/§6), and nothing here
        // tracks reference counts for it. An orphaned artwork file is a
        // few KB and a fine trade for not needing that bookkeeping.
        documents.remove(at: index)
        try persist()
        rebuildItems()
    }

    // MARK: - Queries

    public func item(withID id: String) -> MediaItem? {
        items.first { $0.id == id }
    }

    public func items(matching query: String) -> [MediaItem] {
        guard !query.isEmpty else { return items }
        let q = query.lowercased()
        return items.filter {
            $0.title.lowercased().contains(q) || $0.author.lowercased().contains(q)
        }
    }

    public var albums: [AlbumGroup] { Grouping.albums(from: items) }
    public var artists: [ArtistGroup] { Grouping.artists(from: items) }

    // MARK: - Private

    private func makeItem(from doc: MediaInfoDocument) -> MediaItem {
        MediaItem(
            info: doc,
            audioFileURL: doc.paths.audio.map { audioDirectory.appendingPathComponent($0) },
            videoFileURL: doc.paths.video.map { videoDirectory.appendingPathComponent($0) },
            artworkFileURL: doc.paths.assets.first.map { rootURL.appendingPathComponent($0) }
        )
    }

    private func rebuildItems() {
        items = documents
            .map(makeItem)
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private func persist() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(documents)
            try data.write(to: manifestFileURL, options: .atomic)
        } catch {
            WFLog.library.error("Couldn't write library.json: \(error.localizedDescription, privacy: .public)")
            throw LibraryError.writeFailed(error.localizedDescription)
        }
    }

    private func moveFile(from sourceURL: URL, into directory: URL, relativePath: String) throws {
        let destination = directory.appendingPathComponent(relativePath)
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.moveItem(at: sourceURL, to: destination)
    }

    /// Content-hashes `sourceURL` into `Artwork/{sha256}.jpg`, reusing an
    /// existing file with the same hash rather than duplicating it — the
    /// one place hashing still applies post-v2 (§5). Returns the relative
    /// path (`"Artwork/<hash>.jpg"`) to store in `paths.assets`.
    private func storeArtworkDeduped(_ sourceURL: URL) throws -> String? {
        guard let data = try? Data(contentsOf: sourceURL) else { return nil }
        let hash = Hashing.sha256(data)
        let relativePath = "Artwork/\(hash).jpg"
        let destination = rootURL.appendingPathComponent(relativePath)
        if !FileManager.default.fileExists(atPath: destination.path) {
            try data.write(to: destination, options: .atomic)
        }
        try? FileManager.default.removeItem(at: sourceURL)
        return relativePath
    }
}
