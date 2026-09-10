import Foundation
import WaveformBackendKit

/// Spotify search credentials and the Genius-assisted-matching toggle —
/// the settings `Search.swift`/`Match.swift` need but don't own
/// themselves. Kept separate from `PlaybackSettingsStore` since that
/// type is specifically playback/download-quality settings; this one
/// is specifically "who am I talking to the network as."
///
/// Genius no longer needs a per-user access token: search (YouTube +
/// YouTube Music) and the official Genius API are both proxied through
/// `waveform-search-backend` now, which holds its own pool of Genius
/// tokens server-side. `useGeniusMatching` is just an on/off switch —
/// there's nothing left here to misconfigure.
///
/// Stored in `UserDefaults` for now, same as every other setting in this
/// app.
@MainActor
final class AcquireSettingsStore: ObservableObject {
    /// When on, `Match.pickVideoSource` tries a Genius-assisted lookup
    /// before falling back to the plain weighted YouTube search — see
    /// `GeniusClient`'s doc comment. On by default: Genius-assisted
    /// matching has no per-user cost or setup anymore, so there's no
    /// reason to default it off the way the old token-gated version did.
    @Published var useGeniusMatching: Bool {
        didSet { UserDefaults.standard.set(useGeniusMatching, forKey: Keys.useGeniusMatching) }
    }

    /// §8: when on, a low-confidence audio/video match (one that never
    /// cleared `Match.qualifies`'s score floor) is held back from the
    /// permanent library rather than silently downloaded — see
    /// `DownloadManager.download(_:kinds:capOverride:forceKinds:)`.
    /// Off by default so existing behavior (always take the top-ranked
    /// candidate) is unchanged until someone opts in.
    @Published var conservativeMatching: Bool {
        didSet { UserDefaults.standard.set(conservativeMatching, forKey: Keys.conservativeMatching) }
    }

    private enum Keys {
        static let useGeniusMatching = "waveform.useGeniusMatching"
        static let conservativeMatching = "waveform.conservativeMatching"
    }

    init() {
        let defaults = UserDefaults.standard
        self.useGeniusMatching = defaults.object(forKey: Keys.useGeniusMatching) as? Bool ?? true
        self.conservativeMatching = defaults.bool(forKey: Keys.conservativeMatching)
    }

    /// `nil` when either half of the credential pair is missing — matches
    /// `Search.pipeline`'s "Spotify search is silently skipped, not
    /// errored" contract for an unconfigured client (§8).
    var spotifyClient: SpotifyClient? {
        return SpotifyClient()
    }

    /// `nil` when the user has turned Genius-assisted matching off —
    /// `Match.pickVideoSource` treats a `nil` `GeniusClient` as "skip
    /// the Genius-assisted lookup, fall straight to weighted search"
    /// rather than erroring.
    var geniusClient: GeniusClient? {
        useGeniusMatching ? GeniusClient() : nil
    }

    var isGeniusEnabled: Bool { useGeniusMatching }
}
