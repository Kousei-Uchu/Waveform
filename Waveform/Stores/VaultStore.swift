import Foundation

/// Owns "where the unified library folder lives" (§6/§8) — nothing else.
/// The old per-`.cmf`-file bookmark bookkeeping (a vault *folder* plus an
/// arbitrary list of individually-imported files, each with its own
/// persisted security-scoped bookmark) is gone entirely now that
/// `LibraryStore` owns everything under one folder and nothing is
/// "imported" anymore — content only ever arrives via the Search &
/// Download screen (`Acquire/`), never a file picker. This type's only
/// remaining job is picking/persisting that one folder's URL.
@MainActor
final class VaultStore: ObservableObject {
    @Published private(set) var libraryRootURL: URL
    @Published var lastError: String?

    private let bookmarkKey = "waveform.libraryRootBookmark"

    init() {
        libraryRootURL = Self.defaultLibraryRootURL()
        if let data = UserDefaults.standard.data(forKey: bookmarkKey),
           let resolved = try? Self.resolveBookmark(data) {
            _ = resolved.startAccessingSecurityScopedResource()
            libraryRootURL = resolved
        }
        try? FileManager.default.createDirectory(at: libraryRootURL, withIntermediateDirectories: true)
    }

    /// macOS-only: lets the user relocate the library folder (e.g. onto an
    /// external drive) via `.fileImporter(allowedContentTypes: [.folder])`.
    /// Not offered on iOS — per §6, the sandboxed Documents directory
    /// (exposed via the Files app with file sharing enabled) is the only
    /// user-facing location there; there's no broader filesystem to
    /// relocate into the way `~/Music` gives macOS one.
    func relocate(to url: URL) {
        #if os(macOS)
        do {
            let bookmark = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
            _ = url.startAccessingSecurityScopedResource()
            libraryRootURL = url
        } catch {
            lastError = "Couldn't use that folder: \(error.localizedDescription)"
        }
        #endif
    }

    /// iOS: `Documents/Waveform`, exposed via the Files app under "On My
    /// iPhone → Waveform" with file sharing enabled (§6 — there's no
    /// app-writable system "Music" folder on iOS the way macOS has one).
    /// macOS: defaults to `~/Music/Waveform` where real filesystem access
    /// exists, falling back to `Documents/Waveform` if `~/Music` somehow
    /// isn't available (e.g. a restricted sandbox profile).
    private static func defaultLibraryRootURL() -> URL {
        let fm = FileManager.default
        #if os(macOS)
        let base = fm.urls(for: .musicDirectory, in: .userDomainMask).first
            ?? fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        #else
        let base = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        #endif
        return base.appendingPathComponent("Waveform", isDirectory: true)
    }

    private static func resolveBookmark(_ data: Data) throws -> URL {
        var isStale = false
        #if os(macOS)
        return try URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        #else
        return try URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale)
        #endif
    }
}
