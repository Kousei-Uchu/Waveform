import SwiftUI
import WaveformBackendKit

@main
struct WaveformApp: App {
    @StateObject private var vaultStore: VaultStore
    @StateObject private var library: LibraryStore
    @StateObject private var queue: PlaybackQueue
    @StateObject private var player: MediaPlayerController
    @StateObject private var settings: PlaybackSettingsStore
    @StateObject private var playlists = PlaylistStore()
    @StateObject private var artwork = ArtworkStore()
    @ObservedObject private var palette = PaletteStore.shared
    @StateObject private var liveActivity = LiveActivityManager()
    @StateObject private var nowPlayingWidgetSync = NowPlayingWidgetSync()
    @StateObject private var router = DeepLinkRouter()
    @StateObject private var downloadManager: DownloadManager
    @ObservedObject private var accessibility = AccessibilitySettingsStore.shared
    // Spotify search client + the Genius-assisted-matching toggle (§8's
    // Settings additions) — `Search.pipeline`/`Match.pickVideoSource`
    // read these via `AcquireSettingsStore.spotifyClient`/`.geniusClient`,
    // both of which are already written to silently no-op when off, so
    // this can exist app-wide from first launch with no setup needed.
    // Explicitly constructed in `init()` (rather than left as a default
    // property initializer) because `DownloadManager` now needs it too,
    // for its own Genius-assisted video re-matching on download.
    @StateObject private var acquireSettings: AcquireSettingsStore

    init() {
        // `VaultStore` only picks the folder URL now; `LibraryStore` owns
        // everything under it (§6/§8) — there's no more `MediaLibrary`
        // scanning a folder full of individually-imported `.cmf` files,
        // so this is the one place the library folder gets opened.
        // Points every search/Genius call in WaveformBackendKit at the
        // deployed waveform-search-backend instance — set this to your
        // real Vercel deployment URL. YouTubeKit's stream resolution
        // (Resolve.swift) never uses this; it stays entirely on-device.
        BackendConfig.baseURL = URL(string: "https://waveform-search-backend.vercel.app")!
        let vaultStore = VaultStore()
        let library = LibraryStore(rootURL: vaultStore.libraryRootURL)
        let queue = PlaybackQueue()
        let settings = PlaybackSettingsStore()
        let player = MediaPlayerController(
            queue: queue,
            settings: settings,
            // Resolved fresh, right before playback needs it — never
            // cached — since YouTube's stream URLs expire (§4).
            resolveStreamURL: { ref, kind in try await Resolve.streamTarget(for: ref, kind: kind) },
            engineFactory: { VLCPlaybackEngine() }
        )
        let acquireSettings = AcquireSettingsStore()
        _vaultStore = StateObject(wrappedValue: vaultStore)
        _library = StateObject(wrappedValue: library)
        _queue = StateObject(wrappedValue: queue)
        _settings = StateObject(wrappedValue: settings)
        _player = StateObject(wrappedValue: player)
        _acquireSettings = StateObject(wrappedValue: acquireSettings)
        _downloadManager = StateObject(wrappedValue: DownloadManager(library: library, settings: settings, queue: queue, acquireSettings: acquireSettings))
#if os(iOS)
    // Make UIKit-backed scrolling containers transparent.
    UITableView.appearance().backgroundColor = .clear
    UITableViewCell.appearance().backgroundColor = .clear
    UICollectionView.appearance().backgroundColor = .clear

    // Navigation bars
    let navigationAppearance = UINavigationBarAppearance()
    navigationAppearance.configureWithTransparentBackground()
    navigationAppearance.backgroundColor = .clear
    navigationAppearance.shadowColor = .clear

    UINavigationBar.appearance().standardAppearance = navigationAppearance
    UINavigationBar.appearance().scrollEdgeAppearance = navigationAppearance
    UINavigationBar.appearance().compactAppearance = navigationAppearance

    // Tab bar
    let tabAppearance = UITabBarAppearance()
    tabAppearance.configureWithTransparentBackground()
    tabAppearance.backgroundColor = .clear
    tabAppearance.shadowColor = .clear

    UITabBar.appearance().standardAppearance = tabAppearance
    UITabBar.appearance().scrollEdgeAppearance = tabAppearance
    #endif
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                RootView()
                    .environmentObject(library)
                    .environmentObject(queue)
                    .environmentObject(player)
                    .environmentObject(settings)
                    .environmentObject(playlists)
                    .environmentObject(vaultStore)
                    .environmentObject(artwork)
                    .environmentObject(palette)
                    .environmentObject(router)
                    .environmentObject(downloadManager)
                    .environmentObject(acquireSettings)
                    .environmentObject(accessibility)
                    .task {
                        library.load()
                    }
                    .onAppear {
                        liveActivity.start(player: player, queue: queue, artwork: artwork)
                        nowPlayingWidgetSync.start(player: player, queue: queue, artwork: artwork, palette: palette)
                        palette.currentItemID = queue.current?.playable.id
                        loadTintIfNeeded(for: queue.current)
                    }
                    .onOpenURL { url in
                        router.handle(url)
                    }
                    .onChange(of: queue.current?.id) { _ in
                        palette.currentItemID = queue.current?.playable.id
                        loadTintIfNeeded(for: queue.current)
                    }
                    .tint(palette.currentSecondaryTint ?? .stableSecondary)
                    .animation(.easeInOut(duration: 1), value: palette.currentTint)
                    .background(Color.clear)
                    .accentColor(.stableAccent)
            }
        }
    }

    /// Fetches artwork and kicks off palette extraction for `entry`,
    /// independent of whether NowPlayingView (or anything else) happens to
    /// be on screen. Previously this only ran inside NowPlayingView's own
    /// `.task(id:)`, so a track's tint never got computed unless the user
    /// opened Now Playing at least once while it was current.
    private func loadTintIfNeeded(for entry: QueueEntry?) {
        guard let entry, let item = entry.playable.libraryItem else { return }
        Task {
            await artwork.load(for: item)
            if let image = artwork.image(for: item) {
                palette.load(itemID: entry.playable.id, image: image)
            }
        }
    }
}

struct BackgroundView<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @ObservedObject private var palette = PaletteStore.shared
    

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [palette.currentTint ?? .stableAccent, (palette.currentTint ?? .stableAccent).analogous()],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 1), value: palette.currentTint)

            content()
        }
    }
}

extension Color {

    /// An analogous color — adjacent on the color wheel — for harmony rather
    /// than contrast. If `offset` is nil, it's calculated from the color's
    /// own saturation/brightness so muted colors shift further (to stay
    /// visually distinct) and vivid colors shift less (to stay in-family).
    func analogous(offset: Double? = nil) -> Color {
        let (hue, saturation, brightness, alpha) = hsbaComponents()

        if saturation < 0.08 {
            let nudged = brightness > 0.5 ? brightness - 0.12 : brightness + 0.12
            return Color(hue: hue, saturation: saturation, brightness: min(max(nudged, 0.05), 0.95), opacity: alpha)
        }

        let resolvedOffset = offset ?? intelligentAnalogousOffset(saturation: saturation, brightness: brightness)
        let hueShift = resolvedOffset / 360.0
        var newHue = hue + hueShift
        if newHue < 0 { newHue += 1.0 }
        newHue = newHue.truncatingRemainder(dividingBy: 1.0)

        return Color(hue: newHue, saturation: saturation, brightness: brightness, opacity: alpha)
    }

    /// Bigger shift for muted/very light/very dark colors (where a small hue
    /// change is barely perceptible), smaller shift for vivid mid-brightness
    /// colors (where a small change is already clearly a different hue).
    private func intelligentAnalogousOffset(saturation: Double, brightness: Double) -> Double {
        // 0 = fully vivid & unclamped, 1 = fully muted/washed out
        let mutedness = 1.0 - saturation

        // Distance of brightness from a "mid" 0.5 — extremes (near-black,
        // near-white) also compress perceived hue difference.
        let brightnessExtremity = abs(brightness - 0.5) * 2.0 // 0...1

        // Weighted blend: saturation matters most, brightness a bit less.
        let compression = min(max(mutedness * 0.7 + brightnessExtremity * 0.3, 0), 1)

        // Map compression (0...1) to a 20°...55° range.
        let minOffset = 20.0
        let maxOffset = 55.0
        return minOffset + compression * (maxOffset - minOffset)
    }

    // MARK: - Shared helper

    private func hsbaComponents() -> (hue: Double, saturation: Double, brightness: Double, alpha: Double) {
        #if canImport(UIKit)
        let native = UIColor(self)
        #elseif canImport(AppKit)
        let native = NSColor(self).usingColorSpace(.deviceRGB) ?? NSColor(self)
        #endif

        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        native.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

        return (Double(hue), Double(saturation), Double(brightness), Double(alpha))
    }
}

extension Color {
    /// Same asset as AccentColor, but resolved by explicit name rather than
    /// the symbolic `.accentColor`, so it doesn't depend on window/trait
    /// timing when converted to UIColor for HSB math.
    static let stableAccent = Color("AccentColor")

    /// Companion to `stableAccent` — the fixed system-theme fallback for
    /// `currentSecondaryTint`, same role `stableAccent` plays for
    /// `currentTint`. Backed by a `SecondaryAccentColor` asset you need to
    /// add to the catalog (see `SecondaryAccentColor.colorset/Contents.json`)
    /// — pick light/dark values that pair well with `AccentColor`'s.
    static let stableSecondary = Color("SecondaryAccentColor")
}
