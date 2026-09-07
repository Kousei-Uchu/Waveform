import Foundation
import YouTubeKit
import os

public enum ResolveError: Error, LocalizedError, Sendable {
    case notYouTube(RemoteRef)
    case noStreamAvailable(kind: TrackKind, videoID: String)

    public var errorDescription: String? {
        switch self {
        case .notYouTube(let ref):
            "\"\(ref.title)\" has no YouTube video backing it — nothing to resolve a stream for."
        case .noStreamAvailable(let kind, let videoID):
            "No playable \(kind.rawValue) stream found for video \(videoID)."
        }
    }
}

/// Resolves a `RemoteRef` into a directly-playable URL using YouTubeKit.
public enum Resolve {

    /// A picked stream variant plus the codec/container information
    /// Fetch.swift needs when constructing a MediaFile.
    public struct PickedVariant: Sendable {
        public let url: URL
        public let codec: String
        public let container: String
    }

    /// What `streamTarget(for:kind:)` hands back for live playback:
    /// `url` is the primary input a `PlaybackEngine` loads as usual,
    /// `audioSlaveURL` — non-nil only for a `.video` request that got
    /// picked as a separate adaptive video-only + audio-only pair rather
    /// than a pre-muxed progressive stream — is an *additional* input the
    /// engine attaches as an audio track alongside the primary video,
    /// with no local muxing/download involved (VLCKit plays the two
    /// URLs as one synced item). `.audio` requests never populate this.
    public struct StreamTarget: Sendable {
        public let url: URL
        public let audioSlaveURL: URL?

        public init(url: URL, audioSlaveURL: URL? = nil) {
            self.url = url
            self.audioSlaveURL = audioSlaveURL
        }
    }

    /// Two ways `downloadPlan(for:kind:cap:)` can resolve a `.video`
    /// request: either one already-muxed file to stream-copy as-is
    /// (a progressive stream, or a video-only stream with no audio at
    /// all), or a separate video-only + audio-only pair that `Mux.swift`
    /// combines after both are fetched. `.audio` requests are always
    /// `.single`.
    public enum DownloadPlan: Sendable {
        case single(PickedVariant)
        case adaptive(video: PickedVariant, audio: PickedVariant)
    }

    // MARK: - Streaming

    /// Resolves the best playable stream target for the requested kind.
    ///
    /// Resolution happens fresh on every call because YouTube's direct
    /// googlevideo URLs are short-lived.
    public static func streamTarget(
        for ref: RemoteRef,
        kind: TrackKind
    ) async throws -> StreamTarget {

        let videoID = try youTubeVideoID(for: ref)
        let streams = try await YouTube(videoID: videoID).streams

        switch kind {

        case .audio:
            guard let stream = streams
                .filterAudioOnly()
                .filter({ $0.isNativelyPlayable })
                .highestAudioBitrateStream()
            else {
                throw ResolveError.noStreamAvailable(
                    kind: .audio,
                    videoID: videoID
                )
            }

            return StreamTarget(url: stream.url)

        case .video:
            // Prefer a separate video-only + audio-only adaptive pair,
            // handed to the engine as a primary URL plus an audio slave
            // (§4 v2 enhancement, now live) — this is what lets live
            // playback reach resolutions/codecs YouTube's pre-muxed
            // progressive formats never offer (progressive tops out well
            // below most adaptive resolutions and is never AV1), with no
            // on-disk muxing needed since VLCKit decodes and syncs the
            // two URLs itself at playback time. Unlike the *download*
            // path's `adaptivePlan` (see its doc comment), this isn't
            // restricted to any particular codec pairing — VLCKit
            // already plays AV1/VP9/Opus natively, so there's no
            // AVFoundation-can't-read-this-codec constraint here.
            if let video = streams
                .filterVideoOnly()
                .filter({ $0.isNativelyPlayable })
                .highestResolutionStream(),
               let audio = streams
                .filterAudioOnly()
                .filter({ $0.isNativelyPlayable })
                .highestAudioBitrateStream() {

                return StreamTarget(url: video.url, audioSlaveURL: audio.url)
            }

            // Fall back to a progressive stream if adaptive streams
            // weren't both available for some reason.
            if let progressive = streams
                .filterVideoAndAudio()
                .filter({ $0.isNativelyPlayable })
                .highestResolutionStream() {

                return StreamTarget(url: progressive.url)
            }

            // Last resort: a video-only adaptive stream with no audio
            // pairing at all.
            guard let stream = streams
                .filterVideoOnly()
                .filter({ $0.isNativelyPlayable })
                .highestResolutionStream()
            else {
                throw ResolveError.noStreamAvailable(
                    kind: .video,
                    videoID: videoID
                )
            }

            return StreamTarget(url: stream.url)
        }
    }

    // MARK: - Download

    /// Selects the best available download strategy at or below the
    /// requested resolution cap: a single already-muxed file to
    /// stream-copy as-is, or (for `.video`, when an H.264+AAC adaptive
    /// pair is available) a separate video-only + audio-only pair for
    /// `Mux.swift` to combine after Fetch downloads both.
    ///
    /// No transcoding occurs in the resolve step either way — variants
    /// are copied, never re-encoded, by Fetch.swift/Mux.swift.
    public static func downloadPlan(
        for ref: RemoteRef,
        kind: TrackKind,
        cap: DownloadResolutionCap
    ) async throws -> DownloadPlan {

        let videoID = try youTubeVideoID(for: ref)
        let streams = try await YouTube(videoID: videoID).streams

        switch kind {

        case .audio:
            guard let stream = streams
                .filterAudioOnly()
                .highestAudioBitrateStream()
            else {
                WFLog.resolve.error("No playable audio stream for \(videoID, privacy: .public).")
                throw ResolveError.noStreamAvailable(
                    kind: .audio,
                    videoID: videoID
                )
            }

            return .single(picked(from: stream))

        case .video:
            // Prefer a separate H.264 video-only + AAC audio-only
            // adaptive pair over YouTube's pre-muxed progressive
            // formats — progressive tops out well below most adaptive
            // resolutions, so reaching for it first (the old default)
            // capped every video download at whatever progressive
            // happened to offer. `Mux.swift` combines the pair
            // losslessly (stream copy, no re-encode) once both are on
            // disk — see `adaptivePlan`'s doc comment for why this is
            // restricted to H.264/AAC specifically rather than
            // AV1/VP9/Opus too.
            if let plan = adaptivePlan(from: streams, cap: cap) {
                return plan
            }

            // Fall back to a progressive (video+audio combined) stream
            // when no muxable adaptive pair was available.
            let progressive = streams.filterVideoAndAudio()
            let progressiveUnderCap = filteredByCap(progressive, cap: cap)
            let progressivePool = progressiveUnderCap.isEmpty ? progressive : progressiveUnderCap

            if let stream = highestResolution(in: progressivePool) {
                return .single(picked(from: stream))
            }

            WFLog.resolve.warning("No progressive video+audio stream for \(videoID, privacy: .public) — falling back to a video-only stream; this download will have no audio track.")

            let candidates = streams.filterVideoOnly()
            let underCap = filteredByCap(candidates, cap: cap)

            // If nothing exists under the cap, use the smallest available
            // video stream rather than refusing the download.
            let pool = underCap.isEmpty ? candidates : underCap

            // Prefer AV1 where available — this is a single silent
            // file, no muxing/AVFoundation involved, so the AV1-can't-
            // be-muxed-without-ffmpeg restriction above doesn't apply
            // here.
            let av1Streams = pool.filter {
                $0.videoCodec == .av1
            }

            let ranked = av1Streams.isEmpty ? pool : av1Streams

            guard let stream = highestResolution(in: ranked) else {
                WFLog.resolve.error("No playable video stream at all for \(videoID, privacy: .public).")
                throw ResolveError.noStreamAvailable(
                    kind: .video,
                    videoID: videoID
                )
            }

            return .single(picked(from: stream))
        }
    }

    /// Picks the best H.264 (`avc1`) video-only stream (highest
    /// resolution, under `cap`) and pairs it with the best AAC (`mp4a`)
    /// audio-only stream (highest bitrate, never capped — matching how
    /// audio downloads have never been capped elsewhere in this file).
    /// `nil` when either half doesn't exist, so the caller can fall
    /// through to a progressive stream instead.
    ///
    /// Deliberately narrower than "any video-only + any audio-only
    /// pairing": `Mux.swift` combines the two via `AVFoundation`
    /// (`AVAssetExportSession`'s `.passthrough` preset) rather than
    /// ffmpeg, specifically so this doesn't need the not-always-
    /// buildable bundled ffmpeg dependency `Shrink.swift` still carries
    /// (§9) — but `AVFoundation` can only read codecs Apple's own
    /// frameworks understand, which for YouTube's adaptive formats means
    /// H.264 video and AAC audio only; it has no VP9/AV1/Opus/WebM
    /// demuxer the way VLCKit does. An AV1/VP9 video-only stream still
    /// can't be losslessly combined with a separate audio track on the
    /// *download* path without ffmpeg, so it's left out of this pool
    /// entirely (it falls through to progressive, or the silent
    /// video-only last resort below, both of which are single files and
    /// never need muxing). Live *streaming* isn't limited this way —
    /// see `streamTarget`'s doc comment — since VLCKit decodes both
    /// halves itself and never writes a combined file to disk.
    private static func adaptivePlan(
        from streams: [YouTubeKit.Stream],
        cap: DownloadResolutionCap
    ) -> DownloadPlan? {

        let videoOnly = streams.filterVideoOnly().filter { $0.videoCodec == .avc1 }
        let videoUnderCap = filteredByCap(videoOnly, cap: cap)
        let videoPool = videoUnderCap.isEmpty ? videoOnly : videoUnderCap

        let audioOnly = streams.filterAudioOnly().filter { $0.audioCodec == .mp4a }

        guard
            let videoStream = highestResolution(in: videoPool),
            let audioStream = audioOnly.highestAudioBitrateStream()
        else {
            return nil
        }

        return .adaptive(video: picked(from: videoStream), audio: picked(from: audioStream))
    }

    // MARK: - Private

    private static func highestResolution(
        in streams: [YouTubeKit.Stream]
    ) -> YouTubeKit.Stream? {

        streams.max {
            ($0.videoResolution ?? 0) < ($1.videoResolution ?? 0)
        }
    }

    /// Streams at or below `cap`'s resolution, or every stream unfiltered
    /// when `cap == .uncapped`. Shared by the progressive and video-only
    /// pools in `downloadVariant`'s `.video` case so both respect the
    /// same resolution cap.
    private static func filteredByCap(
        _ streams: [YouTubeKit.Stream],
        cap: DownloadResolutionCap
    ) -> [YouTubeKit.Stream] {
        guard cap != .uncapped else { return streams }
        return streams.filter {
            guard let resolution = $0.videoResolution else { return false }
            return resolution <= cap.rawValue
        }
    }

    private static func picked(
        from stream: YouTubeKit.Stream
    ) -> PickedVariant {

        PickedVariant(
            url: stream.url,
            codec: normalizedCodec(stream),
            container: stream.fileExtension.rawValue
        )
    }

    /// Converts YouTubeKit's typed codec representation into the short
    /// codec family names used by Waveform's MediaFile model.
    private static func normalizedCodec(
        _ stream: YouTubeKit.Stream
    ) -> String {

        if let videoCodec = stream.videoCodec {
            switch videoCodec {
            case .av1:
                return "av1"

            case .vp9:
                return "vp9"

            case .avc1:
                return "h264"

            case .mp4v:
                return "mp4v"

            case .unknown(let codec):
                return codec.lowercased()
            }
        }

        if let audioCodec = stream.audioCodec {
            switch audioCodec {
            case .opus:
                return "opus"

            case .mp4a:
                return "aac"

            case .ec3:
                return "ec3"

            case .ac3:
                return "ac3"

            case .unknown(let codec):
                return codec.lowercased()
            }
        }

        return "unknown"
    }

    private static func youTubeVideoID(
        for ref: RemoteRef
    ) throws -> String {

        guard ref.id.hasPrefix("youtube:") else {
            throw ResolveError.notYouTube(ref)
        }

        return String(
            ref.id.dropFirst("youtube:".count)
        )
    }
}
