//
//  NowPlayingStore 2.swift
//  Waveform
//
//  Created by Aiden McGovern (School) on 10/9/2026.
//


#if os(iOS)
import Foundation
import WidgetKit

/// Reads/writes `NowPlayingSnapshot` to the shared App Group container —
/// the one place both the app (the only real writer) and
/// `WaveformWidgets` (the reader) agree on where this data lives and how
/// it's encoded. Plain `UserDefaults(suiteName:)` rather than a file:
/// it's a single small value read on every widget timeline refresh, and
/// that's exactly the access pattern `UserDefaults` backed by the App
/// Group's shared container is for — see `AppGroup` for the container
/// identifier both sides already share (for the artwork file).
public enum NowPlayingStore {
    /// `Widget.kind` for `NowPlayingWidget`, declared here (rather than
    /// only inside the widget extension's own `Widget` conformance) so
    /// `NowPlayingWidgetSync` can pass the exact same string to
    /// `WidgetCenter.shared.reloadTimelines(ofKind:)` without the app
    /// target needing to import the widget extension's code — which it
    /// can't, extensions aren't importable — or hardcode a second copy of
    /// the string that could silently drift out of sync with the real one.
    public static let widgetKind = "NowPlayingWidget"

    private static let snapshotKey = "waveform.nowPlayingSnapshot"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: AppGroup.identifier)
    }

    /// `nil` on any failure: no App Group container, nothing written
    /// yet, or a decode failure (e.g. a future app version changing
    /// `NowPlayingSnapshot`'s shape while an old widget process still has
    /// the previous binary in memory) — every caller already has a
    /// sensible "nothing's playing" empty state to fall back to.
    public static func read() -> NowPlayingSnapshot? {
        guard let data = defaults?.data(forKey: snapshotKey) else { return nil }
        return try? JSONDecoder().decode(NowPlayingSnapshot.self, from: data)
    }

    /// Writes `snapshot` (`nil` clears it — nothing playing/queue empty)
    /// and, unless `reload` is `false`, immediately asks WidgetKit to
    /// re-render `NowPlayingWidget`. This *is* the "WidgetKit
    /// notification" that tells the widget its data changed — WidgetKit
    /// has no push/observer mechanism of its own for App Group data, so
    /// without an explicit `reloadTimelines` call after every write, a
    /// home-screen widget would simply keep showing stale data until its
    /// next system-scheduled (infrequent, unpredictable) refresh.
    ///
    /// `reload` exists so a caller doing several writes in quick
    /// succession (e.g. clearing state, then immediately writing fresh
    /// state for the next track) can defer the reload to the last one —
    /// `WidgetCenter` calls aren't free, and redundant back-to-back
    /// reloads just make the on-screen widget flicker.
    ///
    /// Callable from both the app and the widget extension itself, since
    /// this type has to compile in both places anyway — but in practice
    /// only the app ever calls it: every `AudioPlaybackIntent` in
    /// `NowPlayingIntents.swift` always actually runs its `perform()` in
    /// the *app's* process (see `NowPlayingIntentBridge`'s doc comment),
    /// which is what then calls this after applying the transport change.
    public static func write(_ snapshot: NowPlayingSnapshot?, reload: Bool = true) {
        guard let defaults else { return }
        if let snapshot, let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: snapshotKey)
        } else {
            defaults.removeObject(forKey: snapshotKey)
        }
        if reload {
            WidgetCenter.shared.reloadTimelines(ofKind: widgetKind)
        }
    }
}
#endif