/// WaveformBackendKit
/// ===================
/// The backend for the Waveform media app (spec v3): a unified on-disk
/// library (`LibraryStore`, §6/§7) with source-ID-first dedup (§5),
/// search/match/download/shrink under `Acquire/` (§3/§4), an ordered
/// `PlaybackQueue` typed over `Playable` — a library entry or a
/// not-yet-downloaded remote stream reference (§4) — with shuffle/repeat,
/// and a `MediaPlayerController` that ties queue + engine together on top
/// of an app-supplied `PlaybackEngine` (see that protocol's doc comment
/// for why the concrete engine — VLCKit-backed — lives outside this
/// package).
///
/// Supersedes the old `.cmf`-archive-based `VaultDeckKit`; see the
/// package README for the current end-to-end SwiftUI wiring example.
public enum WaveformBackendKit {
    public static let version = "0.3.0"
}
