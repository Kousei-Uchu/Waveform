import SwiftUI
import WaveformBackendKit

enum SidebarSection: String, CaseIterable, Identifiable, Hashable {
    case library = "Library"
    case search = "Search"
    case queue = "Queue"
    case settings = "Settings"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .library: "music.note.list"
        case .search: "magnifyingglass"
        case .queue: "list.bullet"
        case .settings: "gearshape"
        }
    }
}

/// Adaptive shell: a `NavigationSplitView` sidebar on iPad (regular width)
/// and macOS, falling back to the original `TabView` on iPhone/compact
/// width. Each section (`LibraryView`, `QueueView`, `SettingsView`) still
/// owns its own internal `NavigationStack` either way — the split view's
/// detail column just hosts whichever one is selected, which is the
/// standard pattern for a per-section push stack inside a split layout.
struct RootView: View {
    @EnvironmentObject private var queue: PlaybackQueue
    @EnvironmentObject private var router: DeepLinkRouter
    @EnvironmentObject private var palette: PaletteStore
    @State private var showNowPlaying = false
    @State private var selectedSection: SidebarSection? = .library

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    var body: some View {
        Group {
            VStack{
#if os(iOS)
                if horizontalSizeClass == .compact {
                    compactBody
                } else {
                    splitBody
                }
#else
                splitBody
#endif
                if queue.current != nil {
                    PlayerBar(showNowPlaying: $showNowPlaying)
                }
            }
        }
        .sheet(isPresented: $showNowPlaying) {
            NowPlayingView()
                .presentationBackground(.clear)
        }
        // Tapping the Dynamic Island / Live Activity opens straight to
        // Now Playing — see DeepLinkRouter and the widget's `.widgetURL`.
        .onChange(of: router.openNowPlayingRequestID) { _ in
            showNowPlaying = true
        }
        .background(.clear)
    }

    private var compactBody: some View {
        TabView {
            BackgroundView() {
                LibraryView()
            }
                .tabItem { Label("Library", systemImage: "music.note.list") }

            BackgroundView() {
                SearchDownloadView()
            }
                .tabItem { Label("Search", systemImage: "magnifyingglass") }

            BackgroundView() {
                QueueView()
            }
                .tabItem { Label("Queue", systemImage: "list.bullet") }

            BackgroundView() {
                SettingsView()
            }
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .background(.clear)
        .scrollContentBackground(.hidden)
    }

    private var splitBody: some View {
        NavigationSplitView {
            List(selection: $selectedSection) {
                ForEach(SidebarSection.allCases) { section in
                    Label(section.rawValue, systemImage: section.icon)
                        .tag(section)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .navigationTitle("Waveform")
        } detail: {
            switch selectedSection ?? .library {
            case .library: LibraryView()
            case .search: SearchDownloadView()
            case .queue: QueueView()
            case .settings: SettingsView()
            }
        }
        .background(.clear)
    }
}
