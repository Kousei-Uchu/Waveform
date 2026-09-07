import SwiftUI
import WaveformBackendKit

struct MediaItemCard: View {
    let item: MediaItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ArtworkView(item: item, cornerRadius: 0)
                .aspectRatio(1, contentMode: .fit)
                .accessibilityHidden(true)
            Group {
                Text(item.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(item.author)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
        }
    }
}
