# Waveform

A local media player for `.cmf` archives: `VaultDeckKit` (backend, Swift
Package) + `Waveform` (frontend, SwiftUI source files) + `WaveformWidgets`
(Dynamic Island / Live Activity extension, iOS only), tied together by
[XcodeGen](https://github.com/yonaskolb/XcodeGen) instead of a committed
`.xcodeproj`.

- **`VaultDeckKit/`** — the backend. Reads the real `.cmf`/`info.json`
  schema (Spotify metadata, match scoring, the cross-item asset-dedup
  quirk), `MediaLibrary` with album/artist grouping, `PlaylistStore`,
  `PlaybackQueue`, and an `AVPlayer`-backed `MediaPlayerController` with
  crossfade + volume normalization. See `BACKEND_README.md`.
- **`Waveform/`** — the frontend. Library (songs/albums/artists/
  playlists), queue, mini + full-screen player with video playback and
  album-color tinting, lock-screen/Control Center integration, settings.
  See `FRONTEND_README.md`.
- **`WaveformShared/`** — types shared between the app and the widget
  extension (the Live Activity's data model, the App Group identifier).
- **`WaveformWidgets/`** — the Dynamic Island / Lock Screen Live Activity,
  a separate app-extension target embedded into `Waveform-iOS`.
- **`project.yml`** — the XcodeGen spec that generates `Waveform.xcodeproj`
  (three targets: `Waveform-iOS`, `Waveform-macOS`, `WaveformWidgets`).

## Quick start

```bash
brew install xcodegen
xcodegen generate
open Waveform.xcodeproj
```

Before your first real build, three placeholders need real values —
`FRONTEND_README.md`'s "Before your first build" section has the details,
but in short: the bundle ID prefix (`project.yml`), the App Group
identifier (`WaveformShared/AppGroup.swift` + both `.entitlements`
files, all three need to agree), and code signing for the new
`WaveformWidgets` target.

Re-run `xcodegen generate` any time you add, remove, or rename a source
file — it's the one command that keeps the `.xcodeproj` in sync with
what's on disk, so nobody has to hand-edit file references in Xcode again.

## Read first

- `BACKEND_README.md` — the `.cmf` format as actually produced, the
  dedup-quirk handling, and the crossfade/normalization design.
- `FRONTEND_README.md` — full feature list and a "Known gaps / next
  steps" section — read that before assuming something missing is a bug
  rather than a documented scope cut.
