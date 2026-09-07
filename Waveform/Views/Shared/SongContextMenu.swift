import SwiftUI
import WaveformBackendKit

/// Shared context-menu content for a single item: play/queue actions,
/// like toggle, add-to-playlist, and an optional "remove" action for
/// contexts like a playlist's own item list.
struct SongContextMenu: View {
    let item: MediaItem
    var onRemove: (() -> Void)?

    @EnvironmentObject private var queue: PlaybackQueue
    @EnvironmentObject private var player: MediaPlayerController

    var body: some View {
        if item.hasAudio {
            Button("Play Audio") { playNow(.audio) }
            Button("Add Audio to Queue") { queue.append(QueueEntry(playable: .library(item), kind: .audio)) }
        }
        if item.hasVideo {
            Button("Play Video") { playNow(.video) }
            Button("Add Video to Queue") { queue.append(QueueEntry(playable: .library(item), kind: .video)) }
        }
        LikeButton(item: item)
        Menu("Add to Playlist") {
            AddToPlaylistMenuItems(item: item)
        }
        if let onRemove {
            Divider()
            Button("Remove from Playlist", role: .destructive, action: onRemove)
        }
    }

    private func playNow(_ kind: TrackKind) {
        queue.append(QueueEntry(playable: .library(item), kind: kind))
        queue.jump(to: queue.entries.count - 1)
        player.play()
    }
}
