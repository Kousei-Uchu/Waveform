import SwiftUI
import WaveformBackendKit

struct AlbumsView: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var query = ""

    private let columns = [GridItem(.adaptive(minimum: 140), spacing: 16)]

    private var filtered: [AlbumGroup] {
        guard !query.isEmpty else { return library.albums }
        let q = query.lowercased()
        return library.albums.filter { $0.title.lowercased().contains(q) || $0.author.lowercased().contains(q) }
    }

    var body: some View {
        Group {
            if library.albums.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "square.stack").font(.system(size: 36)).foregroundStyle(.secondary).accessibilityHidden(true)
                    Text("No albums yet").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(filtered) { album in
                            NavigationLink(value: album) {
                                VStack(alignment: .leading, spacing: 6) {
                                    AlbumArtwork(album: album)
                                        .aspectRatio(1, contentMode: .fit)
                                    Group {
                                        Text(album.title).font(.subheadline.weight(.medium)).lineLimit(1)
                                        Text(album.author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
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
                        }
                    }
                    .padding()
                }
            }
        }
        .searchable(text: $query, prompt: "Search albums or artists")
    }
}

/// Uses the first track's own artwork to represent the album.
private struct AlbumArtwork: View {
    let album: AlbumGroup

    var body: some View {
        if let first = album.items.first {
            ArtworkView(item: first, cornerRadius: 0)
                .accessibilityHidden(true)
        } else {
            RoundedRectangle(cornerRadius: 0).fill(.quaternary)
        }
    }
}
