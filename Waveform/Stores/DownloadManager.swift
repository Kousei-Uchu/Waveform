import Foundation
import WaveformBackendKit
import os

/// Drives the resolve→fetch→write path (§4) for the Search & Download
/// screen and for a "Download" action reachable from anywhere else a
/// `.remote` `Playable` shows up (a currently-streaming track, a queue
/// row). One instance, shared app-wide via `@EnvironmentObject`, so a
/// download kicked off from one screen shows its progress on another
/// (e.g. Search results and a Now Playing "Download" button referring to
/// the same track).
@MainActor
final class DownloadManager: ObservableObject {
    enum State: Equatable {
        case idle
        case downloading(FetchProgress?)
        case done
        case failed(String)
    }

    @Published private(set) var states: [String: State] = [:] // keyed by RemoteRef.id

    private let library: LibraryStore
    private let settings: PlaybackSettingsStore
    /// Used only to swap a now-downloaded track's queue entries from
    /// `.remote` to `.library` in place once a download completes (§4:
    /// "playback prefers the local copy automatically") — see
    /// `PlaybackQueue.replaceRemote(matching:with:)`'s doc comment for
    /// why that's safe to do without disrupting anything currently
    /// playing.
    private let queue: PlaybackQueue
    /// Read only for `.geniusClient` — used by `resolveVideoSource(for:)`
    /// below so a Spotify-origin download's video half gets independently
    /// (optionally Genius-assisted) matched rather than blindly reusing
    /// whichever video the audio half matched to.
    private let acquireSettings: AcquireSettingsStore

    init(library: LibraryStore, settings: PlaybackSettingsStore, queue: PlaybackQueue, acquireSettings: AcquireSettingsStore) {
        self.library = library
        self.settings = settings
        self.queue = queue
        self.acquireSettings = acquireSettings
    }

    func state(for ref: RemoteRef) -> State {
        if case .idle = states[ref.id] ?? .idle, isDownloaded(ref) {
            return .done
        }
        return states[ref.id] ?? .idle
    }

    /// Checked live against `library.items` rather than cached locally —
    /// a download completed on another screen (or a dedup hit) should be
    /// reflected immediately (§5), and `LibraryStore.existingItem` is
    /// already cheap (an in-memory scan, no disk/network access).
    func isDownloaded(_ ref: RemoteRef) -> Bool {
        library.existingItem(matching: ref.source) != nil
    }

    /// Resolves → fetches → writes `ref` into the permanent library
    /// (§3/§4). `kinds` is usually `ref.availableKinds` (download
    /// everything on offer) but callers can ask for just `.audio`, e.g. a
    /// "Download" tap on an audio-only currently-streaming track.
    /// `capOverride` is the per-download "Quality" option (§4); `nil`
    /// falls back to the Settings-level default.
    @discardableResult
    func download(
        _ ref: RemoteRef,
        kinds: Set<TrackKind>,
        capOverride: DownloadResolutionCap? = nil
    ) async -> MediaItem? {
        if let existing = library.existingItem(matching: ref.source) {
            states[ref.id] = .done
            queue.replaceRemote(matching: ref.source, with: existing)
            return existing
        }

        states[ref.id] = .downloading(nil)
        let cap = capOverride ?? settings.downloadResolutionCap
        let wanted = kinds.intersection(ref.availableKinds)

        do {
            // Audio and video are resolved+downloaded concurrently
            // (`async let`, not two sequential `await`s) — each involves
            // its own full YouTube stream-list resolution plus its own
            // file transfer, and there's no reason the video half has to
            // wait for the audio half to finish first.
            async let audioResult = fetchAudioIfWanted(ref, wanted: wanted)
            async let videoResult = fetchVideoIfWanted(ref, wanted: wanted, cap: cap)
            let (audioFile, videoFile) = try await (audioResult, videoResult)

            let artworkFile = await downloadArtwork(ref.thumbnailURL)

            let write = LibraryWrite(
                title: ref.title,
                author: ref.author,
                durationMS: ref.duration > 0 ? ref.duration * 1000 : nil,
                source: ref.source,
                audioFile: audioFile,
                videoFile: videoFile,
                artworkFile: artworkFile
            )
            let item = try library.addOrUpdate(write)
            states[ref.id] = .done
            // §4's "playback prefers the local copy automatically": if
            // this track (or another slot referencing the same source)
            // is sitting in the queue as `.remote`, swap it to `.library`
            // now rather than leaving it to keep re-resolving/streaming.
            queue.replaceRemote(matching: ref.source, with: item)
            return item
        } catch {
            WFLog.download.error("Download of \"\(ref.title, privacy: .public)\" (\(ref.id, privacy: .public)) failed: \(error.localizedDescription, privacy: .public)")
            states[ref.id] = .failed(error.localizedDescription)
            return nil
        }
    }

    /// Independently matches a *video* source for `ref` rather than
    /// assuming it's the same YouTube upload the audio side resolved to.
    /// Only meaningful for a Spotify-origin `ref`: a direct YouTube pick
    /// (`ref.source.origin == "youtube"`) is already the exact video the
    /// user selected in Search & Download, so re-matching it here would
    /// risk silently swapping in a *different* video than the one they
    /// tapped — that case returns `nil` and the caller keeps using `ref`
    /// as-is, same as before this method existed.
    private func resolveVideoSource(for ref: RemoteRef) async -> RemoteRef? {
        guard ref.source.origin == "spotify" || ref.source.spotifyID != nil else { return nil }

        let candidate = SearchCandidate(
            id: ref.id,
            origin: .youtube,
            title: ref.title,
            author: ref.author,
            rawTitle: ref.title,
            url: ref.source.url ?? "https://www.youtube.com/watch?v=\(ref.source.youtubeID ?? "")",
            youtubeID: ref.source.youtubeID,
            durationMS: ref.duration > 0 ? ref.duration * 1000 : nil
        )
        let target = MatchTarget(title: ref.title, author: ref.author, durationMS: candidate.durationMS, intent: .video)
        let videoPick = await Match.pickVideoSource(for: candidate, target: target, genius: acquireSettings.geniusClient)

        guard !videoPick.skip, let pick = videoPick.sourcePick else {
            WFLog.download.info("No distinct official video found for \"\(ref.title, privacy: .public)\" — using the audio-matched upload for the video download too.")
            return nil
        }
        guard let videoRef = pick.candidate.remoteRef(availableKinds: [.video]), videoRef.id != ref.id else {
            return nil
        }
        WFLog.download.debug("Video for \"\(ref.title, privacy: .public)\" independently matched to \(videoRef.id, privacy: .public) (audio was \(ref.id, privacy: .public)).")
        return videoRef
    }

    /// Resolves+downloads the audio half of `download(_:kinds:capOverride:)`,
    /// or `nil` if audio wasn't requested. Audio is never resolution-capped
    /// (§4), so `cap` is always `nil` here.
    private func fetchAudioIfWanted(
        _ ref: RemoteRef,
        wanted: Set<TrackKind>
    ) async throws -> (url: URL, media: MediaFile)? {
        guard wanted.contains(.audio) else { return nil }
        return try await fetchVariant(for: ref, kind: .audio, cap: nil, progressKey: ref.id)
    }

    /// Resolves+downloads the video half of `download(_:kinds:capOverride:)`,
    /// or `nil` if video wasn't requested. Independently (re-)matches the
    /// video source via `resolveVideoSource(for:)` rather than assuming
    /// the audio-matched upload is also the right video — see that
    /// method's doc comment for why a direct YouTube `ref` is left as-is.
    private func fetchVideoIfWanted(
        _ ref: RemoteRef,
        wanted: Set<TrackKind>,
        cap: DownloadResolutionCap?
    ) async throws -> (url: URL, media: MediaFile)? {
        guard wanted.contains(.video) else { return nil }
        let videoRef = await resolveVideoSource(for: ref) ?? ref
        return try await fetchVariant(for: videoRef, kind: .video, cap: cap, progressKey: ref.id)
    }

    /// Same resolve→fetch pair `download(_:kinds:capOverride:)` uses per
    /// kind, factored out so audio (never capped, §4) and video (capped)
    /// share the progress-reporting/`MediaFile`-building plumbing.
    ///
    /// `.video` can resolve to either a single already-muxed file
    /// (`Resolve.DownloadPlan.single`) or a separate video-only +
    /// audio-only pair (`.adaptive`) that needs combining — `AdaptiveFetch`
    /// handles that combine itself via `AVFoundation` (no bundled ffmpeg
    /// needed at all for this, unlike Shrink's re-encode, see `Mux.swift`).
    private func fetchVariant(
        for ref: RemoteRef,
        kind: TrackKind,
        cap: DownloadResolutionCap?,
        progressKey: String
    ) async throws -> (url: URL, media: MediaFile) {
        let plan = try await Resolve.downloadPlan(for: ref, kind: kind, cap: cap ?? .uncapped)
        let capLabel = (cap != nil && cap != .uncapped) ? cap?.label : nil

        switch plan {
        case .single(let variant):
            let fetch = Fetch(variant: variant)
            let url = try await fetch.run { [weak self] progress in
                Task { @MainActor in self?.states[progressKey] = .downloading(progress) }
            }
            let media = await fetch.mediaFile(downloadCap: capLabel)
            return (url, media)

        case .adaptive(let video, let audio):
            let adaptiveFetch = AdaptiveFetch(video: video, audio: audio)
            let url = try await adaptiveFetch.run { [weak self] progress in
                Task { @MainActor in self?.states[progressKey] = .downloading(progress) }
            }
            let media = await adaptiveFetch.mediaFile(downloadCap: capLabel)
            return (url, media)
        }
    }

    private func downloadArtwork(_ url: URL?) async -> URL? {
        guard let url else { return nil }
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("jpg")
        do {
            try data.write(to: destination)
            return destination
        } catch {
            return nil
        }
    }
}
