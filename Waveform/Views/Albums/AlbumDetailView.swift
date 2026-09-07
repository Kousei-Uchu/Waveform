import SwiftUI
import WaveformBackendKit

struct AlbumDetailView: View {
    let album: AlbumGroup

    @EnvironmentObject private var queue: PlaybackQueue
    @EnvironmentObject private var player: MediaPlayerController

    var body: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    if let first = album.items.first {
                        ArtworkView(item: first, cornerRadius: 10)
                            .frame(width: 180, height: 180)
                            .shadow(radius: 6)
                            .accessibilityHidden(true)
                    }
                    VStack(spacing: 2) {
                        Text(album.title).font(.title3.weight(.semibold)).multilineTextAlignment(.center)
                        Text(album.author).font(.subheadline).foregroundStyle(.secondary)
                        Text("\(album.items.count) track\(album.items.count == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 12) {
                        Button {
                            QueueActions.playNow(album.items, queue: queue, player: player)
                        } label: {
                            Label("Play", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)

                        Button {
                            QueueActions.playNow(album.items.shuffled(), queue: queue, player: player)
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

            Section {
                ForEach(album.items) { item in
                    SongRow(item: item, showArtist: false)
                }
            }
            .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .navigationTitle(album.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
