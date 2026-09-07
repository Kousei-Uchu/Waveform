//
//  WFLog.swift
//  WaveformBackendKit
//
//  Created by Aiden McGovern (School) on 5/9/2026.
//


import os

/// Centralized `os.Logger` instances, one per functional area, so
/// Console.app / Xcode's log pane / `log stream --predicate 'subsystem ==
/// "com.waveform.app"'` can actually show what the search → match →
/// resolve → fetch → library pipeline is doing.
///
/// Before this file existed there was **no logging anywhere in the
/// project** — the only thing resembling it was a stray `print(lookup)`
/// left in `Match.swift`'s `pickVideoSource`, and that line sat on a code
/// path the app never actually called. Every throwing function still
/// throws (callers already surface those as UI-level errors where it
/// matters — `LibraryStore.lastError`, `DownloadManager.State.failed`,
/// `SearchGroup.error`), but there was previously no way to see *why* a
/// search came back empty, why a match picked what it picked, or why a
/// resolve/fetch silently took a slow path, without attaching a debugger.
///
/// Each category logs at `.debug` for "here's what happened, useful for
/// tracing a specific run," `.info` for "made a deliberate fallback
/// choice worth knowing about," `.warning` for "picked a fallback that
/// has a real, user-visible downside," and `.error` immediately before
/// something throws or fails outright.
public enum WFLog {
    private static let subsystem = "com.waveform.app"

    /// `Search.swift`: YouTube/Spotify search calls, URL resolution.
    public static let search = Logger(subsystem: subsystem, category: "search")
    /// `Match.swift`: scoring, source picking, Genius lookups.
    public static let match = Logger(subsystem: subsystem, category: "match")
    /// `Resolve.swift`: stream/variant selection.
    public static let resolve = Logger(subsystem: subsystem, category: "resolve")
    /// `Fetch.swift`: the actual byte download.
    public static let fetch = Logger(subsystem: subsystem, category: "fetch")
    /// `LibraryStore.swift`: reads/writes of `library.json` and media files.
    public static let library = Logger(subsystem: subsystem, category: "library")
    /// `MediaPlayerController`/playback engines.
    public static let playback = Logger(subsystem: subsystem, category: "playback")
    /// App-level `DownloadManager` orchestration.
    public static let download = Logger(subsystem: subsystem, category: "download")
}