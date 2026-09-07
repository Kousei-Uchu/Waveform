import Foundation
import os

public enum FetchError: Error, LocalizedError, Sendable {
    case cancelled
    case noResumeData

    public var errorDescription: String? {
        switch self {
        case .cancelled: "Download cancelled."
        case .noResumeData: "Download can't be resumed — no resume data was saved."
        }
    }
}

/// Bytes-based download progress — callers format ("12.3 MB / 45.0 MB",
/// a 0...1 fraction, etc.) however suits the UI; `totalBytes` is `nil`
/// when the server doesn't report a content length.
public struct FetchProgress: Sendable, Equatable {
    public let bytesWritten: Int64
    public let totalBytes: Int64?

    public var fraction: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return Double(bytesWritten) / Double(totalBytes)
    }
}

/// Resumable, progress-reporting download that stream-copies a resolved
/// `Resolve.PickedVariant` straight to a local temp file — no decode, no
/// encode (§3). The caller (Search & Download screen / a download queue)
/// hands the resulting temp URL, together with `mediaFile(downloadCap:)`,
/// to `LibraryStore.addOrUpdate` (new item) or `.replaceFile` (Shrink) —
/// `LibraryStore` owns the actual move into `Audio/`/`Video/`, `Fetch`
/// never touches the library folder directly.
///
/// One `Fetch` instance per in-flight download. It holds whatever resume
/// data `URLSession` hands back on cancellation/failure so a transient
/// network drop doesn't mean re-fetching bytes already on disk —
/// mirroring what the old pipeline got "for free" from a persistent
/// `yt-dlp`/`aria2c` process (`server/services/ytdlp.js`'s
/// `speedArgs()`/`--concurrent-fragments`). `run(onProgress:)` is meant
/// to be called once per instance; make a fresh `Fetch` per download
/// attempt.
public actor Fetch {
    private let variant: Resolve.PickedVariant
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var resumeData: Data?
    private var progressHandler: (@Sendable (FetchProgress) -> Void)?
    private var continuation: CheckedContinuation<URL, Error>?

    public init(variant: Resolve.PickedVariant) {
        self.variant = variant
    }

    /// Downloads to a fresh temp file (named with `variant.container`'s
    /// extension so callers don't need to re-derive it) and returns its
    /// URL once complete.
    public func run(onProgress: (@Sendable (FetchProgress) -> Void)? = nil) async throws -> URL {
        progressHandler = onProgress
        let delegate = FetchSessionDelegate(owner: self)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        self.session = session

        WFLog.fetch.debug("Starting download (\(self.variant.codec, privacy: .public)/\(self.variant.container, privacy: .public)).")
        let start = Date()
        do {
            let url = try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let downloadTask = session.downloadTask(with: variant.url)
                self.task = downloadTask
                downloadTask.resume()
            }
            WFLog.fetch.debug("Download finished in \(Date().timeIntervalSince(start), format: .fixed(precision: 1))s.")
            return url
        } catch {
            WFLog.fetch.error("Download failed after \(Date().timeIntervalSince(start), format: .fixed(precision: 1))s: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    /// Cancels the in-flight download but preserves resume data (when the
    /// server supports byte ranges), so a later `resume()` can pick back
    /// up without re-fetching bytes already written.
    public func pause() {
        task?.cancel { [weak self] data in
            guard let self else { return }
            Task { await self.storeResumeData(data) }
        }
    }

    /// Resumes a previously-`pause()`d download. Throws `FetchError.noResumeData`
    /// if the server didn't support resuming (or nothing was paused).
    public func resume(onProgress: (@Sendable (FetchProgress) -> Void)? = nil) async throws -> URL {
        guard let resumeData, let session else { throw FetchError.noResumeData }
        progressHandler = onProgress ?? progressHandler

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let downloadTask = session.downloadTask(withResumeData: resumeData)
            self.task = downloadTask
            downloadTask.resume()
        }
    }

    /// Cancels outright — no resume data is kept, unlike `pause()`.
    public func cancel() {
        task?.cancel()
        failContinuation(FetchError.cancelled)
    }

    /// The `MediaFile` (§7) the caller should record once this download
    /// completes. Codec/container come from the resolved variant;
    /// `shrunk` always starts `false` on the download path (§3);
    /// `downloadCap` is supplied by the caller since `Fetch` itself
    /// doesn't know which cap (if any) was requested when the variant
    /// was picked.
    public func mediaFile(downloadCap: String?) -> MediaFile {
        MediaFile(codec: variant.codec, container: variant.container, shrunk: false, downloadCap: downloadCap)
    }

    // MARK: - Delegate callback bridge

    fileprivate func storeResumeData(_ data: Data?) {
        resumeData = data
    }

    fileprivate func handleProgress(bytesWritten: Int64, totalBytes: Int64?) {
        progressHandler?(FetchProgress(bytesWritten: bytesWritten, totalBytes: totalBytes))
    }

    /// `location` is a staged copy `FetchSessionDelegate` already moved
    /// out of the system's temp download slot (which gets deleted the
    /// instant the delegate callback returns, well before this actor hop
    /// could complete) — this method just renames it to carry the right
    /// file extension and hands the URL back to whoever's awaiting `run`.
    fileprivate func handleFinished(stagedFileURL: URL) {
        do {
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(variant.container)
            try FileManager.default.moveItem(at: stagedFileURL, to: destination)
            succeedContinuation(with: destination)
        } catch {
            failContinuation(error)
        }
    }

    fileprivate func handleFailed(_ error: Error) {
        failContinuation(error)
    }

    private func succeedContinuation(with url: URL) {
        continuation?.resume(returning: url)
        continuation = nil
    }

    private func failContinuation(_ error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}

/// Downloads and muxes a `Resolve.DownloadPlan.adaptive` pair: runs two
/// ordinary `Fetch` instances concurrently for the video-only and
/// audio-only halves, hands both finished files to `Mux` (an
/// `AVFoundation` passthrough export — no ffmpeg, see `Mux.swift`) for a
/// lossless combine once they're done, and cleans up the two
/// intermediate per-track temp files regardless of whether the mux
/// succeeds. One instance per in-flight adaptive download, same
/// contract as `Fetch` itself.
public actor AdaptiveFetch {
    private let video: Resolve.PickedVariant
    private let audio: Resolve.PickedVariant
    private var videoFetch: Fetch?
    private var audioFetch: Fetch?

    public init(video: Resolve.PickedVariant, audio: Resolve.PickedVariant) {
        self.video = video
        self.audio = audio
    }

    /// Runs both downloads concurrently, muxes the results, and returns
    /// the final `.mp4` file's URL. `onProgress` reports one combined
    /// bytes-written/bytes-total pair across both underlying files —
    /// callers (the Download UI) only ever show a single progress bar
    /// per track regardless of how many files that track involves under
    /// the hood.
    public func run(
        onProgress: (@Sendable (FetchProgress) -> Void)? = nil
    ) async throws -> URL {
        let videoFetch = Fetch(variant: video)
        let audioFetch = Fetch(variant: audio)
        self.videoFetch = videoFetch
        self.audioFetch = audioFetch

        let progress = CombinedFetchProgress()

        async let videoURL = videoFetch.run { bytes in
            Task { await progress.updateVideo(bytes, report: onProgress) }
        }
        async let audioURL = audioFetch.run { bytes in
            Task { await progress.updateAudio(bytes, report: onProgress) }
        }
        let (videoFile, audioFile) = try await (videoURL, audioURL)

        defer {
            try? FileManager.default.removeItem(at: videoFile)
            try? FileManager.default.removeItem(at: audioFile)
        }

        return try await Mux.mux(videoURL: videoFile, audioURL: audioFile)
    }

    /// Cancels both halves outright — mirrors `Fetch.cancel()`, no
    /// resume data kept for either.
    public func cancel() async {
        await videoFetch?.cancel()
        await audioFetch?.cancel()
    }

    /// The `MediaFile` the caller should record for a completed adaptive
    /// download. `codec` reflects the *video* stream's codec — matching
    /// what `MediaFile.codec` has always meant for `.video` kind, since
    /// the struct has nowhere to separately note the audio codec (the
    /// old progressive path never recorded one either). `container` is
    /// always `"mp4"`, since that's all `Mux` ever produces.
    public func mediaFile(downloadCap: String?) -> MediaFile {
        MediaFile(codec: video.codec, container: "mp4", shrunk: false, downloadCap: downloadCap)
    }
}

/// Actor-isolated accumulator so `AdaptiveFetch.run`'s two concurrent
/// `Fetch.run` progress callbacks — which can land on any thread — can
/// combine into one `FetchProgress` without a data race; `@Sendable`
/// closures can't otherwise safely share mutable state.
private actor CombinedFetchProgress {
    private var video: FetchProgress?
    private var audio: FetchProgress?

    func updateVideo(_ progress: FetchProgress, report: (@Sendable (FetchProgress) -> Void)?) {
        video = progress
        report?(combined)
    }

    func updateAudio(_ progress: FetchProgress, report: (@Sendable (FetchProgress) -> Void)?) {
        audio = progress
        report?(combined)
    }

    private var combined: FetchProgress {
        let bytesWritten = (video?.bytesWritten ?? 0) + (audio?.bytesWritten ?? 0)
        let totalBytes: Int64?
        if let videoTotal = video?.totalBytes, let audioTotal = audio?.totalBytes {
            totalBytes = videoTotal + audioTotal
        } else {
            totalBytes = nil
        }
        return FetchProgress(bytesWritten: bytesWritten, totalBytes: totalBytes)
    }
}

/// `URLSessionDownloadDelegate` callbacks arrive off-actor and can't be
/// satisfied by an actor directly (actors can't subclass `NSObject`, which
/// delegate conformance requires) — this thin `NSObject` bridges each
/// callback into `Fetch`'s actor isolation via `Task { await ... }`.
private final class FetchSessionDelegate: NSObject, URLSessionDownloadDelegate {
    private weak var owner: Fetch?

    init(owner: Fetch) {
        self.owner = owner
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
        Task { await owner?.handleProgress(bytesWritten: totalBytesWritten, totalBytes: total) }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // The system deletes `location` as soon as this method returns,
        // so stage it to a stable path synchronously, right here, before
        // handing off to the actor.
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.moveItem(at: location, to: staging)
            Task { await owner?.handleFinished(stagedFileURL: staging) }
        } catch {
            Task { await owner?.handleFailed(error) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // Success is already handled by `didFinishDownloadingTo` — this
        // only fires with a non-nil error on failure/cancellation.
        guard let error else { return }
        let nsError = error as NSError
        if let data = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            Task { await owner?.storeResumeData(data) }
        }
        Task { await owner?.handleFailed(error) }
    }
}
