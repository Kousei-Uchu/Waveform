import SwiftUI
import WaveformBackendKit

struct SongRow: View {
    let item: MediaItem
    var showArtist: Bool = true
    var onRemove: (() -> Void)?

    @EnvironmentObject private var queue: PlaybackQueue
    @EnvironmentObject private var player: MediaPlayerController

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(item: item, cornerRadius: 4)
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).lineLimit(1)
                if showArtist {
                    Text(item.author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if item.hasVideo {
                Image(systemName: "film").font(.caption).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            QueueActions.playNow([item], queue: queue, player: player)
        }
        .contextMenu { SongContextMenu(item: item, onRemove: onRemove) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(showArtist ? "\(item.title) by \(item.author)" : item.title)
        .accessibilityHint("Double tap to play")
        .accessibilityAddTraits(.isButton)
    }
}
