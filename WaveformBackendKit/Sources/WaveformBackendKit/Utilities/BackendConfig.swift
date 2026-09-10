//
//  BackendConfig.swift
//  WaveformBackendKit
//
//  Created by Aiden McGovern (School) on 10/9/2026.
//


import Foundation

/// Base URL of the Vercel backend that now handles YouTube/YouTube
/// Music search (via youtubei.js) and proxies the official Genius API
/// (token pool + rotation) — see `waveform-search-backend`'s README.
///
/// A mutable static, same pattern as `Search.defaultYouTubeSource`:
/// set this once at app launch (e.g. from `WaveformApp.init`) before
/// any search or Genius call happens. Nothing in this package ever
/// uses this URL to resolve a playable YouTube stream/download URL —
/// that still happens entirely on-device via YouTubeKit in
/// `Resolve.swift`; this backend only ever sees search queries and
/// video IDs, never the resulting stream.
public enum BackendConfig {
    public static var baseURL = URL(string: "https://waveform-search-backend.vercel.app")!
}
