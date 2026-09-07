import SwiftUI
import WaveformBackendKit

#if os(macOS)
import AppKit
typealias PlatformImage = NSImage
#else
import UIKit
typealias PlatformImage = UIImage
#endif

/// Loads a downloaded item's cover art lazily, on a background task, and
/// caches the decoded image in memory keyed by `MediaItem.id`.
/// `ArtworkView` is the usual entry point into this.
///
/// Much simpler than the old `.cmf`-era version: `MediaItem.artworkFileURL`
/// already points straight at a real file under the library folder
/// (`LibraryStore` resolves that at read time) — there's no companion
/// archive object to look artwork up through anymore, so this no longer
/// needs a `library:` parameter at all.
@MainActor
final class ArtworkStore: ObservableObject {
    @Published private var cache: [String: PlatformImage] = [:]
    private var inFlight: Set<String> = []

    func image(for item: MediaItem) -> PlatformImage? {
        cache[item.id]
    }

    func load(for item: MediaItem) async {
        guard cache[item.id] == nil, !inFlight.contains(item.id) else { return }
        guard let url = item.artworkFileURL else { return }

        inFlight.insert(item.id)
        defer { inFlight.remove(item.id) }

        let data = try? await Task.detached(priority: .utility) {
            try Data(contentsOf: url)
        }.value
        guard let data, let image = PlatformImage(data: data) else { return }
        cache[item.id] = image
    }
}

extension Image {
    init(platformImage: PlatformImage) {
        #if os(macOS)
        self.init(nsImage: platformImage)
        #else
        self.init(uiImage: platformImage)
        #endif
    }
}
