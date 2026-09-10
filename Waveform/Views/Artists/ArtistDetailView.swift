import SwiftUI
import WaveformBackendKit

struct ArtistDetailView: View {
    let artist: ArtistGroup

    @EnvironmentObject private var queue: PlaybackQueue
    @EnvironmentObject private var player: MediaPlayerController

    /// Tracks grouped by album, in album-title order, so the artist page
    /// reads like a discography rather than a flat song dump.
    ///
    /// Every track *without* real album info (`albumName == nil` —
    /// non-Spotify sources, or a Spotify response that somehow came back
    /// without one) shares `albumGroupKey`'s per-track fallback key
    /// (`author::title`), which is unique per track by construction —
    /// grouping straight off that key would give every such track its
    /// own one-song section, all labeled "Singles" identically (the
    /// visual "two different Singles sections" bug this fixes). Those are
    /// pulled out and merged into one real "Singles" section instead;
    /// every track that *does* have a real album name keeps its own
    /// distinct, correctly-labeled section as before.
    private var albums: [(key: String, title: String, items: [MediaItem])] {
        let grouped = Dictionary(grouping: artist.items, by: \.albumGroupKey)
        var named: [(key: String, title: String, items: [MediaItem])] = []
        var singles: [MediaItem] = []

        for (key, items) in grouped {
            let sorted = items.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            if let albumName = sorted.first?.albumName, !albumName.isEmpty {
                named.append((key: key, title: albumName, items: sorted))
            } else {
                singles.append(contentsOf: sorted)
            }
        }

        named.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        if !singles.isEmpty {
            let sortedSingles = singles.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            named.append((key: "singles", title: "Singles", items: sortedSingles))
        }
        return named
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
                Section(group.title) {
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
