//
//  NowPlayingWidgetSync.swift
//  Waveform
//
//  Created by Aiden McGovern (School) on 10/9/2026.
//


import Foundation
import Combine
import WaveformBackendKit

#if os(iOS)
import UIKit
#endif

/// Mirrors `MediaPlayerController`/`PlaybackQueue`/`PaletteStore` state
/// into the shared App Group as a `NowPlayingSnapshot`, so
/// `WaveformWidgets`' `NowPlayingWidget` (Home Screen + Lock Screen) can
/// show it — and handles the reverse direction too: on iOS, it's the
/// `NowPlayingIntentHandling` conformer that
/// `NowPlayingIntentBridge.handler` points at, so a tap on one of the
/// widget's `Button(intent:)` transport controls (§ "AppIntent buttons
/// for interactive features") ends up calling straight into the real,
/// currently-running `MediaPlayerController`.
///
/// Lives in the app layer (not `WaveformBackendKit`) for the same reason
/// `LiveActivityManager` does: this is platform/widget-extension
/// integration, not media-library backend logic, and (like that type)
/// only actually does anything on iOS — `WaveformWidgets` is an iOS-only
/// extension target, so there's nothing to sync on macOS. Structured the
/// same way as `LiveActivityManager` throughout (unconditional outer
/// shell, `#if os(iOS)`-gated internals) so `WaveformApp.swift` can
/// construct and use both identically regardless of platform. The
/// `NowPlayingIntentHandling` conformance itself is a separate,
/// iOS-only `extension` below, since that protocol (defined in
/// `WaveformShared/NowPlayingIntents.swift`) doesn't exist in the
/// `Waveform-macOS` build at all.
@MainActor
final class NowPlayingWidgetSync: ObservableObject {
    #if os(iOS)
    private var player: MediaPlayerController?
    private var artwork: ArtworkStore?
    private weak var palette: PaletteStore?
    private var cancellables: Set<AnyCancellable> = []
    #endif

    init() {}

    /// Call once at launch. Reacts to track changes and play/pause
    /// immediately; elapsed-time-only ticking never triggers a sync at
    /// all — a playing track's on-widget elapsed time instead advances on
    /// its own via `NowPlayingSnapshot.timerRange` (a live `ProgressView`,
    /// no reload needed), so there's no reason to write+reload every
    /// second the way a naive "mirror `currentTime`" approach would.
    func start(player: MediaPlayerController, queue: PlaybackQueue, artwork: ArtworkStore, palette: PaletteStore) {
        #if os(iOS)
        self.player = player
        self.artwork = artwork
        self.palette = palette
        NowPlayingIntentBridge.handler = self

        let trackOrStatusChange = queue.$currentIndex
            .combineLatest(player.$status)
            .map { _ in () }

        // Palette extraction for a newly-loaded track finishes
        // asynchronously (`PaletteStore.load` kicks off a `Task`), so a
        // sync triggered by the track change above often runs *before*
        // the new colours exist yet — this also fires once they land,
        // via `palette`'s own `objectWillChange` (its per-item colour
        // caches are `@Published` but private, so this is the only way
        // to observe "colours changed" from outside the type).
        let paletteChange = palette.objectWillChange

        trackOrStatusChange.merge(with: paletteChange)
            .sink { [weak self] in
                guard let self else { return }
                Task { await self.sync() }
            }
            .store(in: &cancellables)

        Task { await sync() }
        #endif
    }

    #if os(iOS)
    fileprivate func sync() async {
        guard let player, let artwork, let palette else {
            NowPlayingStore.write(nil)
            return
        }
        guard let entry = player.queue.current else {
            NowPlayingStore.write(nil)
            return
        }

        let artworkFilename = await writeSharedArtworkIfNeeded(for: entry.playable, artwork: artwork, palette: palette)

        let snapshot = NowPlayingSnapshot(
            itemID: entry.playable.id,
            title: entry.playable.title,
            author: entry.playable.author,
            isPlaying: player.status == .playing,
            elapsedSeconds: player.currentTime,
            durationSeconds: player.duration,
            artworkFilename: artworkFilename,
            primaryColorHex: palette.color(for: entry.playable.id).map { Self.hexString(from: UIColor($0)) },
            secondaryColorHex: palette.secondaryColor(for: entry.playable.id).map { Self.hexString(from: UIColor($0)) }
        )
        NowPlayingStore.write(snapshot)
    }

    /// Writes the current track's cover art into the shared App Group
    /// container, reusing the exact filename/convention
    /// `LiveActivityManager.writeSharedArtworkIfNeeded` already
    /// established (a Live Activity and this widget are, in the common
    /// case where both are active, showing the same artwork for the same
    /// track — no reason to write it twice under two different names).
    /// Also kicks off `PaletteStore.load` for the artwork, same as
    /// `WaveformApp.loadTintIfNeeded` does, so a track that's never had
    /// Now Playing opened still gets its widget colours computed.
    private func writeSharedArtworkIfNeeded(for playable: Playable, artwork: ArtworkStore, palette: PaletteStore) async -> String? {
        guard let item = playable.libraryItem else { return nil }
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppGroup.identifier
        ) else {
            return nil
        }

        await artwork.load(for: item)
        guard let image = artwork.image(for: item) else { return nil }
        palette.load(itemID: playable.id, image: image)

        guard let data = image.jpegData(compressionQuality: 0.7) else { return nil }

        let filename = "now-playing-artwork.jpg"
        do {
            try data.write(to: containerURL.appendingPathComponent(filename), options: .atomic)
            return filename
        } catch {
            return nil
        }
    }

    private static func hexString(from color: UIColor) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(
            format: "#%02X%02X%02X",
            Int((r * 255).rounded()),
            Int((g * 255).rounded()),
            Int((b * 255).rounded())
        )
    }
    #endif
}

#if os(iOS)
extension NowPlayingWidgetSync: NowPlayingIntentHandling {
    func togglePlayPause() async {
        player?.togglePlayPause()
        await sync()
    }

    func skipToNext() async {
        player?.skipToNext()
        await sync()
    }

    func skipToPrevious() async {
        player?.skipToPrevious()
        await sync()
    }
}
#endif