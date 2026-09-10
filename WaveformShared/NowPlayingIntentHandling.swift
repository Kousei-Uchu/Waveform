//
//  NowPlayingIntentHandling.swift
//  Waveform
//
//  Created by Aiden McGovern (School) on 10/9/2026.
//


#if os(iOS)
import AppIntents

/// What an `AudioPlaybackIntent` below actually calls into once the
/// system has routed its `perform()` to run in the app's own process
/// (see the intents' doc comments for why that routing happens
/// automatically, without the app needing to be foregrounded). Defined
/// as a protocol — rather than each intent referencing
/// `MediaPlayerController` directly — so this file compiles unchanged in
/// both the `Waveform-iOS` app target (which sets
/// `NowPlayingIntentBridge.handler` to a real adapter at launch — see
/// `NowPlayingWidgetSync`) and the `WaveformWidgets` extension target
/// (which needs these intent *types* to exist, since its SwiftUI widget
/// code references them directly in `Button(intent:)`, but never
/// actually needs — or gets — a real handler; see `NowPlayingIntentBridge`).
@MainActor
public protocol NowPlayingIntentHandling: AnyObject {
    func togglePlayPause() async
    func skipToNext() async
    func skipToPrevious() async
}

/// Set once, at app launch, by whichever object in the `Waveform-iOS`
/// app target actually owns `MediaPlayerController`
/// (`NowPlayingWidgetSync.start(...)`). `weak` because that owner is a
/// long-lived `@StateObject` the app's own view hierarchy already keeps
/// alive for the app's lifetime — this is a reference to it, not a
/// second owner.
///
/// Stays `nil` for the entire lifetime of the `WaveformWidgets`
/// extension process: nothing in that process ever sets it, and nothing
/// needs to. Every intent below conforms to `AudioPlaybackIntent`, which
/// the AppIntents framework specifically routes to run in the
/// *originating app's* process rather than the widget extension's,
/// precisely so a widget's (or Lock Screen's, or Siri's) playback
/// controls can reach a real, already-running player without needing
/// their own audio session — see
/// `developer.apple.com/documentation/appintents/audioplaybackintent`.
/// The intent *types* still have to compile inside the extension target
/// too, since the widget's SwiftUI code references them directly — that
/// dependency is the only reason this file is a member of both targets.
@MainActor
public enum NowPlayingIntentBridge {
    public static weak var handler: NowPlayingIntentHandling?
}

public struct PlayPauseIntent: AudioPlaybackIntent {
    public static var title: LocalizedStringResource = "Play/Pause"
    public static var description = IntentDescription("Toggles Waveform playback.")

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        await NowPlayingIntentBridge.handler?.togglePlayPause()
        return .result()
    }
}

public struct SkipForwardIntent: AudioPlaybackIntent {
    public static var title: LocalizedStringResource = "Next Track"
    public static var description = IntentDescription("Skips to the next track in Waveform.")

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        await NowPlayingIntentBridge.handler?.skipToNext()
        return .result()
    }
}

public struct SkipBackIntent: AudioPlaybackIntent {
    public static var title: LocalizedStringResource = "Previous Track"
    public static var description = IntentDescription("Skips to the previous track (or restarts the current one) in Waveform.")

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        await NowPlayingIntentBridge.handler?.skipToPrevious()
        return .result()
    }
}
#endif