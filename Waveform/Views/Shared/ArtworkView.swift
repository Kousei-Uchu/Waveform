import SwiftUI
import WaveformBackendKit

/// Shows a track's artwork regardless of whether it's a downloaded
/// library item or a not-yet-downloaded remote search result (§4) — the
/// queue, mini player, and Now Playing screen all work against `Playable`
/// and shouldn't need to branch on which kind they have just to show a
/// picture. A library item's real artwork file is loaded through
/// `ArtworkStore` (cached, decoded once); a remote item falls back to its
/// `RemoteRef.thumbnailURL` via `AsyncImage` — nothing is written to disk
/// for a remote item until Download is tapped, so there's no local file
/// to load yet.
struct ArtworkView: View {
    let playable: Playable
    var cornerRadius: CGFloat = 6

    @EnvironmentObject private var artwork: ArtworkStore

    /// Convenience for the (still very common) case of a known library
    /// item, so call sites that only ever deal in `MediaItem` don't need
    /// to wrap it in `.library(...)` themselves.
    init(item: MediaItem, cornerRadius: CGFloat = 6) {
        self.playable = .library(item)
        self.cornerRadius = cornerRadius
    }

    init(playable: Playable, cornerRadius: CGFloat = 6) {
        self.playable = playable
        self.cornerRadius = cornerRadius
    }

    var body: some View {
        Group {
            switch playable {
            case .library(let item):
                if let image = artwork.image(for: item) {
                    Image(platformImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    placeholder
                }
            case .remote(let ref):
                if let url = ref.thumbnailURL {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image {
                            image.resizable().aspectRatio(contentMode: .fill)
                        } else {
                            placeholder
                        }
                    }
                } else {
                    placeholder
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .task(id: playable.id) {
            if case .library(let item) = playable {
                await artwork.load(for: item)
            }
        }
    }

    private var placeholder: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            Image(systemName: playable.hasVideo && !playable.hasAudio ? "film" : "music.note")
                .foregroundStyle(.secondary)
        }
    }
}
