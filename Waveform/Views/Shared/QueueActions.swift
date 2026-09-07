import WaveformBackendKit

@MainActor
enum QueueActions {
    /// Replaces the queue with `items` (preferring audio when an item has
    /// both) and starts playing from the first one.
    static func playNow(_ items: [MediaItem], queue: PlaybackQueue, player: MediaPlayerController) {
        let entries = entries(for: items)
        guard !entries.isEmpty else { return }
        queue.clear()
        queue.append(contentsOf: entries)
        queue.jump(to: 0)
        player.play()
    }

    static func appendToQueue(_ items: [MediaItem], queue: PlaybackQueue) {
        queue.append(contentsOf: entries(for: items))
    }

    private static func entries(for items: [MediaItem]) -> [QueueEntry] {
        items.compactMap { item in
            let kind: TrackKind? = item.hasAudio ? .audio : (item.hasVideo ? .video : nil)
            guard let kind else { return nil }
            return QueueEntry(playable: .library(item), kind: kind)
        }
    }
}
