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

    /// Surfaced alongside `states` (not merged into it) when Conservative
    /// Matching (§8 Settings) skips a kind rather than silently
    /// downloading a low-confidence match — the confident kind(s), if
    /// any, still proceed and land in `states` as usual; this is purely
    /// advisory for the UI to show a "download anyway?" prompt for the
    /// skipped one. Cleared automatically once a fully-confident (or
    /// forced) attempt for the same `ref.id` succeeds.
    struct ConfidenceIssue: Equatable {
        let kind: TrackKind
        let message: String
    }

    @Published private(set) var states: [String: State] = [:] // keyed by RemoteRef.id
    @Published private(set) var confidenceIssues: [String: ConfidenceIssue] = [:] // keyed by RemoteRef.id

    private let library: LibraryStore
    private let settings: PlaybackSettingsStore
    /// Used only to swap a now-downloaded track's queue entries from
    /// `.remote` to `.library` in place once a download completes (§4:
    /// "playback prefers the local copy automatically") — see
    /// `PlaybackQueue.replaceRemote(matching:with:)`'s doc comment for
    /// why that's safe to do without disrupting anything currently
    /// playing.
    private let queue: PlaybackQueue
    /// Read for `.geniusClient` (used by `resolveVideoSource(for:)` below
    /// so a Spotify-origin download's video half gets independently
    /// (optionally Genius-assisted) matched rather than blindly reusing
    /// whichever video the audio half matched to) and for
    /// `.conservativeMatching` (§8: whether a low-confidence match should
    /// be downloaded anyway or held back for confirmation).
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
    ///
    /// `forceKinds` bypasses Conservative Matching's confidence check for
    /// the listed kinds — how a caller re-invokes `download` after the
    /// person taps "Download Anyway" on a `confidenceIssues` prompt for
    /// this same `ref.id`. Empty (the default) for a normal, first-time
    /// download request.
    @discardableResult
    func download(
        _ ref: RemoteRef,
        kinds: Set<TrackKind>,
        capOverride: DownloadResolutionCap? = nil,
        forceKinds: Set<TrackKind> = []
    ) async -> MediaItem? {
        if let existing = library.existingItem(matching: ref.source) {
            states[ref.id] = .done
            confidenceIssues[ref.id] = nil
            queue.replaceRemote(matching: ref.source, with: existing)
            return existing
        }

        var wanted = kinds.intersection(ref.availableKinds)
        guard !wanted.isEmpty else {
            states[ref.id] = .failed("Nothing to download.")
            return nil
        }

        // Conservative Matching (§8): a video match is only known once
        // it's actually (re-)resolved, so that resolve happens up front,
        // before any bytes are fetched — otherwise a low-confidence video
        // would only be discovered *after* paying for its download.
        // `fetchVideoIfWanted` below reuses this result rather than
        // resolving a second time.
        var resolvedVideoRef: RemoteRef?
        if wanted.contains(.video) {
            resolvedVideoRef = await resolveVideoSource(for: ref)
        }
        // A `nil` `resolvedVideoRef` means "no distinct video match was
        // needed/found — reuse the audio-matched upload" (see
        // `resolveVideoSource`'s doc comment), which is a deliberate
        // choice, not a low-confidence one, so it's trusted (`true`) same
        // as before Conservative Matching existed.
        let videoConfident = resolvedVideoRef?.matchConfident ?? true

        confidenceIssues[ref.id] = nil
        if acquireSettings.conservativeMatching {
            let audioUnconfident = wanted.contains(.audio) && !ref.matchConfident && !forceKinds.contains(.audio)
            let videoUnconfident = wanted.contains(.video) && !videoConfident && !forceKinds.contains(.video)

            if audioUnconfident { wanted.remove(.audio) }
            if videoUnconfident { wanted.remove(.video) }

            if wanted.isEmpty {
                // Neither requested kind cleared the confidence floor
                // (and neither was force-approved) — nothing left to
                // download at all.
                let message = kinds.count > 1
                    ? "No confident audio or video match was found for this track."
                    : "No confident \(kinds.contains(.video) ? "video" : "audio") match was found for this track."
                states[ref.id] = .failed(message)
                confidenceIssues[ref.id] = ConfidenceIssue(kind: audioUnconfident ? .audio : .video, message: message)
                return nil
            }
            if audioUnconfident || videoUnconfident {
                // One kind is confident enough to proceed — download it
                // below, but still flag the skipped one so the UI can
                // offer "Download Anyway" rather than silently dropping it.
                let skippedKind: TrackKind = audioUnconfident ? .audio : .video
                confidenceIssues[ref.id] = ConfidenceIssue(
                    kind: skippedKind,
                    message: "No confident \(skippedKind == .audio ? "audio" : "video") match was found — downloaded the \(skippedKind == .audio ? "video" : "audio") only."
                )
            }
        }

        states[ref.id] = .downloading(nil)
        let cap = capOverride ?? settings.downloadResolutionCap
        let progressCombiner = TrackDownloadProgressCombiner()

        do {
            // Audio and video are resolved+downloaded concurrently
            // (`async let`, not two sequential `await`s) — each involves
            // its own full YouTube stream-list resolution plus its own
            // file transfer, and there's no reason the video half has to
            // wait for the audio half to finish first.
            //
            // Both legs report through `progressCombiner` rather than
            // writing `states[ref.id]` directly — they used to write the
            // same dictionary key independently, so whichever leg's
            // callback fired most recently would stomp the other's
            // progress, making the bar flicker between two unrelated
            // fractions instead of showing one coherent combined value.
            async let audioResult = fetchAudioIfWanted(ref, wanted: wanted, progress: progressCombiner)
            async let videoResult = fetchVideoIfWanted(ref, wanted: wanted, cap: cap, progress: progressCombiner, preresolvedVideoRef: resolvedVideoRef)
            let (audioFile, videoFile) = try await (audioResult, videoResult)

            let artworkFile = await downloadArtwork(ref.thumbnailURL)

            let write = LibraryWrite(
                title: ref.title,
                author: ref.author,
                durationMS: ref.duration > 0 ? ref.duration * 1000 : nil,
                source: ref.source,
                match: MediaMatch(
                    audio: wanted.contains(.audio) ? ref.matchNote : nil,
                    // A distinct video match reports its own `MatchNote`;
                    // reusing the audio upload for video reports the
                    // audio's note too, since that's genuinely what was
                    // matched against for the video file in that case.
                    video: wanted.contains(.video) ? (resolvedVideoRef?.matchNote ?? ref.matchNote) : nil
                ),
                albumMeta: ref.albumMeta,
                authorMeta: ref.authorMeta,
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
            spotifyID: ref.source.spotifyID,
            isrc: ref.source.isrc,
            durationMS: ref.duration > 0 ? ref.duration * 1000 : nil,
            albumName: ref.albumMeta["name"]?.stringValue,
            artists: ArtistRef.array(from: ref.authorMeta),
            albumMeta: ref.albumMeta
        )
        let target = MatchTarget(title: ref.title, author: ref.author, durationMS: candidate.durationMS, intent: .video)
        let videoPick = await Match.pickVideoSource(for: candidate, target: target, genius: acquireSettings.geniusClient)

        guard !videoPick.skip, let pick = videoPick.sourcePick else {
            WFLog.download.info("No distinct official video found for \"\(ref.title, privacy: .public)\" — using the audio-matched upload for the video download too.")
            return nil
        }
        guard let videoRef = pick.candidate.remoteRef(
            availableKinds: [.video],
            matchConfident: pick.confident,
            matchNote: Match.matchNote(for: pick)
        ), videoRef.id != ref.id else {
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
        wanted: Set<TrackKind>,
        progress: TrackDownloadProgressCombiner
    ) async throws -> (url: URL, media: MediaFile)? {
        guard wanted.contains(.audio) else { return nil }
        return try await fetchVariant(for: ref, kind: .audio, cap: nil, progressKey: ref.id, progressRole: .audio, progress: progress)
    }

    /// Resolves+downloads the video half of `download(_:kinds:capOverride:)`,
    /// or `nil` if video wasn't requested. `preresolvedVideoRef` is
    /// whatever `download(_:kinds:capOverride:forceKinds:)` already
    /// learned from `resolveVideoSource(for:)` while deciding Conservative
    /// Matching — passed through here so the video source isn't matched
    /// a second time; `nil` there means "no distinct video found," same
    /// as a `nil` return from `resolveVideoSource` itself, so `ref` is
    /// used as-is.
    private func fetchVideoIfWanted(
        _ ref: RemoteRef,
        wanted: Set<TrackKind>,
        cap: DownloadResolutionCap?,
        progress: TrackDownloadProgressCombiner,
        preresolvedVideoRef: RemoteRef?
    ) async throws -> (url: URL, media: MediaFile)? {
        guard wanted.contains(.video) else { return nil }
        let videoRef = preresolvedVideoRef ?? ref
        return try await fetchVariant(for: videoRef, kind: .video, cap: cap, progressKey: ref.id, progressRole: .video, progress: progress)
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
    ///
    /// Both branches now go through `SegmentedFetch` rather than a plain
    /// `Fetch` — see `Fetch.swift`'s doc comment on `SegmentedFetch` for
    /// why (concurrent byte-range chunks instead of one connection per
    /// file; falls back to single-stream automatically when the CDN
    /// doesn't support ranges).
    ///
    /// `progressRole` distinguishes this leg (audio vs. video) purely for
    /// logging — `progress` (the shared `TrackDownloadProgressCombiner`)
    /// is what actually merges both legs' byte counts into one coherent
    /// `states[progressKey]` update, rather than each leg overwriting the
    /// other's independently-tracked progress.
    private func fetchVariant(
        for ref: RemoteRef,
        kind: TrackKind,
        cap: DownloadResolutionCap?,
        progressKey: String,
        progressRole: TrackDownloadProgressCombiner.Role,
        progress: TrackDownloadProgressCombiner
    ) async throws -> (url: URL, media: MediaFile) {
        let plan = try await Resolve.downloadPlan(for: ref, kind: kind, cap: cap ?? .uncapped)
        let capLabel = (cap != nil && cap != .uncapped) ? cap?.label : nil

        switch plan {
        case .single(let variant):
            let fetch = SegmentedFetch(variant: variant)
            let url = try await fetch.run { fetchProgress in
                Task { await progress.update(role: progressRole, progress: fetchProgress) { combined in
                    Task { @MainActor [weak self] in self?.states[progressKey] = .downloading(combined) }
                } }
            }
            let media = await fetch.mediaFile(downloadCap: capLabel)
            return (url, media)

        case .adaptive(let video, let audio):
            let adaptiveFetch = AdaptiveFetch(video: video, audio: audio)
            let url = try await adaptiveFetch.run { fetchProgress in
                Task { await progress.update(role: progressRole, progress: fetchProgress) { combined in
                    Task { @MainActor [weak self] in self?.states[progressKey] = .downloading(combined) }
                } }
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
