# Waveform — SwiftUI frontend

The frontend for the app, built on `VaultDeckKit`. Source files only —
there's no hand-built `.xcodeproj` to go stale; see **Building** below for
how the project file actually gets generated.

## What's here

```
Waveform/
  WaveformApp.swift          — @main, wires up every store into the environment
  Waveform-iOS.entitlements  — App Group (for the Live Activity's shared artwork)
  Waveform-macOS.entitlements
  Stores/
    VaultStore.swift         — persists the chosen folder as a security-scoped bookmark
    ArtworkStore.swift       — loads + caches cover art (NSImage/UIImage)
    PaletteStore.swift       — average-color extraction for the now-playing tint
    LiveActivityManager.swift — Dynamic Island / Lock Screen Live Activity (iOS only)
    DeepLinkRouter.swift     — waveform://now-playing, opened by tapping the Live Activity
  Views/
    RootView.swift           — adaptive shell + persistent mini player + Now Playing sheet
    Library/
      LibraryView.swift      — container: shared NavigationStack, Songs/Albums/Artists/Playlists switcher, import
      SongsView.swift, MediaItemCard.swift, EmptyLibraryView.swift, ItemDetailView.swift
    Albums/
      AlbumsView.swift, AlbumDetailView.swift
    Artists/
      ArtistsView.swift, ArtistDetailView.swift
    Playlists/
      PlaylistsView.swift, PlaylistDetailView.swift, LikedSongsView.swift
    Queue/
      QueueView.swift, QueueRow.swift
    Player/
      PlayerBar.swift, NowPlayingView.swift   — video playback + album-color tint live here
    Settings/
      SettingsView.swift     — vault folder, library stats, normalize volume, crossfade
    Shared/
      ArtworkView.swift, SongRow.swift, SongContextMenu.swift,
      LikeButton.swift + AddToPlaylistMenuItems (in PlaylistControls.swift), QueueActions.swift
  Utilities/
    TimeFormatting.swift

WaveformShared/               — compiled into BOTH Waveform-iOS and WaveformWidgets
  AppGroup.swift               (deliberately NOT into Waveform-macOS — see project.yml)
  PlaybackActivityAttributes.swift

WaveformWidgets/               — separate app-extension target, iOS only
  WaveformWidgetsBundle.swift
  PlaybackActivityWidget.swift — Lock Screen banner + Dynamic Island compact/minimal/expanded
  WaveformWidgets.entitlements
```

## Building

This uses [XcodeGen](https://github.com/yonaskolb/XcodeGen) instead of a
committed `.xcodeproj` — `project.yml` at the repo root is the source of
truth; the `.xcodeproj` is a disposable build artifact.

```bash
brew install xcodegen
cd WaveformProject   # wherever project.yml lives
xcodegen generate
open Waveform.xcodeproj
```

`project.yml` defines three targets — `Waveform-iOS`, `Waveform-macOS`,
and `WaveformWidgets` (the Live Activity extension, iOS only, embedded
into `Waveform-iOS`) — pointed at the `Waveform/`/`WaveformShared/`/
`WaveformWidgets/` source folders and depending on `VaultDeckKit` as a
local Swift package. Re-run `xcodegen generate` any time you add/remove/
rename source files; it regenerates the project to match what's on disk,
so you never hand-edit file references in Xcode.

**Before your first build**, three things need a real value instead of
the placeholders here:

1. **Bundle ID prefix.** `project.yml` uses `com.yourname` throughout
   (`PRODUCT_BUNDLE_IDENTIFIER` for all three targets) — change it to
   something you actually own.
2. **App Group, for the Live Activity's artwork.** `WaveformShared/AppGroup.swift`
   hardcodes `group.com.yourname.waveform`. Register a real App Group
   with that (or your own) identifier in your Apple Developer account,
   then update it in **three** places so they agree:
   `WaveformShared/AppGroup.swift`, `Waveform/Waveform-iOS.entitlements`, and
   `WaveformWidgets/WaveformWidgets.entitlements`. If you skip this, the
   app still runs fine and the Live Activity still appears — it just
   always shows a placeholder music-note glyph instead of real artwork,
   since the shared container silently fails to resolve on both sides.
3. **Code signing for the widget extension**, same as any other target —
   Xcode will prompt for a team/provisioning profile for `WaveformWidgets`
   the first time you build for a device.

If you'd rather use [Tuist](https://tuist.io) instead of XcodeGen, the
same idea applies — `project.yml`'s target/dependency shape maps over
fairly directly to a `Project.swift` manifest; XcodeGen's just the
simpler of the two for a project this size.

## What's implemented

- **Adaptive shell**: `NavigationSplitView` sidebar (Library/Queue/Settings)
  on iPad regular-width and macOS, falling back to the original `TabView`
  on iPhone/compact width. Each section keeps its own internal
  `NavigationStack` in both layouts.
- **Library**: Songs/Albums/Artists/Playlists in one segmented switcher,
  sharing a single navigation stack. Import a folder (persisted, rescanned
  at launch) or individual `.cmf` files.
- **Albums/Artists**: grouped from `MediaLibrary.albums`/`.artists` (see
  the backend README for the grouping heuristic), with Play/Shuffle and,
  on an artist page, tracks organized by album.
- **Playlists + Liked Songs**: create/rename/delete, reorder, add from any
  song's context menu, a dedicated Liked Songs screen.
- **Queue**: reorderable, swipe to remove, shuffle, repeat off/one/all.
- **Player**: mini bar + full-screen Now Playing. Switches to a real
  `VideoPlayer` for video queue entries (audio stays on the artwork view);
  the whole screen tints toward the current track's average artwork color
  (`PaletteStore`, via `CIAreaAverage` — not real dominant-color
  clustering, just a cheap representative average, which is enough for a
  background tint).
- **Lock screen / Control Center**: `MPNowPlayingInfoCenter` +
  `MPRemoteCommandCenter` (play/pause/next/previous/seek), driven from
  `MediaPlayerController`.
- **Dynamic Island / Live Activity** (iOS only, iOS 16.2+ — a separate
  `WaveformWidgets` app-extension target, see `project.yml`): shows
  artwork/title/artist/progress on the Lock Screen and in the Dynamic
  Island (compact/minimal/expanded), Spotify-style. Tapping it opens the
  app straight to Now Playing via a `waveform://now-playing` deep link
  (`DeepLinkRouter`). Artwork crosses into the extension through a shared
  App Group container (`AppGroup`) since the extension can't read a `.cmf`
  archive itself, and `ContentState` deliberately carries no live-ticking
  timer — `ProgressView(timerInterval:)` has a
  [documented Apple bug](https://developer.apple.com/forums/thread/722073)
  where it freezes at 100% specifically in Dynamic Island/always-on-lock-
  screen contexts, so progress is a plain static value refreshed on
  track-change/play-pause and throttled to once every 5 seconds while
  playing, not a smoothly animating bar.
- **Settings**: vault folder, library stats, Normalize Volume toggle,
  Crossfade duration picker (Off/3s/6s/10s) — both bound straight to
  `VaultDeckKit`'s `PlaybackSettingsStore`.
- **Accessibility**: icon-only controls (transport buttons, toolbar menus,
  like/shuffle/repeat toggles) have `accessibilityLabel`/`accessibilityValue`;
  decorative artwork and status icons paired with adjacent text are hidden
  from VoiceOver rather than double-announced; composite rows (song/queue/
  library cards) are combined into single accessibility elements with a
  sensible label and a "double tap to play" hint instead of reading each
  sub-view separately. **Not done**: a real device VoiceOver walkthrough
  (everything here is reviewed by reading the view code, not by actually
  running a screen reader over it), and no explicit Dynamic Type stress
  test — nothing was found that hard-clips at large text sizes on
  inspection, but that's not the same as verifying it.

## Known gaps / next steps

Everything that was in this section as of the previous pass (no lock-screen
controls, path-based playlist ids, single-file imports not persisting,
crossfade not handling mid-fade queue mutation, no duplicate detection, no
match/source metadata in the UI) has been addressed — see `BACKEND_README.md`
for the details on each. What's left:

- **Live Activity artwork depends on the App Group actually being set up.**
  If `AppGroup.identifier` doesn't match a real App Group registered in
  your Apple Developer account (and both entitlements files), the Live
  Activity still works — it just falls back to a plain music-note glyph
  instead of real artwork, since `containerURL(forSecurityApplicationGroupIdentifier:)`
  returns `nil` and both sides silently skip the image. See "Before your
  first build" above.
- **Crossfade orchestration is unit-test-free.** See
  `BACKEND_README.md`'s testing section — it needs real `AVPlayer`s
  advancing over real wall-clock time, which isn't practical to drive from
  `XCTest` without a much heavier harness than this project has.
- **Never actually run through a real pipeline-produced `.cmf`.** Every
  test fixture here is built by this package's own `CMFWriter`, which
  proves internal read/write consistency, not that every real-world edge
  case in an archive from the actual CMF Pipeline is handled correctly.

## A note on testing

No Swift toolchain in the environment this was built in, so none of this
has actually run through `xcodegen generate` + a real Xcode build. I've
hand-checked types, API signatures, and brace balance throughout,
cross-referenced the `MediaPlayer` framework calls (`MPNowPlayingInfoCenter`,
`MPRemoteCommandCenter`, `MPMediaItemArtwork`) against Apple's docs rather
than trusting memory, and validated `project.yml`'s structure — including
the `schemes:` block — against XcodeGen's actual documented spec and real
example configs rather than assuming its defaults. None of that is a
substitute for a real build; treat the first one as the actual test and
paste back whatever errors come up.
