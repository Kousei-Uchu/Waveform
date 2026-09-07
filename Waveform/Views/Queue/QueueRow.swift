import SwiftUI
import WaveformBackendKit

struct QueueRow: View {
    let entry: QueueEntry
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(playable: entry.playable, cornerRadius: 4)
                .frame(width: 44, height: 44)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.playable.title)
                    .lineLimit(1)
                    .fontWeight(isCurrent ? .semibold : .regular)
                Text(entry.playable.author)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            
            Spacer()
            
            // Streaming-vs-downloaded distinction (§8) — a not-yet-local
            // entry gets a small radio-waves glyph alongside the usual
            // audio/video kind icon.
            if !entry.playable.isDownloaded {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .accessibilityHidden(true)
            }
            
            Image(systemName: entry.kind == .audio ? "waveform" : "film")
                .foregroundStyle(.secondary)
                .font(.caption)
            
            if isCurrent {
                Image(systemName: "speaker.wave.2.fill")
                    .foregroundStyle(.tint)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(entry.playable.title) by \(entry.playable.author), " +
            "\(entry.kind == .audio ? "audio" : "video")" +
            (entry.playable.isDownloaded ? "" : ", streaming")
        )
        .accessibilityValue(isCurrent ? "Currently playing" : "")
        .accessibilityAddTraits(.isButton)
        .liquidGlassIfAvailable(in: .rect(cornerRadius: 8), isInteractive: true, tinted: true)
    }
}
