# WaveformBackendKit

The backend for Waveform: a standalone Swift package that owns
searching, matching, downloading, library storage, and playback. It has
no dependency on SwiftUI and no idea a UI exists — the app (see
[FRONTEND_README.md](FRONTEND_README.md)) is a thin layer on top of it.

## What's in it

```
WaveformBackendKit/Sources/WaveformBackendKit/
├── Acquire/    Search · Match · WaveformCorrelation · Resolve · Fetch · Shrink · ArtworkSelection
├── Library/    LibraryStore, album/artist grouping
├── Playback/   MediaPlayerController, PlaybackQueue, PlaybackEngine protocol, LoudnessAnalyzer
├── Playlists/  PlaylistStore (liked songs + user playlists)
└── Models/     MediaItem, RemoteRef, QueueEntry, TrackKind, ...
```

Very few third-party dependencies (YouTube search/resolve aside) — and
notably, it doesn't import VLCKit at all. Playback is defined against a
protocol (`PlaybackEngine`), and the app target supplies the concrete
VLCKit-backed implementation, so this package stays a plain SPM target
that never needs to carry a CocoaPods dependency.

## Matching a Spotify track to a real stream

Spotify search results are metadata, not audio — `Match.swift` searches
YouTube and scores every candidate against the real target: title
similarity, artist match, duration delta, keyword signals, channel
authority, view count. When candidates are close, `WaveformCorrelation.swift`
breaks the tie for real: it decodes ~30 seconds of audio from each
candidate with `AVFoundation`, reduces it to an RMS envelope with
`Accelerate`/vDSP, and cross-correlates it against the audio already
picked, rather than letting the video match guess independently:

```swift
public struct MatchWeights: Sendable {
    public var title = 0.27
    public var artist = 0.18
    public var duration = 0.09
    public var keywords = 0.20
    public var channel = 0.20
    public var views = 0.22
    public var waveform = 0.15
}
```

`Resolve.swift` then turns a chosen candidate into an actually-playable
stream URL, and `Fetch.swift` handles the resumable, progress-reporting
download when the user wants to keep it rather than just stream it.

## Playback

`MediaPlayerController` runs two playback engines at once — never one —
purely so it can crossfade between them: as a track nears its end, the
next one loads silently on the standby engine, then both volumes ramp
in opposite directions until they swap roles. `PlaybackEngine` is the
protocol that makes this engine-agnostic; see FRONTEND_README.md for
which concrete engine the app actually supplies.

`LoudnessAnalyzer` measures RMS over a track's first 30 seconds and
returns an attenuation gain — it can only turn a loud track down, never
boost a quiet one up, which is an honest tradeoff rather than a fake
"full" loudness match.

## Shrink

Re-encodes an already-downloaded audio or video file to Opus/AV1 in
place, with CRF/preset/bitrate knobs that default from the user's
settings but are overridable per file.

## Library and playlists

`LibraryStore` owns everything written to disk once a download
completes, and groups items into albums/artists. `PlaylistStore`
persists user playlists and liked songs.

## Tests

```bash
cd WaveformBackendKit && swift test
```

Covers match scoring, waveform correlation, loudness attenuation
(against synthetic sine-wave audio), text normalization/fuzzy matching,
playlist persistence, the playback queue's shuffle/repeat/next/previous
logic, settings persistence, and library round-trips.

## License

See individual dependencies for their own licenses (the YouTube
search/resolve libraries this package uses for the Acquire pipeline).
No license file is currently included for this repository's own code.
