//
//  ArtworkSelection.swift
//  WaveformBackendKit
//
//  Created by Aiden McGovern (School) on 5/9/2026.
//


import Foundation

/// The single place that decides "which image is this track's artwork" —
/// written so both the streaming path (a `RemoteRef`'s displayed
/// thumbnail, before anything is downloaded) and the download path
/// (whatever gets fetched and written into `Artwork/` at fetch time) make
/// the *same* choice, rather than each guessing independently and
/// quietly disagreeing.
///
/// The policy: **always prefer the original Spotify candidate's album
/// cover over a YouTube thumbnail**, when a Spotify candidate exists at
/// all. This matters specifically because `Match.pickAudioSource`/
/// `pickVideoSource` (the previous pass) resolve a Spotify track to a
/// *YouTube* `SearchCandidate` for playback — without this, whichever
/// video ends up matched would silently determine the artwork too (a
/// YouTube thumbnail, often lower quality or just the wrong crop/edition
/// compared to the actual Spotify album art), even though the original
/// Spotify search result already had the real cover art sitting right
/// there in `thumbnailURLString`.
public enum ArtworkSelection {

    /// `raw` is whatever the user actually searched for/tapped (may be
    /// Spotify- or YouTube-origin); `matched` is what `Match` resolved it
    /// to for actual playback (always YouTube-origin, per
    /// `SourcePick.candidate`). Returns `raw`'s cover when `raw` is a
    /// Spotify candidate — Spotify's album art is reliably higher quality
    /// and correctly-cropped square art, versus a YouTube thumbnail's
    /// video-frame aspect ratio and inconsistent quality — falling back
    /// to `matched`'s thumbnail (or `raw`'s, if `matched` has none) for a
    /// YouTube-origin `raw` with no Spotify counterpart at all.
    public static func preferredArtworkURL(raw: SearchCandidate, matched: SearchCandidate) -> URL? {
        if raw.origin == .spotify, let spotifyArt = raw.thumbnailURL {
            return spotifyArt
        }
        return matched.thumbnailURL ?? raw.thumbnailURL
    }

    /// Convenience for the common case where nothing has been matched
    /// yet (e.g. a bare Spotify search result being turned straight into
    /// a `RemoteRef` for immediate streaming before matching completes,
    /// or a video-intent lookup that came back `skip`) — just `raw`'s own
    /// best thumbnail, Spotify or otherwise.
    public static func preferredArtworkURL(raw: SearchCandidate) -> URL? {
        raw.thumbnailURL
    }
}