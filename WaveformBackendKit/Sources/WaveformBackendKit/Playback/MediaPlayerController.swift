import Foundation
import Combine
import MediaPlayer

#if os(iOS)
import AVFoundation // AVAudioSession only — audio routing, unrelated to which PlaybackEngine renders media.
import UIKit
#else
import AppKit
#endif

public enum PlaybackStatus: Equatable, Sendable {
    case idle
    case loading
    case playing
    case paused
    case ended
    case failed(String)
}

/// Wraps two `PlaybackEngine`s (only one "active" at a time), watches a
/// `PlaybackQueue` for track changes, and resolves whatever URL the engine
/// actually needs to load — a local file for a `.library` entry, or a
/// freshly-resolved stream URL for a `.remote` one (§4).
///
/// Two engines instead of one so crossfading between tracks (ramping one
/// engine's volume down while ramping the other up) doesn't require
/// juggling a single engine's item mid-playback. `videoRenderView` always
/// points at whichever one is currently "active" — SwiftUI can hand it
/// straight to `PlaybackVideoView(contentView:)` for video entries.
///
/// Crossfading is only ever attempted between two *local* audio tracks —
/// a remote entry up next skips straight to a plain load (see
/// `maybeBeginCrossfade`), since pre-resolving its stream URL early enough
/// to cross-fade into would risk the URL going stale before it's used.
///
/// This package doesn't ship a `PlaybackEngine` implementation itself —
/// the caller supplies one (or two, via `engineFactory`) at construction
/// time. See `PlaybackEngine`'s doc comment for why (in short: VLCKit /
/// MobileVLCKit are CocoaPods, which this SPM package can't depend on
/// directly, so the concrete engine lives in the app target instead).
@MainActor
public final class MediaPlayerController: NSObject, ObservableObject {
    @Published public private(set) var status: PlaybackStatus = .idle
    @Published public private(set) var currentTime: TimeInterval = 0
    @Published public private(set) var duration: TimeInterval = 0
    @Published public private(set) var currentKind: TrackKind?

    /// Read-only from the outside — use the transport methods below to
    /// control playback. Exposed so a view can embed it via
    /// `PlaybackVideoView` for video entries; it will point at a different
    /// underlying engine's view after a crossfade swap, which SwiftUI
    /// picks up naturally on the next render since it's read fresh
    /// alongside this object's other `@Published` properties.
    public var videoRenderView: PlaybackPlatformView { activePlayer.videoRenderView }

    public let queue: PlaybackQueue
    public let settings: PlaybackSettingsStore

    private let resolveStreamURL: (RemoteRef, TrackKind) async throws -> Resolve.StreamTarget

    private let playerA: PlaybackEngine
    private let playerB: PlaybackEngine
    private var activeIsA = true
    private var activePlayer: PlaybackEngine { activeIsA ? playerA : playerB }
    private var standbyPlayer: PlaybackEngine { activeIsA ? playerB : playerA }

    private var queueSink: AnyCancellable?
    private var currentEntryID: UUID?
    private var suppressNextQueueLoad = false

    private var crossfadeState: CrossfadeState?
    private var preparedNextEntryID: UUID?
    private var normalizationGains: [String: Float] = [:] // Playable.id -> gain

    private struct CrossfadeState {
        let nextEntry: QueueEntry
        let incomingPlayer: PlaybackEngine
        let outgoingPlayer: PlaybackEngine
        let startTime: TimeInterval
        let crossfadeLength: TimeInterval
        let incomingGain: Float
    }

    /// - Parameters:
    ///   - resolveStreamURL: Resolves a playable stream target for a
    ///     `.remote` entry, called *just before* it's actually needed
    ///     (queue reaches it, or it's tapped directly) — never earlier,
    ///     since resolved stream URLs expire (§4). The app supplies this
    ///     (backed by `Resolve.streamTarget(for:kind:)`) rather than this
    ///     type calling `Resolve` directly, keeping `MediaPlayerController`
    ///     agnostic about *how* a remote URL is resolved. The target's
    ///     `audioSlaveURL` (non-nil for a `.video` item resolved to a
    ///     separate video-only + audio-only adaptive pair) is passed
    ///     straight through to `PlaybackEngine.load(url:audioSlaveURL:)`.
    ///   - engineFactory: Called twice (once per internal player slot) to
    ///     construct the engines this controller drives. Each call must
    ///     return a fresh, independent engine instance.
    public init(
        queue: PlaybackQueue,
        settings: PlaybackSettingsStore,
        resolveStreamURL: @escaping (RemoteRef, TrackKind) async throws -> Resolve.StreamTarget,
        engineFactory: () -> PlaybackEngine
    ) {
        self.queue = queue
        self.settings = settings
        self.resolveStreamURL = resolveStreamURL
        self.playerA = engineFactory()
        self.playerB = engineFactory()
        super.init()
        configureEngine(playerA)
        configureEngine(playerB)
        configureAudioSession()
        configureRemoteCommands()
        queueSink = queue.$currentIndex
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.handleQueueChange()
            }
    }

    deinit {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.removeTarget(nil)
        center.nextTrackCommand.removeTarget(nil)
        center.previousTrackCommand.removeTarget(nil)
        center.changePlaybackPositionCommand.removeTarget(nil)
    }

    // MARK: - Transport

    public func play() {
        guard activePlayer.isLoaded else { return }
        activePlayer.play()
        status = .playing
        updateNowPlayingPlaybackState()
    }

    public func pause() {
        activePlayer.pause()
        standbyPlayer.pause()
        status = .paused
        updateNowPlayingPlaybackState()
    }

    public func togglePlayPause() {
        if status == .playing { pause() } else { play() }
    }

    public func seek(to time: TimeInterval) {
        activePlayer.seek(to: time)
        currentTime = time
        updateNowPlayingPlaybackState()
    }

    public func skipToNext() {
        cancelCrossfade()
        _ = queue.advance()
    }

    /// Restarts the current track if more than a few seconds in (the usual
    /// "previous button" convention), otherwise steps back in the queue.
    public func skipToPrevious(restartThreshold: TimeInterval = 3) {
        cancelCrossfade()
        if currentTime > restartThreshold {
            seek(to: 0)
        } else {
            _ = queue.rewind()
        }
    }

    // MARK: - Engine wiring / crossfade driver

    /// Wires an engine's callbacks once at construction — unlike the old
    /// per-`AVPlayerItem` observer, these fire for the lifetime of the
    /// engine regardless of what's currently loaded into it, so identity
    /// checks below compare against the *engine* rather than the item.
    private func configureEngine(_ engine: PlaybackEngine) {
        engine.onTick = { [weak self] in self?.tick() }
        engine.onDidReachEnd = { [weak self, weak engine] in
            guard let self, let engine else { return }
            self.handleDidReachEnd(from: engine)
        }
    }

    private func handleDidReachEnd(from engine: PlaybackEngine) {
        // Ignore a stale end-of-item notification from an engine a
        // crossfade has already moved past.
        guard activePlayer === engine else { return }
        status = .ended
        skipToNext()
    }

    private func tick() {
        currentTime = activePlayer.currentTime
        if let itemDuration = activePlayer.itemDuration, itemDuration > 0 {
            duration = itemDuration
        }
        updateNowPlayingPlaybackState()

        if let state = crossfadeState {
            updateCrossfade(state)
        } else {
            maybeBeginCrossfade()
        }
    }

    private func maybeBeginCrossfade() {
        guard settings.crossfadeDuration > 0, currentKind == .audio else { return }
        guard duration > 0 else { return }
        let remaining = duration - currentTime
        guard remaining <= settings.crossfadeDuration, remaining > 0 else { return }
        guard let nextEntry = queue.peekNext(), nextEntry.kind == .audio else { return }
        // Only cross-fade into tracks already on disk — resolving a
        // remote URL this early would risk it expiring before playback
        // actually reaches it (§4). A remote track up next just gets a
        // plain (non-crossfaded) load when its turn comes.
        guard nextEntry.playable.isDownloaded else { return }
        guard preparedNextEntryID != nextEntry.id else { return }
        preparedNextEntryID = nextEntry.id

        Task { [weak self] in
            await self?.prepareCrossfade(to: nextEntry, remaining: remaining)
        }
    }

    private func prepareCrossfade(to nextEntry: QueueEntry, remaining: TimeInterval) async {
        guard let item = nextEntry.playable.libraryItem,
              let fileURL = item.fileURL(for: nextEntry.kind) else {
            preparedNextEntryID = nil
            return
        }

        let gain = await resolvedGain(for: nextEntry.playable, kind: nextEntry.kind, fileURL: fileURL)

        guard preparedNextEntryID == nextEntry.id else {
            preparedNextEntryID = nil
            return
        }

        let incoming = standbyPlayer
        // Always a local library file (guarded above), never an audio
        // slave pairing.
        incoming.load(url: fileURL, audioSlaveURL: nil)
        incoming.volume = 0
        incoming.play()

        crossfadeState = CrossfadeState(
            nextEntry: nextEntry,
            incomingPlayer: incoming,
            outgoingPlayer: activePlayer,
            startTime: currentTime,
            crossfadeLength: min(remaining, settings.crossfadeDuration),
            incomingGain: gain
        )
    }

    private func updateCrossfade(_ state: CrossfadeState) {
        let elapsed = state.outgoingPlayer.currentTime - state.startTime
        let progress = state.crossfadeLength > 0 ? min(max(elapsed / state.crossfadeLength, 0), 1) : 1
        state.outgoingPlayer.volume = Float(1 - progress)
        state.incomingPlayer.volume = state.incomingGain * Float(progress)

        if progress >= 1 {
            finishCrossfade(state)
        }
    }

    private func finishCrossfade(_ state: CrossfadeState) {
        state.outgoingPlayer.pause()
        state.outgoingPlayer.volume = 1
        preparedNextEntryID = nil
        crossfadeState = nil

        // Re-validate against the queue's *current* state rather than
        // assuming nothing changed during the fade — the user could have
        // reordered, removed, or cleared items in those few seconds.
        if let index = queue.entries.firstIndex(where: { $0.id == state.nextEntry.id }) {
            activeIsA.toggle()
            currentEntryID = state.nextEntry.id
            currentKind = state.nextEntry.kind
            currentTime = 0
            duration = 0
            // The track we crossfaded into is already playing on what's
            // now the active player — jump the queue to match it directly
            // (rather than `advance()`, which re-derives a position from
            // shuffle/repeat state that may have changed mid-fade) without
            // triggering a redundant fresh load.
            suppressNextQueueLoad = true
            queue.jump(to: index)
            Task { await updateNowPlayingMetadata(for: state.nextEntry) }
        } else {
            // The track we crossfaded into was removed from the queue
            // during the fade. Abandon it and fall back to a normal load
            // of whatever the queue says is current now (or nothing).
            state.incomingPlayer.pause()
            state.incomingPlayer.clear()
            currentEntryID = nil
            currentKind = nil
            Task { await loadCurrent() }
        }
    }

    private func cancelCrossfade() {
        if let state = crossfadeState {
            state.incomingPlayer.pause()
            state.incomingPlayer.clear()
            state.outgoingPlayer.volume = 1
        }
        crossfadeState = nil
        preparedNextEntryID = nil
    }

    // MARK: - Loading

    private func handleQueueChange() {
        if suppressNextQueueLoad {
            suppressNextQueueLoad = false
            return
        }
        cancelCrossfade()
        Task { await loadCurrent() }
    }

    private func loadCurrent() async {
        guard let entry = queue.current else {
            activePlayer.clear()
            currentEntryID = nil
            currentKind = nil
            status = .idle
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        guard entry.id != currentEntryID else { return }
        currentEntryID = entry.id
        currentKind = entry.kind
        status = .loading

        do {
            let target = try await resolvedTarget(for: entry)
            guard entry.id == currentEntryID else { return } // queue moved on while resolving

            let gain = await resolvedGain(for: entry.playable, kind: entry.kind, fileURL: target.url)
            guard entry.id == currentEntryID else { return }

            activePlayer.load(url: target.url, audioSlaveURL: target.audioSlaveURL)
            activePlayer.volume = gain
            currentTime = 0
            duration = 0
            play()
            await updateNowPlayingMetadata(for: entry)
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    /// Local file URL for a `.library` entry (never has an audio slave —
    /// a downloaded item is always one already-muxed file, per
    /// `Resolve.DownloadPlan`/`Mux`), or a just-resolved stream target
    /// for a `.remote` one — resolved here, right before load, rather
    /// than any earlier point, since remote URLs expire (§4).
    private func resolvedTarget(for entry: QueueEntry) async throws -> Resolve.StreamTarget {
        switch entry.playable {
        case .library(let item):
            guard let url = item.fileURL(for: entry.kind) else {
                throw PlaybackLoadError.missingTrack(kind: entry.kind, title: item.title)
            }
            return Resolve.StreamTarget(url: url)
        case .remote(let ref):
            return try await resolveStreamURL(ref, entry.kind)
        }
    }

    private func resolvedGain(for playable: Playable, kind: TrackKind, fileURL: URL) async -> Float {
        guard settings.normalizeVolume, kind == .audio, playable.isDownloaded else { return 1.0 }
        if let cached = normalizationGains[playable.id] { return cached }
        let gain = await LoudnessAnalyzer.measureAttenuationGain(for: fileURL)
        normalizationGains[playable.id] = gain
        return gain
    }

    // MARK: - Lock screen / Control Center

    private func configureAudioSession() {
        #if os(iOS)
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            // Non-fatal — playback still works in-app, it just won't
            // survive backgrounding/silent-switch as gracefully.
        }
        #endif
    }

    /// Registers with the system's lock-screen/Control Center/media-key
    /// command surface. Handlers hop to the main actor and return
    /// `.success` immediately rather than waiting for the hop to complete —
    /// `MPRemoteCommandHandler` requires a synchronous result, and the UI
    /// will reflect the change within a tick regardless.
    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in self.play() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in self.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in self.togglePlayPause() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in self.skipToNext() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in self.skipToPrevious() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self, let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            Task { @MainActor in self.seek(to: event.positionTime) }
            return .success
        }
    }

    /// Updates elapsed time and playback rate only — cheap enough to call
    /// on every tick. Track identity/artwork are set separately by
    /// `updateNowPlayingMetadata`, which only needs to run once per track.
    private func updateNowPlayingPlaybackState() {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = status == .playing ? 1.0 : 0.0
        if duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func updateNowPlayingMetadata(for entry: QueueEntry) async {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: entry.playable.title,
            MPMediaItemPropertyArtist: entry.playable.author,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: status == .playing ? 1.0 : 0.0,
        ]
        if let albumName = entry.playable.albumName {
            info[MPMediaItemPropertyAlbumTitle] = albumName
        }
        if duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        guard let item = entry.playable.libraryItem, let artworkURL = item.artworkFileURL else { return }

        let data = try? await Task.detached(priority: .utility) {
            try Data(contentsOf: artworkURL)
        }.value
        guard let data, let image = PlatformImage(data: data) else { return }
        guard entry.id == currentEntryID else { return } // track changed while decoding

        let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        var updated = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        updated[MPMediaItemPropertyArtwork] = artwork
        MPNowPlayingInfoCenter.default().nowPlayingInfo = updated
    }
}

public enum PlaybackLoadError: Error, LocalizedError, Sendable {
    case missingTrack(kind: TrackKind, title: String)

    public var errorDescription: String? {
        switch self {
        case .missingTrack(let kind, let title):
            "No \(kind.rawValue) track found for \"\(title)\"."
        }
    }
}

#if os(macOS)
private typealias PlatformImage = NSImage
#else
private typealias PlatformImage = UIImage
#endif
