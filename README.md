# Waveform

A music and video player for iOS and macOS that doubles as your own
personal library. Search for a song, play it instantly by streaming,
and only download it if you actually want to keep it — everything you
do keep lives in one place, organized by song, album, artist, and
playlist, and plays back with crossfade, volume normalization, and a
Dynamic Island widget that follows the music out of the app.

## Finding music

Open Search, type a song or artist — or just paste a YouTube or
Spotify link — and results start coming back as you type. Tap one and
it starts playing right away by streaming, no download required, so
you can check something out before deciding whether it's worth keeping.
If it's a Spotify result, Waveform quietly finds the best-matching
YouTube source behind the scenes, checking title, artist, duration, and
even a quick audio comparison against the audio it already picked — so
the video that plays actually matches the song, not just a
same-titled upload of something else. Playlists on either service can
be pulled in and downloaded all at once instead of one track at a time.

## Your library

Anything you download gets added to your library and organized
automatically into Songs, Albums, Artists, and Playlists, with a Liked
Songs shelf for quick favorites. Play an artist and get their tracks
grouped by album; play an album and it queues the whole thing in order.
Playlists can be created, renamed, reordered, and built up from any
song's context menu, the same way you'd expect from any music app.

## Playing it back

Playback is gapless and crossfades between tracks rather than cutting
abruptly — the next song fades in as the current one fades out, with
crossfade length adjustable in Settings (or turned off entirely). Songs
that are mixed too loud get pulled down automatically so you're not
reaching for the volume knob every time a quiet track is followed by a
loud one. Video tracks play back the actual video instead of falling
back to just audio, and the whole Now Playing screen tints itself to
match the current song's artwork rather than sitting on a plain
background.

Once something's downloaded, if you don't need it at full quality, a
Shrink option re-encodes the file to a smaller size right on your
device, with sensible defaults and knobs to override if you want more
control.

## Everywhere else on your device

Play/pause, skip, and scrubbing show up on your lock screen and in
Control Center like any other media app. On iPhone, Waveform also puts
a live Dynamic Island / Lock Screen widget on the now-playing track —
artwork, title, artist, and progress — and tapping it jumps straight
back into the full Now Playing screen.

## Getting started

Waveform runs on iPhone, iPad, and Mac from one project — the phone and
iPad layout adapts into a sidebar on iPad and Mac rather than staying
locked to a phone-sized tab bar. Bring your own YouTube/Spotify access
where the search step needs it, point Waveform at where you want your
library stored, and you're set.

---

Building it yourself, or curious how it works? See
[DEVELOPMENT.md](DEVELOPMENT.md) for the architecture, build steps, and
tests.
