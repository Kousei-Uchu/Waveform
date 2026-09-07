//
//  MuxError.swift
//  WaveformBackendKit
//
//  Created by Aiden McGovern (School) on 5/9/2026.
//


import Foundation
import AVFoundation
import CoreMedia

public enum MuxError: Error, LocalizedError, Sendable {
    case missingSourceFile
    case noTracksFound
    case exportFailed(String)
    case exportCancelled

    public var errorDescription: String? {
        switch self {
        case .missingSourceFile: "One of the files to mux doesn't exist on disk."
        case .noTracksFound: "Couldn't find a usable video or audio track in one of the source files."
        case .exportFailed(let message): "Muxing failed: \(message)"
        case .exportCancelled: "Muxing was cancelled."
        }
    }
}

/// Losslessly combines a separately-downloaded video-only file and
/// audio-only file into one playable file — the step
/// `Resolve.downloadPlan(for:kind:cap:)`'s `.adaptive` case exists for,
/// used by `AdaptiveFetch` (`Fetch.swift`) once both halves have
/// finished downloading.
///
/// **Deliberately built on `AVFoundation`, not ffmpeg.** `Shrink.swift`
/// still needs a bundled ffmpeg for its actual re-encode (AV1/Opus,
/// which `AVFoundation` can't produce), but *this* job is pure
/// container-level repackaging — no re-encode at all — which
/// `AVMutableComposition` + `AVAssetExportSession`'s `.passthrough`
/// preset already does natively: no extra dependency, no `BuildFFmpeg`
/// step (§9), nothing to link. `AVAssetExportPresetPassthrough`
/// specifically means "repackage the existing samples as-is," the same
/// stream-copy contract `Shrink`'s ffmpeg `-c copy` would have been.
///
/// The tradeoff this buys: `AVFoundation` can only *read* codecs
/// Apple's own frameworks understand — it has no VP9/AV1/Opus/WebM
/// demuxer the way VLCKit does. So `Resolve.adaptivePlan` only ever
/// builds a `.adaptive` plan (the only case that reaches this type) out
/// of an H.264 (`avc1`) video-only + AAC (`mp4a`) audio-only pairing —
/// see that method's doc comment for the full reasoning. An AV1/VP9
/// video-only stream still can't be combined with a separate audio
/// track on the *download* path this way; it falls back to a
/// progressive stream instead. Live *streaming* isn't limited this way
/// at all — see `Resolve.streamTarget` — since VLCKit decodes both
/// halves itself and never writes a combined file to disk.
public enum Mux {

    /// Composes `videoURL`'s video track and `audioURL`'s audio track
    /// into one `.mp4` file via a passthrough export (no re-encode).
    public static func mux(videoURL: URL, audioURL: URL) async throws -> URL {
        guard FileManager.default.fileExists(atPath: videoURL.path),
              FileManager.default.fileExists(atPath: audioURL.path)
        else {
            throw MuxError.missingSourceFile
        }

        let videoAsset = AVURLAsset(url: videoURL)
        let audioAsset = AVURLAsset(url: audioURL)

        guard
            let videoTrack = try await videoAsset.loadTracks(withMediaType: .video).first,
            let audioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first
        else {
            throw MuxError.noTracksFound
        }

        let composition = AVMutableComposition()
        let compositionVideoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        )
        let compositionAudioTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        )

        let videoDuration = try await videoAsset.load(.duration)
        let audioDuration = try await audioAsset.load(.duration)

        try compositionVideoTrack?.insertTimeRange(
            CMTimeRange(start: .zero, duration: videoDuration),
            of: videoTrack,
            at: .zero
        )
        try compositionAudioTrack?.insertTimeRange(
            CMTimeRange(start: .zero, duration: audioDuration),
            of: audioTrack,
            at: .zero
        )

        guard let exportSession = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetPassthrough
        ) else {
            throw MuxError.exportFailed("Couldn't create an export session for the combined asset.")
        }

        let destination = temporaryDestination()
        exportSession.outputURL = destination
        exportSession.outputFileType = .mp4

        // `exportAsynchronously(completionHandler:)` rather than the
        // newer iOS 18 `export(to:as:) async throws` — this package's
        // deployment target is iOS 17/macOS 14 (Package.swift), and the
        // older completion-handler API is still fully functional there
        // (just deprecated on newer SDKs), wrapped in a continuation to
        // fit this file's async/await style, same pattern `Fetch.swift`
        // already uses to bridge `URLSessionDownloadDelegate`.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            exportSession.exportAsynchronously {
                continuation.resume()
            }
        }

        switch exportSession.status {
        case .completed:
            return destination
        case .cancelled:
            throw MuxError.exportCancelled
        default:
            throw MuxError.exportFailed(exportSession.error?.localizedDescription ?? "Unknown export failure.")
        }
    }

    private static func temporaryDestination() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")
    }
}