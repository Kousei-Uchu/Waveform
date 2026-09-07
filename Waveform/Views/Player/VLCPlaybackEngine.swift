//
//  VLCPlaybackEngine.swift
//  Waveform
//
//  Created by Aiden McGovern (School) on 1/9/2026.
//


import Foundation
import WaveformBackendKit

#if os(iOS)
import MobileVLCKit
import UIKit
#else
import VLCKit
import AppKit
#endif

/// `PlaybackEngine` backed by VLCKit / MobileVLCKit.
///
/// This is deliberately the *only* file in the app that imports
/// VLCKit/MobileVLCKit directly. `WaveformBackendKit` only knows about
/// the `PlaybackEngine` protocol — it has no idea VLC exists — which is
/// what lets it stay a plain SPM package while this app target (which does
/// carry the VLCKit/MobileVLCKit CocoaPods dependency, per the Podfile)
/// supplies the real implementation at construction time.
///
/// One important semantic gap vs. the old `AVPlayer`-backed engine:
/// AVFoundation exposes item duration synchronously as soon as an item is
/// loaded (or close to it), but VLCKit's `media.length` only becomes
/// accurate once VLC has parsed the file's metadata, which can lag a
/// beat behind `load(url:)` returning. `MediaPlayerController` already
/// tolerates `itemDuration == nil` (it just waits for a later `onTick` to
/// pick up a real value), so no changes were needed there — but if you see
/// the scrubber's max briefly read as unset right after a track starts,
/// this is why.
final class VLCPlaybackEngine: NSObject, PlaybackEngine {
    private let mediaPlayer = VLCMediaPlayer()
    private var tickTimer: Timer?

    var onTick: (() -> Void)?
    var onDidReachEnd: (() -> Void)?

    let videoRenderView: PlaybackPlatformView = {
        let view = PlaybackPlatformView()
        #if os(iOS)
        view.backgroundColor = .black
        #else
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        #endif
        return view
    }()

    override init() {
        super.init()
        mediaPlayer.drawable = videoRenderView
        mediaPlayer.delegate = self
        // VLCKit doesn't offer a periodic-time-observer API like
        // AVFoundation's, so this timer stands in for it — same ~4Hz
        // cadence `MediaPlayerController` used with AVPlayer, driving both
        // the scrubber and the crossfade progress calculation.
        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.onTick?()
        }
    }

    deinit {
        tickTimer?.invalidate()
        mediaPlayer.stop()
    }

    /// `audioSlaveURL`, when present, is attached via VLCKit's
    /// `addPlaybackSlave(_:type:enforce:)` — the documented,
    /// non-deprecated way to add an extra input (audio or subtitles) to
    /// an existing item so it plays back in sync with the primary one,
    /// with no local muxing involved. This is what lets a `.remote`
    /// `.video` item resolved to a separate video-only + audio-only pair
    /// (`Resolve.StreamTarget`) play with sound at all: `mediaPlayer`
    /// only ever has one primary `VLCMedia`, so the audio half has to
    /// arrive this way rather than as a second `load(url:)`.
    /// `enforce: true` selects it immediately rather than leaving it as
    /// an alternate track the user would have to switch to manually.
    func load(url: URL, audioSlaveURL: URL?) {
        mediaPlayer.media = VLCMedia(url: url)
        if let audioSlaveURL {
            mediaPlayer.addPlaybackSlave(audioSlaveURL, type: .audio, enforce: true)
        }
    }

    func clear() {
        mediaPlayer.stop()
        mediaPlayer.media = nil
    }

    func play() { mediaPlayer.play() }
    func pause() { mediaPlayer.pause() }

    var isLoaded: Bool { mediaPlayer.media != nil }

    var currentTime: TimeInterval {
        Double(mediaPlayer.time.intValue) / 1000
    }

    var itemDuration: TimeInterval? {
        guard let ms = mediaPlayer.media?.length.intValue, ms > 0 else { return nil }
        return Double(ms) / 1000
    }

    func seek(to time: TimeInterval) {
        mediaPlayer.time = VLCTime(int: Int32((time * 1000).rounded()))
    }

    /// `PlaybackEngine.volume` is 0...1 (unity at 1.0, matching the old
    /// `AVPlayer.volume` contract that the crossfade math is written
    /// against); VLCKit's native range is 0...200 as a percentage, so this
    /// converts both ways rather than changing that contract.
    var volume: Float {
        get { Float(mediaPlayer.audio?.volume ?? 100) / 100 }
        set { mediaPlayer.audio?.volume = Int32((newValue * 100).rounded()) }
    }
}

extension VLCPlaybackEngine: VLCMediaPlayerDelegate {
    func mediaPlayerStateChanged(_ aNotification: Notification) {
        if mediaPlayer.state == .ended {
            onDidReachEnd?()
        }
    }
}
