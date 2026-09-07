import SwiftUI
import WaveformBackendKit

struct SongsView: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var query = ""

    private let columns = [GridItem(.adaptive(minimum: 140), spacing: 16)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(library.items(matching: query)) { item in
                    NavigationLink(value: item) {
                        MediaItemCard(item: item)
                    }
                    .listRowBackground(Color.clear)
                    .buttonStyle(.plain)
                    .contextMenu { SongContextMenu(item: item) }
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
        .searchable(text: $query, prompt: "Search title or author")
        .background(.clear)
    }
}
