import Foundation
import WaveformBackendKit

/// Spotify client id/secret and an optional Genius token — the
/// credentials `Search.swift`/`Match.swift` need but don't own
/// themselves (§8's Settings additions: "Spotify client id/secret,
/// optional Genius token"). Kept separate from `PlaybackSettingsStore`
/// since that type is specifically playback/download-quality settings;
/// this one is specifically "who am I talking to the network as."
///
/// Stored in `UserDefaults` for now, same as every other setting in this
/// app — a real Keychain-backed store would be a reasonable hardening
/// pass later, but nothing here is more sensitive than an API secret a
/// user pastes in themselves, and this app has no server component to
/// leak it to.
@MainActor
final class AcquireSettingsStore: ObservableObject {
    @Published var geniusToken: String {
        didSet { UserDefaults.standard.set(geniusToken, forKey: Keys.geniusToken) }
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
        static let geniusToken = "waveform.geniusToken"
        static let conservativeMatching = "waveform.conservativeMatching"
    }

    init() {
        let defaults = UserDefaults.standard
        self.geniusToken = defaults.string(forKey: Keys.geniusToken) ?? ""
        self.conservativeMatching = defaults.bool(forKey: Keys.conservativeMatching)
    }

    /// `nil` when either half of the credential pair is missing — matches
    /// `Search.pipeline`'s "Spotify search is silently skipped, not
    /// errored" contract for an unconfigured client (§8).
    var spotifyClient: SpotifyClient? {
        return SpotifyClient()
    }

    /// `nil` when no token is configured — `Match.pickVideoSource` treats
    /// a `nil` `GeniusClient` as "skip the Genius-assisted lookup, fall
    /// straight to weighted search" rather than erroring.
    var geniusClient: GeniusClient? {
        let token = geniusToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return nil }
        return GeniusClient(accessToken: token)
    }

    var isGeniusConfigured: Bool { geniusClient != nil }
}
