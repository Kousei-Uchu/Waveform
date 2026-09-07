import SwiftUI
import WaveformBackendKit

struct PlaylistsView2: View {
    @EnvironmentObject private var playlists: PlaylistStore
    @State private var renamingPlaylist: Playlist?
    @State private var renameText = ""

    var body: some View {
        List {
            

            Section("Your Playlists") {
                if playlists.playlists.isEmpty {
                    Text("No playlists yet").foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                }
                ForEach(playlists.playlists) { playlist in
                    NavigationLink(value: playlist) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(playlist.name)
                            Text("\(playlist.itemIDs.count) track\(playlist.itemIDs.count == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
#if os(iOS)
.containerBackground(.clear, for: .navigation)
#endif
                    }
                    .listRowBackground(Color.clear)
                }
            }

        }
        .listStyle(.plain)
        
    }

    
}

/// A trivial `Hashable` marker type so "Liked Songs" can use the same
/// `navigationDestination`-based push as everything else, without giving
/// it a real `MediaItem`/`Playlist` identity it doesn't have.
struct LikedSongsDestination: Hashable {}


import SwiftUI
import WaveformBackendKit

struct PlaylistsView: View {
    @EnvironmentObject private var playlists: PlaylistStore
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var palette: PaletteStore
    @State private var renamingPlaylist: Playlist?
    @State private var renameText = ""
    @State private var query = ""

    private let columns = [GridItem(.adaptive(minimum: 140), spacing: 16)]
    
    private var filtered: [Playlist] {
        guard !query.isEmpty else { return playlists.playlists }
        let q = query.lowercased()
        return playlists.playlists.filter { $0.name.lowercased().contains(q) }
    }

    var body: some View {
        Group {
            Button {
                _ = playlists.createPlaylist(name: nextDefaultName())
            } label: {
                Label("New Playlist", systemImage: "plus")
                    .font(.body.weight(.semibold)) // Helps visibility against lensed backgrounds
                    .foregroundStyle(.primary)
                    .padding(.vertical, 14)       // Gives breathing room inside the 3D bubble
                    .frame(maxWidth: .infinity)
                    // 1. Apply the glass effect directly to the content layer for native depth mapping
                    .liquidGlassIfAvailable(in: .capsule, isInteractive: true)
            }
            .buttonStyle(.plain) // Prevents standard list button highlights from interfering
            // 2. Add padding to separate the capsule from row edges, triggering edge aberration
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            // 3. Keep the underlying system row perfectly empty
            .listRowBackground(Color.clear)
            
            if playlists.playlists.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "square.stack").font(.system(size: 36)).foregroundStyle(.secondary).accessibilityHidden(true)
                    Text("No playlists yet").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        NavigationLink(value: LikedSongsDestination()) {
                            VStack(alignment: .leading, spacing: 6) {
                                ZStack {
                                    Rectangle().fill(.pink.gradient)
                                    Image(systemName: "heart.fill").foregroundStyle(.white)
                                }
                                .aspectRatio(1, contentMode: .fill)
                                .accessibilityHidden(true)
                                Group {
                                    Text("Liked Songs").font(.subheadline.weight(.medium)).lineLimit(1)
                                    Text("\(playlists.likedItemIDs.count) track\(playlists.likedItemIDs.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                .padding(.horizontal, 10)
                            }
                        }
                        .listRowBackground(Color.clear)
                        .buttonStyle(.plain)
                        //.padding(.horizontal, 10)
                        //.padding(.vertical, 10)
                        .padding(.bottom, 10)
                        .clipShape(RoundedRectangle(cornerRadius: 9))
                        .padding(1)
                        .liquidGlassIfAvailable(in: .rect(cornerRadius: 10), isInteractive: true, tinted: true)
                        
                        ForEach(filtered) { playlist in
                            NavigationLink(value: playlist) {
                                VStack(alignment: .leading, spacing: 6) {
                                    PlaylistCompositeArtwork(playlist: playlist, library: library, palette: palette)
                                        .accessibilityHidden(true)
                                        .aspectRatio(1, contentMode: .fill)
                                    Group {
                                        Text(playlist.name).font(.subheadline.weight(.medium)).lineLimit(1)
                                        Text("\(playlist.itemIDs.count) track\(playlist.itemIDs.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    .padding(.horizontal, 10)
                                }
                            }
                            .contextMenu {
                                Button("Rename…") {
                                    renamingPlaylist = playlist
                                    renameText = playlist.name
                                }
                                Button("Delete", role: .destructive) {
                                    playlists.delete(playlist)
                                }
                            }
                            .listRowBackground(Color.clear)
                            .buttonStyle(.plain)
                            //.padding(.horizontal, 10)
                            //.padding(.vertical, 10)
                            .padding(.bottom, 10)
                            .clipShape(RoundedRectangle(cornerRadius: 9))
                            .padding(1)
                            .liquidGlassIfAvailable(in: .rect(cornerRadius: 10), isInteractive: true, tinted: true)
                        }
                    }
                    .padding()
                }
                .scrollContentBackground(.hidden)
                .navigationDestination(for: LikedSongsDestination.self) { _ in
                    LikedSongsView()
                        .scrollContentBackground(.hidden)
                        .background(
                            Rectangle()
                                .liquidGlassIfAvailable(in: Rectangle(), tinted: true)
                                .ignoresSafeArea()
                        )
                }
                .alert("Rename Playlist", isPresented: Binding(
                    get: { renamingPlaylist != nil },
                    set: { if !$0 { renamingPlaylist = nil } }
                )) {
                    TextField("Name", text: $renameText)
                    Button("Cancel", role: .cancel) { renamingPlaylist = nil }
                    Button("Save") {
                        if let playlist = renamingPlaylist {
                            let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmed.isEmpty { playlists.rename(playlist, to: trimmed) }
                        }
                        renamingPlaylist = nil
                    }
                }
            }
        }
        .searchable(text: $query, prompt: "Search playlists")
    }
    
    private func nextDefaultName() -> String {
        let existing = Set(playlists.playlists.map(\.name))
        guard existing.contains("New Playlist") else { return "New Playlist" }
        var n = 2
        while existing.contains("New Playlist \(n)") { n += 1 }
        return "New Playlist \(n)"
    }
}

private struct PlaylistCompositeArtwork: View {
    let playlist: Playlist
    let library: LibraryStore
    let palette: PaletteStore
    
    let columns: [GridItem] = [
            GridItem(.flexible(), spacing: 0),
            GridItem(.flexible(), spacing: 0)
        ]
    
    var body: some View {
        LazyVGrid(columns: columns, spacing: 0) {
            ForEach(0..<4) { index in
                PlaylistMediaArtwork(playlist: playlist, library: library, palette: palette, index: index)
            }
        }
    }
}


/// Uses the first track's own artwork to represent the album.
private struct PlaylistMediaArtwork: View {
    let playlist: Playlist?
    let library: LibraryStore
    let palette: PaletteStore
    let index: Int
    
    var body: some View {
        if let item = getPlaylistItem(index: index, for: playlist, library: library) {
            ArtworkView(item: item, cornerRadius: 0)
                .aspectRatio(1, contentMode: .fill)
                .clipped()
                .accessibilityHidden(true)
        } else {
            ZStack {
                Rectangle().fill(Color.randomShade(of: palette.currentTint ?? .stableAccent))
                Image(systemName: "music.note")
                    .foregroundStyle(.secondary)
            }
            .aspectRatio(1, contentMode: .fill)
        }
    }
    
    func getPlaylistItem(index: Int, for playlist: Playlist?, library: LibraryStore) -> MediaItem? {
        guard let itemIDs = playlist?.itemIDs, itemIDs.indices.contains(index) else { return nil }
        return library.item(withID: itemIDs[index])
    }
}
