# VaultDeckKit

The backend for a SwiftUI media app: reads the real `.cmf` format (as
documented from the CMF Pipeline's `server/services/cmf.js` et al. —
Spotify-enriched metadata, YouTube match scoring, cross-item asset dedup and
all), plus a library index with album/artist grouping, playlists and liked
songs, an ordered playback queue, and an `AVPlayer`-backed controller with
crossfade and attenuation-based volume normalization.

Only third-party dependency: [ZIPFoundation](https://github.com/weichsel/ZIPFoundation)
(MIT), since a `.cmf` is a zip with the extension renamed and Foundation has
no built-in zip read/write support.

## Install

Xcode: **File → Add Package Dependencies…** and point at this package's
directory. Or, if you're using XcodeGen for the app itself (see the
frontend README), it's wired up automatically as a local package dependency
in `project.yml`.

## What's in it

| Type | Role |
|---|---|
| `MediaInfoDocument` / `MediaPaths` / `MediaSource` / `MediaMatch` / `MatchNote` / `MatchScore` | 1:1 mirror of `info.json`, including the match/scoring data |
| `MediaItem` | A resolved item — metadata plus already-resolved audio/video/asset paths, and album/artist grouping keys |
| `CMFArchive` | Read access: list items, read/extract entries, resolve dedup-skipped assets |
| `CMFWriter` / `CMFWritableItem` | Builds a `.cmf` matching the real schema — mainly for test fixtures now, since the actual pull/match pipeline lives outside this package |
| `MediaLibrary` | `ObservableObject` indexing archives; `.items`, `.albums`, `.artists`, search |
| `PlaylistStore` | `ObservableObject`: user playlists + liked songs, JSON-persisted |
| `PlaybackQueue` | `ObservableObject`: ordered queue, shuffle, repeat-one/all, next/previous/peek |
| `PlaybackSettingsStore` | `ObservableObject`: normalize-volume toggle, crossfade duration — persisted to `UserDefaults` |
| `MediaPlayerController` | `ObservableObject` wrapping two `AVPlayer`s (for crossfade); exposes `avPlayer` for video playback |

Everything meant to be observed by SwiftUI is `@MainActor` and
`ObservableObject` — bind with `@StateObject`/`@EnvironmentObject` as usual.

## The `.cmf` format, as actually produced

One top-level folder per item (never nested album/playlist folders — those
are expanded client-side before packing):

```
{item_title}_{item_author}/
  info.json
  audio/{item_title}_{item_author}.mp3     — present iff mode includes audio
  video/{item_title}_{item_author}.mp4     — present iff mode includes video
  assets/
    cover.{ext}
    artist.{ext}
```

`info.json`: `item_title`, `item_author`, `album_meta` (open-ended — full
Spotify Album object, a slim fallback, or `{}`), `author_meta` (same
tiering for the artist), `paths` (`audio`/`video` nullable single paths,
`assets` an array), `source` (`origin`/`url`/`spotify_id`/`youtube_id`/
`isrc`), `duration_ms`, `match` (`audio`/`video` weighted-search scoring,
when applicable), `packed_at`, `mode`.

**The dedup quirk (format doc §4), and how this package handles it:** the
packer SHA-256-hashes every file as it's added and skips writing one whose
bytes already exist anywhere earlier in the archive — so `paths.assets` can
point at a file that was never actually written, when it's a byte-identical
cover shared with an earlier item. `CMFArchive.listItems()` resolves this
itself: if a declared asset path isn't present in the zip, it looks for the
same filename (`cover.*` / `artist.*`) under a sibling item sharing this
item's Spotify album id (preferred) or artist id, and uses that instead.
By the time you have a `MediaItem`, `coverAssetEntryPath`/
`artistAssetEntryPath` are either a real, present entry path or `nil` —
never a reference you have to chase down yourself. Audio/video paths get
no such fallback (the format doc doesn't describe one, and cross-track
audio collisions are vanishingly rare) — a dangling audio/video reference
just fails with `CMFError.fileNotFound` when you try to read it.

Everything else — folder/file naming, title/author cleanup, the match
score shape, known format limitations — mirrors the format doc this was
built from field-for-field.

## Playback: crossfade and normalization

`MediaPlayerController` runs two `AVPlayer`s. Only one is ever "active"
(`avPlayer` always points at it — hand it straight to `VideoPlayer(player:)`
for a video entry). When crossfading:

1. On each time-observer tick, once the active *audio* track is within
   `settings.crossfadeDuration` of its end, the next queue entry (if it's
   also audio) is extracted and loaded onto the standby player at volume 0.
2. Every subsequent tick ramps the outgoing player's volume down and the
   incoming player's volume up in proportion to elapsed time, until the
   incoming player is at full (post-normalization) volume — at which point
   the two players swap roles and the queue silently advances to match
   what's already playing.

Crossfade only applies between two **audio** entries — video never
crossfades, and a crossfade in progress is cancelled by any manual
skip/seek.

**Volume normalization is attenuation-only.** `AVPlayer.volume` can only
turn a track down (0...1), never boost one above its native level, so this
isn't real two-way loudness matching — `LoudnessAnalyzer` measures a
track's average RMS over its first ~30 seconds and, if it's louder than a
fixed reference target, returns a gain below 1.0 to bring it down. Quieter
tracks are left alone. Good enough to stop one track from blowing out your
ears after a quiet one; not a substitute for real LUFS-based normalization.

## Playlists and liked songs

`PlaylistStore` persists to a small JSON file under
`Application Support/VaultDeckKit/playlists.json` (or wherever you point
`storageDirectory` at). Playlists reference items by `MediaItem.id`, which
is derived from the archive's file path plus its root folder — if a `.cmf`
moves to a different location on disk, items pointing at it won't resolve
in `items(in:library:)` until the archive is re-added from that same path.
Known limitation, not a bug to chase down right now.

## Album/artist grouping

`MediaLibrary.albums`/`.artists` group by Spotify id when `album_meta`/
`author_meta` carry one (the common case for Spotify-sourced items with
credentials configured), falling back to `author + album name` (albums) or
the cleaned author string (artists) for everything else — see
`MediaItem.albumGroupKey`/`artistGroupKey`. This is a heuristic, not a
guarantee of matching the pipeline's own dedup decisions.

## Design notes

- **Everything's local.** `CMFArchive` and `MediaLibrary` only ever read
  from a file URL you give them — no networking in this package.
- **`CMFArchive` is thread-safe** (`@unchecked Sendable`, internally
  locked), so extraction can happen off the main actor while
  `MediaLibrary` reads metadata on it.
- **`match`/`source` are read-only decorations, not used for playback
  decisions.** Nothing in this package re-runs or second-guesses the
  pipeline's YouTube matching — it's here for a UI that wants to show
  "why this file," not to redo the work.

## Running the tests

```bash
swift test
```

Covers: `CMFWriter`/`CMFArchive` round trips including the asset
dedup-fallback resolution (§4's dangling-reference scenario);
`MediaItem.id`'s content-based derivation and its survival across an
archive's path changing; `MediaLibrary`'s album/artist grouping and
cross-archive duplicate merging; `PlaylistStore`'s CRUD operations and
JSON persistence round-trip; `PlaybackQueue`'s next/previous/shuffle/
repeat/peek logic; `PlaybackSettingsStore`'s `UserDefaults` persistence;
and `LoudnessAnalyzer`'s attenuation behavior against synthetic sine-wave
audio generated in-test (louder input measurably attenuated more than
quieter input, nothing ever boosted, missing files fail closed to unity
gain rather than crashing).

**Not covered, and not easily coverable as unit tests:** the crossfade
orchestration in `MediaPlayerController` itself (the tick-driven ramp,
the mid-fade queue-mutation guard) isn't exercised by anything here — it
needs two real `AVPlayer`s actually advancing through real audio over
real wall-clock time, which isn't practical to drive from `XCTest`
without either a much heavier test harness (fake audio session, injected
clock) or genuinely waiting several seconds per test. The logic was
reviewed by hand instead; if you want confidence beyond that, an
integration-style test that plays two short fixture files through a real
`MediaPlayerController` and asserts on `currentEntryID`/volume at
specific timestamps would be the way to close this gap.
