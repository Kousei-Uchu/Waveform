import SwiftUI
import WaveformBackendKit

enum LibrarySection: String, CaseIterable, Identifiable {
    case songs = "Songs"
    case albums = "Albums"
    case artists = "Artists"
    case playlists = "Playlists"
    var id: String { rawValue }
}

/// The Library tab's container: owns the one `NavigationStack` (and every
/// `navigationDestination` type it can push) shared by all four sections.
///
/// Unlike the old `.cmf`-era version, there's no folder/file import flow
/// here anymore (§8 — "everything arrives through Acquire") — content
/// only ever enters the library via the Search & Download screen's
/// Download action. `LibraryStore` just reflects whatever's already on
/// disk under the managed vault folder.
struct LibraryView: View {
    @EnvironmentObject private var library: LibraryStore

    @State private var section: LibrarySection = .playlists
    @State private var dismissedError: String?

    var body: some View {
        NavigationStack {
            Group {
                if library.items.isEmpty && !library.isLoading {
                    EmptyLibraryView()
                } else {
                    VStack(spacing: 0) {
                        Picker("Section", selection: $section) {
                            ForEach(LibrarySection.allCases) { section in
                                Text(section.rawValue).tag(section)
                            }
                        }
                        .pickerStyle(.segmented)
                        .padding([.horizontal, .top])

                        sectionContent
                    }
                }
            }
            .navigationTitle("Library")
            .navigationDestination(for: MediaItem.self) {
                ItemDetailView(item: $0)
                    .scrollContentBackground(.hidden)
                    .background(
                        Rectangle()
                            .liquidGlassIfAvailable(in: Rectangle(), tinted: true)
                            .ignoresSafeArea()
                    )
            }
            .navigationDestination(for: AlbumGroup.self) {
                AlbumDetailView(album: $0)
                    .scrollContentBackground(.hidden)
                    .background(
                        Rectangle()
                            .liquidGlassIfAvailable(in: Rectangle(), tinted: true)
                            .ignoresSafeArea()
                    )
            }
            .navigationDestination(for: ArtistGroup.self) {
                ArtistDetailView(artist: $0)
                    .scrollContentBackground(.hidden)
                    .background(
                        Rectangle()
                            .liquidGlassIfAvailable(in: Rectangle(), tinted: true)
                            .ignoresSafeArea()
                    )
            }
            .navigationDestination(for: Playlist.self) {
                PlaylistDetailView(playlist: $0)
                    .scrollContentBackground(.hidden)
                    .background(
                        Rectangle()
                            .liquidGlassIfAvailable(in: Rectangle(), tinted: true)
                            .ignoresSafeArea()
                    )
            }
            .overlay {
                if library.isLoading {
                    ProgressView("Loading…")
                        .padding()
                        .liquidGlassIfAvailable(in: RoundedRectangle(cornerRadius: 10), tinted: true)
                }
            }
            .alert(
                "Library error",
                isPresented: Binding(
                    get: { library.lastError != nil && library.lastError != dismissedError },
                    set: { presented in if !presented { dismissedError = library.lastError } }
                )
            ) {
                Button("OK") { dismissedError = library.lastError }
            } message: {
                Text(library.lastError ?? "")
            }
            .background(.clear)
#if os(iOS)
.containerBackground(.clear, for: .navigation)
#endif
        }
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch section {
        case .songs: SongsView()
        case .albums: AlbumsView()
        case .artists: ArtistsView()
        case .playlists: PlaylistsView()
        }
    }
}
