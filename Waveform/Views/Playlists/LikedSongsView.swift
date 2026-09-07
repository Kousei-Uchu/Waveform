import SwiftUI
import WaveformBackendKit

struct LikedSongsView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var playlists: PlaylistStore
    @EnvironmentObject private var queue: PlaybackQueue
    @EnvironmentObject private var player: MediaPlayerController

    private var items: [MediaItem] {
        playlists.likedItems(library: library)
    }

    var body: some View {
        Group {
            if items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "heart").font(.system(size: 36)).foregroundStyle(.secondary).accessibilityHidden(true)
                    Text("No liked songs yet").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    Section {
                        HStack(spacing: 12) {
                            Button {
                                QueueActions.playNow(items, queue: queue, player: player)
                            } label: {
                                Label("Play", systemImage: "play.fill")
                            }
                            .buttonStyle(.borderedProminent)

                            Button {
                                QueueActions.playNow(items.shuffled(), queue: queue, player: player)
                            } label: {
                                Label("Shuffle", systemImage: "shuffle")
                            }
                            .buttonStyle(.bordered)
                        }
                        .frame(maxWidth: .infinity)
                        .listRowSeparator(.hidden)
                    }
                    .listRowBackground(Color.clear)

                    Section {
                        ForEach(items) { item in
                            SongRow(item: item)
                        }
                    }
                    .listRowBackground(Color.clear)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle("Liked Songs")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
