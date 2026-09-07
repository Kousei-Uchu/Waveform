//
//  PlaybackEngine.swift
//  VaultDeckKit
//
//  Created by Aiden McGovern (School) on 1/9/2026.
//


import Foundation

#if os(iOS)
import UIKit
/// The platform view type a `PlaybackEngine` renders video into. This
/// package only ever treats it as an opaque view to embed — see
/// `PlaybackVideoView`.
public typealias PlaybackPlatformView = UIView
#else
import AppKit
public typealias PlaybackPlatformView = NSView
#endif

/// Everything `MediaPlayerController` needs from a media engine, with no
/// assumption about which framework actually renders/decodes.
///
/// `VaultDeckKit` ships no conforming type — the app is expected to supply
/// one (e.g. an `AVPlayer`-backed engine, or a VLCKit-backed one) via the
/// `engineFactory` closure passed to `MediaPlayerController.init`. This is
/// deliberate: VLCKit/MobileVLCKit are CocoaPods, and an SPM package can't
/// depend on a pod directly, so the concrete engine has to live in
/// whichever target actually carries that dependency.
///
/// `MediaPlayerController` keeps two instances alive at once (for
/// crossfading), so an engine only ever needs to manage a single "current
/// item" at a time — no playlist/queue awareness required.
@MainActor
public protocol PlaybackEngine: AnyObject {
    /// Loads a local file or stream URL, replacing whatever was
    /// previously loaded. Does not start playback — call `play()`
    /// separately, mirroring `AVPlayer.replaceCurrentItem` + `play()`.
    ///
    /// `audioSlaveURL`, when non-nil, is an *additional* input the
    /// engine attaches as an audio track alongside `url` — used for a
    /// `.remote` `.video` item resolved to a separate video-only +
    /// audio-only adaptive pair (`Resolve.StreamTarget`) rather than one
    /// pre-muxed progressive stream. `nil` for every other case
    /// (downloaded library items are already single, fully-muxed files;
    /// `.audio` items have nothing to attach).
    func load(url: URL, audioSlaveURL: URL?)

    /// Unloads the current item and stops playback.
    func clear()

    func play()
    func pause()

    /// Linear volume, 0...1. 1.0 is unity gain (matches `AVPlayer.volume`
    /// semantics) — engines that expose a different native range (e.g.
    /// VLCKit's 0...200 percentage) are responsible for converting.
    var volume: Float { get set }

    /// Whether an item is currently loaded (mirrors `AVPlayer.currentItem != nil`).
    var isLoaded: Bool { get }

    var currentTime: TimeInterval { get }

    /// nil when duration isn't known yet (e.g. metadata still parsing).
    var itemDuration: TimeInterval? { get }

    func seek(to time: TimeInterval)

    /// Called by the engine on a steady cadence (~4Hz) while it has an
    /// item loaded, regardless of play/pause state — `MediaPlayerController`
    /// uses this in place of AVFoundation's periodic time observer.
    var onTick: (() -> Void)? { get set }

    /// Called once when the currently loaded item finishes playing through
    /// to the end (not on manual stop/clear).
    var onDidReachEnd: (() -> Void)? { get set }

    /// A view this engine renders video into. For audio-only items this
    /// view simply won't have anything drawn into it — callers only embed
    /// it when `currentKind == .video`. Engines should return the *same*
    /// view instance across calls (SwiftUI's `PlaybackVideoView` re-parents
    /// it rather than recreating it when the active engine changes).
    var videoRenderView: PlaybackPlatformView { get }
}
