import SwiftUI
import WaveformBackendKit

struct ArtistsView: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var query = ""

    private var filtered: [ArtistGroup] {
        guard !query.isEmpty else { return library.artists }
        let q = query.lowercased()
        return library.artists.filter { $0.name.lowercased().contains(q) }
    }

    var body: some View {
        Group {
            if library.artists.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "music.mic").font(.system(size: 36)).foregroundStyle(.secondary).accessibilityHidden(true)
                    Text("No artists yet").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filtered) { artist in
                    NavigationLink(value: artist) {
                        HStack(spacing: 12) {
                            if let first = artist.items.first {
                                ArtworkView(item: first, cornerRadius: 22)
                                    .frame(width: 44, height: 44)
                                    .clipShape(Circle())
                                    .accessibilityHidden(true)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(artist.name)
                                Text("\(artist.items.count) track\(artist.items.count == 1 ? "" : "s")")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .listRowBackground(Color.clear)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .searchable(text: $query, prompt: "Search artists")
    }
}
