//
//  NowPlayingSnapshot.swift
//  Waveform
//
//  Created by Aiden McGovern (School) on 10/9/2026.
//


#if os(iOS)
import Foundation

/// The cross-process snapshot of "what's currently playing," written by
/// the main app (`NowPlayingWidgetSync`) into the shared App Group
/// container and read back by `WaveformWidgets`' `NowPlayingWidget`
/// timeline provider.
///
/// Deliberately doesn't carry raw artwork bytes — same reasoning as
/// `PlaybackActivityAttributes.ContentState`: this is written far more
/// often than a Live Activity update (any time the palette, track, or
/// play state changes) and the widget extension already has its own way
/// to read the shared artwork file directly (`artworkFilename` +
/// `AppGroup`), so there's no reason to duplicate image bytes in here.
///
/// iOS-only (`WaveformWidgets`, the only reader, is an iOS-only
/// extension target — see that target's `SDKROOT` — so this stays out of
/// the `Waveform-macOS` build entirely, matching how `AppGroup.swift`/
/// `PlaybackActivityAttributes.swift` are already scoped).
public struct NowPlayingSnapshot: Codable, Equatable, Sendable {
    public var itemID: String
    public var title: String
    public var author: String
    public var albumName: String?
    public var isPlaying: Bool
    public var elapsedSeconds: Double
    public var durationSeconds: Double
    /// Filename inside the App Group container — same convention
    /// `LiveActivityManager.writeSharedArtworkIfNeeded` already uses, and
    /// in fact usually the exact same file, since both are "the current
    /// track's cover art" written to the same shared location.
    public var artworkFilename: String?
    /// Hex strings (`"#RRGGBB"`), precomputed by `PaletteStore` on the
    /// app side — the widget extension never runs its own palette
    /// extraction (no `PaletteKit` dependency there, and no reason to
    /// redo work the app already did against the same artwork).
    public var primaryColorHex: String?
    public var secondaryColorHex: String?
    /// When this snapshot was written — used to keep a *playing* track's
    /// displayed elapsed time advancing between infrequent widget
    /// reloads, via `timerRange` below, rather than freezing at whatever
    /// value happened to be true the moment the widget last redrew.
    public var updatedAt: Date

    public init(
        itemID: String,
        title: String,
        author: String,
        albumName: String? = nil,
        isPlaying: Bool,
        elapsedSeconds: Double,
        durationSeconds: Double,
        artworkFilename: String? = nil,
        primaryColorHex: String? = nil,
        secondaryColorHex: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.itemID = itemID
        self.title = title
        self.author = author
        self.albumName = albumName
        self.isPlaying = isPlaying
        self.elapsedSeconds = elapsedSeconds
        self.durationSeconds = durationSeconds
        self.artworkFilename = artworkFilename
        self.primaryColorHex = primaryColorHex
        self.secondaryColorHex = secondaryColorHex
        self.updatedAt = updatedAt
    }

    /// 0...1, clamped — same convention as
    /// `PlaybackActivityAttributes.ContentState.progress`. Used for a
    /// paused track's (static) progress bar.
    public var progress: Double {
        guard durationSeconds > 0 else { return 0 }
        return min(max(elapsedSeconds / durationSeconds, 0), 1)
    }

    /// The `start...end` range a live-ticking widget element can hand
    /// straight to `ProgressView(timerInterval:countsDown:)` or
    /// `Text(_:style: .timer)` so the elapsed/remaining time keeps
    /// advancing on-screen between widget reloads — WidgetKit renders
    /// those two views' progress live, without asking the timeline
    /// provider for a new entry every second. `nil` for a paused track
    /// (nothing to animate; the static `progress` above is exact and
    /// correct as-is) or a track with no known duration.
    public var timerRange: ClosedRange<Date>? {
        guard isPlaying, durationSeconds > 0 else { return nil }
        let start = updatedAt.addingTimeInterval(-elapsedSeconds)
        let end = start.addingTimeInterval(durationSeconds)
        guard start < end else { return nil }
        return start...end
    }
}
#endif