import SwiftUI
import WaveformBackendKit

struct PlayerBar: View {
    @EnvironmentObject private var queue: PlaybackQueue
    @EnvironmentObject private var player: MediaPlayerController
    @Binding var showNowPlaying: Bool

    var body: some View {
        if let entry = queue.current {
            HStack(spacing: 12) {
                Button {
                    showNowPlaying = true
                } label: {
                    HStack(spacing: 12) {
                        ArtworkView(playable: entry.playable, cornerRadius: 4)
                            .frame(width: 40, height: 40)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 4) {
                                Text(entry.playable.title).font(.subheadline).lineLimit(1)
                                // Streaming-vs-downloaded distinction (§8) —
                                // a small glyph is enough here; the full
                                // Download action lives on Now Playing.
                                if !entry.playable.isDownloaded {
                                    Image(systemName: "antenna.radiowaves.left.and.right")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .accessibilityHidden(true)
                                }
                            }
                            Text(entry.playable.author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Now playing: \(entry.playable.title) by \(entry.playable.author)")
                .accessibilityHint("Opens Now Playing")
                .accessibilityAddTraits(.isButton)

                Spacer()

                Button {
                    player.skipToPrevious()
                } label: {
                    Image(systemName: "backward.fill")
                }
                .accessibilityLabel("Previous")

                Button {
                    player.togglePlayPause()
                } label: {
                    Image(systemName: player.status == .playing ? "pause.fill" : "play.fill")
                        .font(.title3)
                }
                .accessibilityLabel(player.status == .playing ? "Pause" : "Play")

                Button {
                    player.skipToNext()
                } label: {
                    Image(systemName: "forward.fill")
                }
                .accessibilityLabel("Next")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Rectangle()
                    .liquidGlassIfAvailable(in: Rectangle(), tinted: true)
                    .ignoresSafeArea(edges: .bottom)
            )
        }
    }
}
