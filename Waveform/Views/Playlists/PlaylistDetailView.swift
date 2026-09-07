import SwiftUI
import WaveformBackendKit

struct PlaylistDetailView: View {
    let playlist: Playlist

    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var playlists: PlaylistStore
    @EnvironmentObject private var queue: PlaybackQueue
    @EnvironmentObject private var player: MediaPlayerController

    /// Re-reads the live playlist from the store each time, so edits
    /// (rename, reorder, remove) made elsewhere are reflected immediately.
    private var current: Playlist {
        playlists.playlists.first { $0.id == playlist.id } ?? playlist
    }

    private var items: [MediaItem] {
        playlists.items(in: current, library: library)
    }

    var body: some View {
        Group {
            if items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "music.note.list").font(.system(size: 36)).foregroundStyle(.secondary).accessibilityHidden(true)
                    Text("No tracks yet").foregroundStyle(.secondary)
                    Text("Add songs from Library using \"Add to Playlist\".")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
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
                            SongRow(item: item, onRemove: {
                                playlists.removeItem(item.id, from: current)
                            })
                        }
                        .onMove { from, to in
                            playlists.moveItems(in: current, fromOffsets: from, toOffset: to)
                        }
                    }
                    .listRowBackground(Color.clear)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                #if os(iOS)
                .toolbar { EditButton() }
                #endif
            }
        }
        .navigationTitle(current.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
