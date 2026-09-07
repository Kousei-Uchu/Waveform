import SwiftUI
import WaveformBackendKit

struct NowPlayingView: View {
    @EnvironmentObject private var queue: PlaybackQueue
    @EnvironmentObject private var player: MediaPlayerController
    @EnvironmentObject private var artwork: ArtworkStore
    @EnvironmentObject private var palette: PaletteStore
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var playbackSettings: PlaybackSettingsStore
    @Environment(\.dismiss) private var dismiss

    @State private var isScrubbing = false
    @State private var scrubTime: TimeInterval = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                if let entry = queue.current {
                    mediaSurface(for: entry)
                        .frame(maxWidth: 320, maxHeight: 320)
                        .shadow(radius: 12)
                        .padding(.top, 20)
                        .task(id: entry.playable.id) {
                            guard let item = entry.playable.libraryItem else { return }
                            await artwork.load(for: item)
                            if let image = artwork.image(for: item) {
                                palette.load(itemID: entry.playable.id, image: image)
                            }
                        }

                    VStack(spacing: 6) {
                        Text(entry.playable.title)
                            .font(.title2.weight(.semibold))
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .foregroundStyle(secondaryAccentColor(for: entry))
                        Text(entry.playable.author)
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }

                    // Streaming-vs-downloaded distinction + a Download
                    // action reachable from a currently-streaming track
                    // (§8).
                    if let ref = entry.playable.remoteRef {
                        downloadRow(for: ref)
                    }

                    VStack(spacing: 6) {
                        Slider(
                            value: Binding(
                                get: { isScrubbing ? scrubTime : player.currentTime },
                                set: { scrubTime = $0 }
                            ),
                            in: 0...max(player.duration, 1),
                            onEditingChanged: { editing in
                                isScrubbing = editing
                                if !editing {
                                    player.seek(to: scrubTime)
                                }
                            }
                        )
                        .accessibilityLabel("Playback position")
                        .accessibilityValue(TimeFormatting.string(from: isScrubbing ? scrubTime : player.currentTime))
                        HStack {
                            Text(TimeFormatting.string(from: isScrubbing ? scrubTime : player.currentTime))
                            Spacer()
                            Text(TimeFormatting.string(from: player.duration))
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    }
                    .padding(.horizontal)

                    HStack(spacing: 36) {
                        Button {
                            queue.toggleShuffle()
                        } label: {
                            Image(systemName: "shuffle")
                                .foregroundStyle(queue.isShuffled ? secondaryAccentColor(for: entry) : Color.secondary)
                        }
                        .accessibilityLabel("Shuffle")
                        .accessibilityValue(queue.isShuffled ? "On" : "Off")

                        Button {
                            player.skipToPrevious()
                        } label: {
                            Image(systemName: "backward.fill").font(.title2)
                        }
                        .accessibilityLabel("Previous")

                        Button {
                            player.togglePlayPause()
                        } label: {
                            Image(systemName: player.status == .playing ? "pause.circle.fill" : "play.circle.fill")
                                .font(.system(size: 56))
                        }
                        .accessibilityLabel(player.status == .playing ? "Pause" : "Play")

                        Button {
                            player.skipToNext()
                        } label: {
                            Image(systemName: "forward.fill").font(.title2)
                        }
                        .accessibilityLabel("Next")

                        Button {
                            cycleRepeatMode()
                        } label: {
                            Image(systemName: repeatIcon)
                                .foregroundStyle(queue.repeatMode == .off ? Color.secondary : secondaryAccentColor(for: entry))
                        }
                        .accessibilityLabel("Repeat")
                        .accessibilityValue(repeatAccessibilityValue)
                    }
                    .buttonStyle(.plain)
                    .tint(secondaryAccentColor(for: entry))

                    if case .failed(let message) = player.status {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }

                    Spacer()
                } else {
                    Spacer()
                    Text("Nothing playing").foregroundStyle(.secondary)
                    Spacer()
                }
            }
            .padding()
            .background(
                Rectangle()
                    .liquidGlassIfAvailable(in: Rectangle(), tinted: true)
                    .ignoresSafeArea()
            )
            #if os(iOS)
            .containerBackground(.clear, for: .navigation)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .tint(queue.current.map(secondaryAccentColor))
    }

    /// Artwork for audio, a live video surface for video — both bound to
    /// the same `MediaPlayerController`, so play/pause/seek controls below
    /// work identically either way.
    @ViewBuilder
    private func mediaSurface(for entry: QueueEntry) -> some View {
        if entry.kind == .video, player.currentKind == .video {
            PlaybackVideoView(contentView: player.videoRenderView)
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 16))
        } else {
            ArtworkView(playable: entry.playable, cornerRadius: 16)
                // Decorative here — the title/author below already say what
                // this is, so VoiceOver shouldn't announce it separately.
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func downloadRow(for ref: RemoteRef) -> some View {
        switch downloads.state(for: ref) {
        case .idle:
            Button {
                Task { await downloads.download(ref, kinds: ref.availableKinds, capOverride: playbackSettings.downloadResolutionCap) }
            } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.bordered)
        case .downloading(let progress):
            HStack(spacing: 6) {
                if let fraction = progress?.fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView()
                }
                Text("Downloading…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 160)
        case .done:
            Label("Downloaded", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .failed(let message):
            VStack(spacing: 4) {
                Button {
                    Task { await downloads.download(ref, kinds: ref.availableKinds, capOverride: playbackSettings.downloadResolutionCap) }
                } label: {
                    Label("Retry Download", systemImage: "exclamationmark.arrow.circlepath")
                }
                .buttonStyle(.bordered)
                Text(message).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func accentColor(for entry: QueueEntry) -> Color {
        palette.color(for: entry.playable.id) ?? .stableAccent
    }

    /// The contrast-safe text/tint counterpart to `accentColor(for:)` —
    /// drawn from `PaletteStore`'s secondary swatch selection, which is
    /// scored specifically for standing apart from the primary color
    /// rather than for being independently interesting. Falls back to a
    /// synthesized complement of the primary if the palette hasn't
    /// resolved a secondary (e.g. still loading, or every other swatch got
    /// filtered out for this image).
    private func secondaryAccentColor(for entry: QueueEntry) -> Color {
        palette.currentSecondaryTint ?? .stableAccent
    }

    private var backgroundGradient: some View {
        let base = queue.current.map(accentColor) ?? Color.clear
        return LinearGradient(
            colors: [base.opacity(0.25), Color.clear],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }

    private var repeatIcon: String {
        switch queue.repeatMode {
        case .off, .all: "repeat"
        case .one: "repeat.1"
        }
    }

    private var repeatAccessibilityValue: String {
        switch queue.repeatMode {
        case .off: "Off"
        case .all: "All"
        case .one: "One"
        }
    }

    private func cycleRepeatMode() {
        switch queue.repeatMode {
        case .off: queue.repeatMode = .all
        case .all: queue.repeatMode = .one
        case .one: queue.repeatMode = .off
        }
    }
}
