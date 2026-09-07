# WaveformBackendKit v3 — Implementation Checklist

Tracking against `WaveformBackendKit — Spec v3 (iOS first)`. Updated as of
this pass. Legend: ✅ done · 🔧 in progress / partially done · ⬜ not started.

## §7 Models — ✅ DONE (one field added this pass)
- `MediaInfoDocument`, `MediaPaths`, `MediaSource`, `MediaMatch`/`MatchNote`/
  `MatchScore`/`MatchCandidate`, `JSONValue` — all present under
  `Sources/WaveformBackendKit/Models/`, matching the spec's field list
  exactly (including `id: UUID`, `media`/`MediaFile` block with
  `codec`/`container`/`shrunk`/`downloadCap`).
- `TrackKind`, `RemoteRef`, `Playable` (`Player.swift`) — present and match
  §4's description (remote vs library, `hasKind`, `isDownloaded`, etc).
- 🔧 `MatchScoreParts` (`Models/MatchNote.swift`) — added an optional
  `views` field this pass (source-ID dedup/JSON shape otherwise
  untouched, so old `library.json` still decodes fine). The original
  port of this struct had dropped `matcher.js`'s `views` weight (0.22,
  tied for second-highest) entirely; `Match.swift` needs it, so the
  model gained it back rather than `Match.swift` silently ignoring
  view-count signal that the spec's own reference implementation relies on.

## §6 Unified library layout — ✅ DONE
- `LibraryStore` (`Library/LibraryStore.swift`) owns `library.json` +
  `Audio/`/`Video/`/`Artwork/`, writes real (non-normalized) extensions,
  never leaves a dangling `paths.*` reference. `Grouping.swift` carried
  over as standalone functions.

## §5 Dedup — ✅ DONE
- `LibraryStore.existingItem(matching:)` / `MediaSource.matchesSameTrack`
  implement source-ID-first dedup exactly as specified.
- Artwork content-hash dedup (`storeArtworkDeduped`) — done.

## §4 Streaming vs. downloading, §3 encode strategy — ✅ DONE (Playback layer)
- `PlaybackQueue` is typed over `Playable` (mixed remote/library queues
  work as specified). `MediaPlayerController` resolves a remote entry's
  stream URL "just before it's needed" via an injected
  `resolveStreamURL` closure, crossfades only between two downloaded
  audio tracks, and defers to a caller-supplied `PlaybackEngine` (VLCKit
  lives in the app target, correctly kept out of the SPM package).
- Now backed end-to-end by `Acquire/Resolve.swift`+`Fetch.swift` (a
  single track can stream or download) and `Acquire/Search.swift`+
  `Match.swift` (something now actually *produces* the `RemoteRef`s fed
  into `resolveStreamURL`) — see §8 below.

## §8 `Acquire/` module — 🔧 IN PROGRESS
The folder now has five of six files:
- ✅ `Resolve.swift` — `YouTube(videoID:).streams`-backed resolution for
  both call sites in §4: `streamURL(for:kind:)` (streaming — best
  natively-playable stream, progressive-preferred for video, never
  cached) and `downloadVariant(for:kind:cap:)` (download — applies
  `DownloadResolutionCap`, prefers AV1 among candidates under the cap,
  falls back to the smallest available variant if nothing qualifies
  under it, per §10's "falls back sensibly otherwise"). Returns a
  `PickedVariant` (`url`/`codec`/`container`) that normalizes YouTube's
  raw codec strings down to the short labels §7's `MediaFile` wants.
  Flagged in a doc comment: exact `YouTubeKit.Stream` property names
  (`.codecs`, `.resolution`, `.fileExtension`, `.isNativelyPlayable`,
  etc.) are matched against the library's published usage examples, not
  a source checkout — worth a quick diff once the dependency is actually
  resolved by Xcode, since it's a small, actively-developed package.
- ✅ `Fetch.swift` — actor-isolated, resumable `URLSession` download of a
  `Resolve.PickedVariant` to a local temp file (stream-copy, §3 — no
  decode/encode). Reports `FetchProgress` (bytes, not just a fraction)
  via a callback; `pause()`/`resume()` round-trip through
  `URLSessionDownloadTask`'s native resume-data mechanism. Delegate
  callbacks land on a plain `NSObject` (`FetchSessionDelegate`) since
  actors can't themselves conform to `URLSessionDownloadDelegate`, and
  hop into the actor via `Task { await ... }`. `mediaFile(downloadCap:)`
  hands the caller a ready-to-use `MediaFile` for
  `LibraryStore.addOrUpdate`/`.replaceFile` — `Fetch` itself never
  touches the library folder.
- ✅ `TextMatching.swift` — new this pass, not in the original six-file
  list but a direct split-out of `CMF Pipeline/server/lib/text.js`
  (`normalizeText`/`stripTitleNoise`/`cleanArtistName`/`parseArtistTitle`/
  `diceCoefficient`/`durationScore`/`parseClockDuration`), for the same
  reason the old pipeline kept it out of `matcher.js`: none of it is
  YouTube/Spotify-specific, and both `Search.swift` and `Match.swift`
  need it.
- ✅ `Search.swift` — `SearchCandidate`/`SearchGroup`/`SearchResult`
  models plus:
  - `YouTubeSearch` — free-text YouTube search. **No vetted, actively
    maintained no-API-key Swift search library exists** (unlike stream
    extraction, which has `YouTubeKit`), so this is a direct,
    dependency-free port of `innertube.js`'s approach: POST to YouTube's
    internal `/youtubei/v1/search` with the well-known public "WEB"
    client key every unofficial YouTube client (yt-dlp, youtubei.js,
    NewPipe) uses, then walk the response tree generically for
    `videoRenderer` nodes (mirroring `innertube.js`'s `collectMedia`,
    which already has comments noting the exact shelf nesting has
    shifted across API versions — a generic walk survives more of that
    churn than a fixed key path). **Expect this to need touch-ups if/when
    YouTube changes the response shape** — same maintenance burden the
    old pipeline's `youtubei.js` dependency carried, just not absorbed by
    a library here.
  - `videoDetails(_:)` (single-video lookup, e.g. for a pasted URL) uses
    YouTube's actual public/documented **oEmbed** endpoint instead,
    since that's stable and doesn't need the internal-API guesswork —
    doesn't report duration, so a URL-pasted candidate's `durationMS` is
    `nil` until a stream is actually resolved.
  - `SpotifyClient` (actor) — client-credentials token caching + search/
    track/album/playlist/artist-top-tracks, a straight port of
    `spotify.js` against Spotify's public, documented Web API. Takes
    `Credentials` from whatever the app's Settings screen collects (§8
    app-level, not built yet).
  - `Search.pipeline(query:spotify:)` / `.resolveURL(_:spotify:)` — the
    `resolve.js` `searchPipeline`/`resolveUrl` entry points; grouped
    results with per-group error strings rather than a hard failure when
    one source (e.g. Spotify, if unconfigured) comes up empty.
- ✅ `Match.swift` — `matcher.js` ported field-for-field (`MatchWeights`
  including the restored `views` weight, `scoreCandidate`/
  `rankCandidates`, the video bonus/penalty keyword regex lists,
  log-scaled relative view scoring), plus the `jobs.js` orchestration
  around it: `pickAudioSource`/`pickVideoSource` (weighted search, with
  `GeniusClient` preferred over free-text search when configured — a
  Genius song page's linked YouTube media, filtered to non-"- Topic"
  channels, is a stronger "does an MV exist" signal than title/keyword
  scoring alone) and `Match.qualifies(_:)` (the `MIN_VIDEO_MATCH_SCORE`/
  `MIN_VIDEO_KEYWORD_SCORE` floor from `jobs.js`, hardcoded rather than
  env-tunable since there's no server env file in an iOS app — Settings
  is the natural place to expose these later if real-world use calls for
  it). `GeniusClient` is its own `actor` in this file (matches the spec's
  own description of `Match.swift` as "weighted scoring + Genius-assisted
  video matching" in one module) — a direct port of `lib/genius.js`,
  using `Search.videoDetails`'s oEmbed lookup in place of the old
  pipeline's `yt.getInfo(videoId)` Innertube call to resolve a Genius
  media link's channel name.
- ✅ `WaveformCorrelation.swift` — RMS envelope extraction + Pearson
  correlation, matching `ffmpeg.js`'s `extractPcmEnvelope`/
  `envelopeCorrelation` algorithm exactly (50ms/400-sample windows at
  8kHz, `maxLag = min(40, n/4)` two-direction lag search) — but decoding
  via `AVAudioFile`/`AVAudioConverter` and computing via `Accelerate`/
  vDSP instead of shelling out to ffmpeg, since ffmpeg isn't wired into
  this app until `Shrink.swift` lands and waveform matching needs to
  work before that. **Flagged caveat, not yet resolved**: `AVAudioFile`
  can't open a bare `.webm`/Opus file, which is exactly what
  `Resolve.downloadVariant` often picks for `kind: .audio` (YouTube's
  best audio is usually webm/Opus) — whatever wires up waveform probing
  end-to-end will need to either request an AAC/m4a probe-only variant
  or wait for `Shrink`'s ffmpeg. Left as a flagged gap rather than
  guessed at, since resolving it well depends on decisions
  (`Shrink.swift`'s ffmpeg build, or a second Resolve variant-selection
  path) that don't exist yet.
- ✅ `Shrink.swift` — explicit, user-initiated, per-item re-encode to
  AV1/Opus (video → `.webm`, audio → `.opus`), a direct port of
  `ffmpeg.js`'s `toWebm` encode arguments (10-bit `yuv420p10le`, same
  CRF/preset/bitrate defaults) minus the NVENC branch (no discrete GPU
  on iOS) and minus the "try a copy remux first" fallback (left to the
  Shrink UI to decide whether Shrink has anything to do at all, rather
  than this type silently no-op'ing). **Deliberately decoupled from any
  specific ffmpeg package**: the actual "run this command line" call
  goes through a small `FFmpegRunning` protocol rather than a concrete
  dependency, since §9's ffmpeg SPM package is still ⬜. A starting
  concrete implementation sketch (`FFmpegKitRunner`, commented out — see
  the file) targets the classic `FFmpegKit`/`FFmpegSession`/`ReturnCode`
  API most "ffmpeg for iOS" wrappers descending from mobile-ffmpeg
  expose, but **this hasn't been verified against `kingslay/FFmpegKit`
  specifically** — its README describes an `ffmpeg` *executable*
  product for `swift run`/macOS tooling, not a documented in-app
  programmatic API, so it may need a different concrete runner once
  it's actually added in Xcode and its real API is visible.

`Acquire/` is now feature-complete against the spec's six-file list —
search, match (with optional Genius/waveform assistance), resolve,
fetch, and shrink all exist. What's unverified rather than unbuilt: the
`YouTubeSearch`/`YouTubeKit.Stream`/`FFmpegRunning` caveats flagged
above, all of which need either a real Xcode/network environment or a
chosen concrete dependency to actually confirm.

## §9 Build changes — 🔧 IN PROGRESS
- ✅ `ZIPFoundation` dependency dropped from `Package.swift` (three passes ago).
- ✅ `YouTubeKit` (alexeichhorn) added to `Package.swift`, pinned
  `from: "0.4.0"`, wired as a dependency of the `WaveformBackendKit`
  target — consumed by `Resolve.swift`.
- No new SPM dependencies needed for `Search.swift`/`Match.swift`/
  `WaveformCorrelation.swift` this pass — YouTube search/oEmbed, Spotify,
  and Genius are all plain `URLSession` HTTP against documented or
  well-known endpoints, and the waveform math uses only `AVFoundation`/
  `Accelerate` (both system frameworks).
- 🔧 `kingslay/FFmpegKit` — **its real API is now confirmed** (this pass),
  resolving the previous pass's "not yet checked against the actual
  package" caveat: it's a single free function, `ffmpeg_execute(argc,
  argv) -> Int32`, called with a C-style argv whose index 0 is the
  literal `"ffmpeg"` token — not the `FFmpegKit`/`FFmpegSession`/
  `ReturnCode` object API the previous placeholder `FFmpegKitRunner`
  sketch assumed. That assumption turned out to be doubly wrong: it was
  the wrong shape for this package, *and* the project it was modeled on
  (`arthenica/ffmpeg-kit`) is now an **archived, discontinued repo** —
  not a lineage worth building against regardless. `Shrink.swift`'s
  `FFmpegKitRunner` sketch is rewritten against the real
  `ffmpeg_execute` shape (still commented out, still not compiled in).
  **Still open, and still can't be resolved without Xcode:**
  - `ffmpeg_execute`'s return-code convention isn't documented anywhere
    available to check against — `FFmpegKitRunner` assumes standard
    CLI exit-code convention (0 = success) but this is flagged as
    unverified, not confirmed.
  - The package needs a manual `swift package --disable-sandbox
    BuildFFmpeg` step after `swift package resolve` to compile the
    native libraries — unlike `YouTubeKit`, adding the `.package(...)`
    line to `Package.swift` alone doesn't make it buildable. Left
    commented out in `Package.swift` with that instruction attached
    rather than added live, since an uncommented dependency that can't
    actually build without a manual step someone has to remember to run
    would just break `swift build`/CI silently.
  - Worth carrying forward for distribution planning: its default build
    enables `libsmbclient`, making the resulting binary GPL rather than
    LGPL-licensed.
- ✅ `Podfile` (VLCKit/MobileVLCKit) — already correct, no change needed
  per spec (playback engine choice is unchanged from v2).

## Package/project plumbing — ✅ FIXED THIS PASS
- `Package.swift` was still named `VaultDeckKit` end-to-end (product,
  target, test target) despite living in a folder called
  `WaveformBackendKit` — renamed to `WaveformBackendKit` throughout.
- `Sources/WaveformBackendKit/WaveformBackendKit.swift` (the package's
  top-level doc/version enum) still described the old `.cmf`-archive
  backend — rewritten to describe v3.
- `project.yml`'s package block (`packages:`) and both app targets'
  dependency entries still said `VaultDeckKit`/pointed at a
  `VaultDeckKit` path — renamed to `WaveformBackendKit`.
- Removed a set of stale duplicate files that pre-dated the `Sources/`
  restructure (top-level `Library/`, `Models/`, `Playlists/` folders
  sitting next to `Sources/` and `Tests/`, byte-identical to their
  `Sources/` counterparts, not part of the SPM target, just dead weight).

## Tests target — ✅ FIXED THIS PASS (was fully broken)
Every file in `Tests/WaveformBackendKitTests/` imported
`@testable import VaultDeckKit` and several called APIs that no longer
exist (`CMFArchive`, `CMFWriter`, `MediaLibrary`, the old
`MediaItem(archiveURL:rootPath:info:...)` initializer,
`QueueEntry(item:kind:)`) — the whole target would not compile.
- ✅ `LoudnessAnalyzerTests.swift`, `PlaybackSettingsStoreTests.swift`,
  `SlugAndJSONValueTests.swift` — only needed the import fixed.
- ✅ `PlaybackQueueTests.swift` — `makeEntry` rebuilt on
  `MediaItem(info:audioFileURL:)` + `QueueEntry(playable:kind:)`; all
  `.item.title` call sites → `.playable.title`.
- ✅ `PlaylistStoreTests.swift` — `makeItem` fixed the same way;
  `testItemsInPlaylistResolvesThroughLibrary` rewritten against
  `LibraryStore`/`LibraryWrite` instead of `CMFWriter`/`MediaLibrary`.
- ✅ `MediaItemIdentityTests.swift` — per spec §10 ("asserts the UUID
  identity survives a file move"), rewritten from scratch: one test
  drives `LibraryStore.replaceFile` (the Shrink code path) and asserts
  `id` is unchanged; a second moves the whole library folder on disk and
  re-opens a fresh `LibraryStore` at the new path, asserting the same.
- ✅ `CMFRoundTripTests.swift` → **replaced with `LibraryRoundTripTests.swift`**
  per spec §10: write→read round trip through `LibraryStore`, source-ID
  dedup (`addOrUpdate` returns the existing item and never touches the
  "new" file on a matching-source second call), distinct sources produce
  distinct entries, and artwork content-hash dedup across two items.
- ✅ `MediaLibraryGroupingTests.swift` — rewritten to drive
  `Grouping.albums`/`Grouping.artists` directly against hand-built
  `MediaItem`s (the old cross-archive-duplicate-merge tests don't apply
  to a single unified store and were dropped; that behavior is now
  covered by `LibraryRoundTripTests`' dedup tests instead).
- ✅ `TextMatchingTests.swift` — full coverage of `normalizeText`,
  `stripTitleNoise`, `cleanArtistName`, `parseArtistTitle`,
  `diceCoefficient`, `durationScore`, `parseClockDuration` (already
  present; confirmed this pass to still match `TextMatching.swift`'s
  current API exactly, no changes needed).
- ✅ `MatchScoringTests.swift` — already present (confirmed against
  `Match.swift`'s current API this pass, no changes needed).
- ✅ `WaveformCorrelationTests.swift` — **written this pass**. Two
  halves: `correlation(_:_:)` against hand-built envelope arrays
  (identical/shifted/unrelated/empty/too-short/zero-variance cases, no
  audio file needed) — plus `envelope(of:)` itself, which turned out
  *not* to need a bundled fixture after all: it reuses
  `LoudnessAnalyzerTests`' synthetic-sine-wave-to-`.caf` trick (writes a
  known signal via `AVAudioFile`, decodes it back through
  `WaveformCorrelation.envelope(of:)`), covering window-count math,
  the `seconds` cap, a missing-file throw, and a full
  envelope→correlation round trip against itself.
- ✅ `ShrinkTests.swift` — **written this pass, fake-runner half only**
  (per the plan below, the real-encode half stays blocked): a
  `FakeFFmpegRunner` (actor conforming to `FFmpegRunning`) records
  calls and can be told to fail, covering `shrinkVideo`/`shrinkAudio`'s
  arg-building (codec/CRF/preset/bitrate flags land correctly,
  `-vn` is audio-only, video args never leak into the audio path),
  custom `Options` overriding the defaults, the `missingSourceFile`
  short-circuit (runner never invoked), a runner failure propagating as
  `.ffmpegFailed`, and `mediaFile(for:downloadCap:)`'s codec/container/
  `shrunk`/`downloadCap` values for both `TrackKind` cases.
- ⬜ Still blocked, genuinely needs a live/real environment:
  - `FetchStreamCopyTests` / resolution-cap tests — need live network
    access to a real YouTube video ID to be meaningful rather than a
    mocked shell, and `YouTubeKit.Stream` isn't something this codebase
    can construct by hand to fake inputs; worth revisiting with either a
    recorded-fixture approach or an injectable stream-provider seam on
    `Resolve` once one of those exists.
  - The real-encode half of `ShrinkTests` — spec §10's actual ask
    ("asserts a Shrink run produces an AV1/Opus file") needs the real
    ffmpeg SPM dependency built (see §9 above), not just a fake runner.

## §8 App-level (`Waveform/`) changes — ⬜ NOT STARTED
The entire frontend is still on the pre-v3 (`.cmf`/`VaultDeckKit`) model:
- `Waveform/Stores/VaultStore.swift` still does `import VaultDeckKit`,
  manages security-scoped bookmarks for individually-imported `.cmf`
  files and a vault *folder*, and calls `library.addArchive(at:)` /
  `library.scanDirectory(_:)` against a `MediaLibrary` type that no
  longer exists in the package. This needs to collapse to "one managed
  library folder" per §8 — a `LibraryStore` owned by the app, no more
  bookmark-per-file bookkeeping.
- ⬜ No Search & Download screen exists yet.
- ⬜ Now Playing / queue UI has no streaming-vs-downloaded visual
  distinction or a Download action on a currently-streaming track yet
  (the backend's `Playable.isDownloaded` is ready for this, UI isn't
  wired to it).
- ⬜ Library item detail has no Shrink action yet.
- ⬜ Settings has none of: Spotify client id/secret, optional Genius
  token, default resolution/bitrate cap, AV1/Opus encode knobs
  (re-scoped to Shrink).
- Every other view under `Waveform/Views/` (`AlbumsView`, `ArtistsView`,
  `LibraryView`, `PlayerBar`, `QueueView`, playlists, etc.) still
  presumably assumes the old `MediaLibrary`/`MediaItem` shape by way of
  `VaultStore` — none inspected line-by-line yet since they're all
  downstream of the `VaultStore` rewrite.
- `WaveformShared`/`WaveformWidgets` — unaffected per spec, not touched.

## Docs — ⬜ NOT STARTED
- Root `README.md`, `BACKEND_README.md`, and
  `WaveformBackendKit/README.md` all still describe the `.cmf`/
  `VaultDeckKit` architecture end-to-end. Spec v3 supersedes them but
  none have been updated yet. Left alone this pass to prioritize getting
  the package/tests actually compiling first — flagging so stale docs
  don't get mistaken for current design.

---

## What's next (suggested order)
1. ✅ ~~`Acquire/Resolve.swift` + `Fetch.swift`~~ — done.
2. ✅ ~~`Acquire/Search.swift` + `Match.swift` + `WaveformCorrelation.swift`~~
   — done. The full search → rank/pick → resolve → download chain
   exists, plus optional Genius/waveform assistance.
3. ✅ ~~`Acquire/Shrink.swift`~~ — done. `Acquire/` is feature-complete
   against the spec's six-file list.
4. ✅ ~~Confirm `kingslay/FFmpegKit`'s real API~~ — done this pass (§9):
   it's `ffmpeg_execute(argc, argv)`, not the `FFmpegKit`/`FFmpegSession`
   API the placeholder sketch assumed (that lineage is archived anyway).
   `FFmpegKitRunner` is rewritten against the confirmed shape.
   **What's left here is no longer a research question, just an
   Xcode-hands-on one**: run `swift package --disable-sandbox
   BuildFFmpeg` once the `.package(...)` line is uncommented in
   `Package.swift`, uncomment `FFmpegKitRunner` in `Shrink.swift`, and
   confirm the exit-code-convention assumption against a real encode.
5. ✅ ~~Write the newly-unblocked pure-function tests~~ — done.
   `TextMatchingTests`/`MatchScoringTests` were already present and
   still matched; `WaveformCorrelationTests` and the fake-runner half of
   `ShrinkTests` are new this pass. All no-network, all runnable in
   Xcode right now without touching the ffmpeg dependency question.
6. **App-level** (next up, and now the single largest remaining chunk of
   work): `VaultStore` simplification → Search & Download screen (can
   now actually call `Search`/`Match`/`Resolve`/`Fetch` end-to-end) →
   streaming/downloaded UI badges + Shrink action → Settings additions
   (Spotify client id/secret, optional Genius token, download cap,
   Shrink knobs).
7. Add the remaining network-dependent test files
   (`FetchStreamCopyTests`, resolution-cap tests, the real-encode half
   of `ShrinkTests`) once real ffmpeg/live YouTube access is available
   to test against (see Tests target section).
8. Update the three READMEs to describe v3 instead of the `.cmf` era.
