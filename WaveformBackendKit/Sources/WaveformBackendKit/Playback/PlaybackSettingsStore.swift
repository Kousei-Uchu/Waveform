import Foundation

/// A resolution ceiling applied when picking which stream variant to
/// download (§4) — a selection filter over what YouTube offers, not a
/// transcode. `.uncapped` always takes the best available variant.
public enum DownloadResolutionCap: Int, Codable, Sendable, CaseIterable, Identifiable {
    case p480 = 480
    case p720 = 720
    case p1080 = 1080
    case uncapped = 0

    public var id: Int { rawValue }

    public var label: String {
        switch self {
        case .uncapped: "No cap"
        default: "\(rawValue)p"
        }
    }
}

/// User-facing playback + download/encode settings. Owned separately from
/// `MediaPlayerController` so a settings screen can bind to it directly
/// without needing the whole player.
@MainActor
public final class PlaybackSettingsStore: ObservableObject {
    @Published public var normalizeVolume: Bool {
        didSet { UserDefaults.standard.set(normalizeVolume, forKey: Keys.normalize) }
    }

    /// Seconds of overlap between tracks. `0` disables crossfading.
    @Published public var crossfadeDuration: TimeInterval {
        didSet { UserDefaults.standard.set(crossfadeDuration, forKey: Keys.crossfade) }
    }

    /// Default resolution ceiling applied when resolving a variant to
    /// download (§4) — overridable per-download from the Search & Download
    /// screen. Downloads themselves are always stream-copied (§3); this
    /// only narrows which source stream gets picked, it never transcodes.
    @Published public var downloadResolutionCap: DownloadResolutionCap {
        didSet { UserDefaults.standard.set(downloadResolutionCap.rawValue, forKey: Keys.resolutionCap) }
    }

    // MARK: - Shrink (§3) — only consulted when the user explicitly taps
    // Shrink on a library item; never on the download hot path.

    @Published public var shrinkAV1CRF: Int {
        didSet { UserDefaults.standard.set(shrinkAV1CRF, forKey: Keys.av1CRF) }
    }
    @Published public var shrinkAV1Preset: Int {
        didSet { UserDefaults.standard.set(shrinkAV1Preset, forKey: Keys.av1Preset) }
    }
    @Published public var shrinkOpusBitrateKbps: Int {
        didSet { UserDefaults.standard.set(shrinkOpusBitrateKbps, forKey: Keys.opusBitrate) }
    }

    private enum Keys {
        static let normalize = "waveformbackendkit.normalizeVolume"
        static let crossfade = "waveformbackendkit.crossfadeDuration"
        static let resolutionCap = "waveformbackendkit.downloadResolutionCap"
        static let av1CRF = "waveformbackendkit.shrinkAV1CRF"
        static let av1Preset = "waveformbackendkit.shrinkAV1Preset"
        static let opusBitrate = "waveformbackendkit.shrinkOpusBitrateKbps"
    }

    public init(userDefaults: UserDefaults = .standard) {
        self.normalizeVolume = userDefaults.bool(forKey: Keys.normalize)
        self.crossfadeDuration = (userDefaults.object(forKey: Keys.crossfade) as? TimeInterval) ?? 0
        let storedCap = userDefaults.object(forKey: Keys.resolutionCap) as? Int
        self.downloadResolutionCap = storedCap.flatMap(DownloadResolutionCap.init(rawValue:)) ?? .p1080
        self.shrinkAV1CRF = (userDefaults.object(forKey: Keys.av1CRF) as? Int) ?? 32
        self.shrinkAV1Preset = (userDefaults.object(forKey: Keys.av1Preset) as? Int) ?? 8
        self.shrinkOpusBitrateKbps = (userDefaults.object(forKey: Keys.opusBitrate) as? Int) ?? 128
    }
}
