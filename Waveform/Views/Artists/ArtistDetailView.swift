import SwiftUI
import WaveformBackendKit

struct ArtistDetailView: View {
    let artist: ArtistGroup

    @EnvironmentObject private var queue: PlaybackQueue
    @EnvironmentObject private var player: MediaPlayerController

    /// Tracks grouped by album, in album-title order, so the artist page
    /// reads like a discography rather than a flat song dump.
    private var albums: [(key: String, items: [MediaItem])] {
        let grouped = Dictionary(grouping: artist.items, by: \.albumGroupKey)
        return grouped
            .map { (key: $0.key, items: $0.value.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }) }
            .sorted { ($0.items.first?.albumName ?? "") < ($1.items.first?.albumName ?? "") }
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    if let first = artist.items.first {
                        ArtworkView(item: first, cornerRadius: 60)
                            .frame(width: 120, height: 120)
                            .clipShape(Circle())
                            .shadow(radius: 6)
                            .accessibilityHidden(true)
                    }
                    Text(artist.name).font(.title3.weight(.semibold))
                    Text("\(artist.items.count) track\(artist.items.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        Button {
                            QueueActions.playNow(artist.items, queue: queue, player: player)
                        } label: {
                            Label("Play", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)

                        Button {
                            QueueActions.playNow(artist.items.shuffled(), queue: queue, player: player)
                        } label: {
                            Label("Shuffle", systemImage: "shuffle")
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
            }
            .listRowBackground(Color.clear)

            ForEach(albums, id: \.key) { group in
                Section(group.items.first?.albumName ?? "Singles") {
                    ForEach(group.items) { item in
                        SongRow(item: item, showArtist: false)
                    }
                }
            }
            .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .navigationTitle(artist.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
