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

/// Resumable, progress-reporting single-connection download that
/// stream-copies a resolved `Resolve.PickedVariant` straight to a local
/// temp file — no decode, no encode (§3).
///
/// This is no longer the type callers reach for directly — use
/// `SegmentedFetch`, which downloads several byte-range chunks of the
/// same variant concurrently for real throughput, and falls back to a
/// plain `Fetch` (this type) automatically when the server doesn't
/// support ranges. `Fetch` still owns `pause()`/`resume()` via
/// `URLSessionDownloadTask`'s native resume-data mechanism — that part
/// of the old single-stream behavior is preserved for the fallback path
/// and for anything (e.g. an existing paused download) that predates
/// segmentation.
///
/// One `Fetch` instance per in-flight download. `run(onProgress:)` is
/// meant to be called once per instance; make a fresh `Fetch` per
/// download attempt.
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
            WFLog.fetch.debug("Download finished (\(self.variant.codec, privacy: .public)/\(self.variant.container, privacy: .public)) in \(Date().timeIntervalSince(start), format: .fixed(precision: 1))s.")
            return url
        } catch {
            WFLog.fetch.error("Download failed (\(self.variant.codec, privacy: .public)/\(self.variant.container, privacy: .public)) after \(Date().timeIntervalSince(start), format: .fixed(precision: 1))s: \(error.localizedDescription, privacy: .public)")
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

/// Splits a download into N concurrent byte-range chunks — the same trick
/// aria2c's `--concurrent-fragments` used in the old pipeline (see the
/// comment that used to live on `Fetch`). A single `URLSessionDownloadTask`
/// (what `Fetch` does alone) is throttled to whatever one connection to
/// the CDN can sustain; several concurrent range requests to the same host
/// routinely pull several times that aggregate throughput, especially
/// against `googlevideo.com`-style CDNs that cap per-connection speed well
/// below real link bandwidth.
///
/// This is now the type every download path should construct — both the
/// progressive (`.single`) path in `DownloadManager` and each half of
/// `AdaptiveFetch`. It falls back to a plain `Fetch` (no segmentation)
/// internally if the server doesn't advertise range support, doesn't
/// report a content length, or the file is too small for segmenting to
/// help.
///
/// No per-segment resume support yet — `pause()`/`resume()` semantics
/// from `Fetch` don't carry over to segmented downloads; `cancel()` is
/// outright, same as `Fetch.cancel()`.
public actor SegmentedFetch {
    private let variant: Resolve.PickedVariant
    private let segmentCount: Int
    private let minimumBytesToSegment: Int64

    private var fallback: Fetch?
    private var isCancelled = false

    public init(
        variant: Resolve.PickedVariant,
        segmentCount: Int = 6,
        minimumBytesToSegment: Int64 = 1 * 1024 * 1024 // 8 MB
    ) {
        self.variant = variant
        self.segmentCount = max(1, segmentCount)
        self.minimumBytesToSegment = minimumBytesToSegment
    }

    public func run(onProgress: (@Sendable (FetchProgress) -> Void)? = nil) async throws -> URL {
        guard let (totalBytes, supportsRanges) = try await probeRangeSupport(),
              supportsRanges,
              totalBytes >= minimumBytesToSegment,
              segmentCount > 1 else {
            WFLog.fetch.debug("Server doesn't support ranges (or file too small) — falling back to single-stream download.")
            let single = Fetch(variant: variant)
            fallback = single
            return try await single.run(onProgress: onProgress)
        }

        WFLog.fetch.debug("Range support confirmed (\(totalBytes) bytes, \(self.variant.codec, privacy: .public)/\(self.variant.container, privacy: .public)) — splitting into \(self.segmentCount) segments.")

        let ranges = byteRanges(totalBytes: totalBytes, segmentCount: segmentCount)
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(variant.container)

        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        let progress = SegmentedProgressTracker(totalBytes: totalBytes)
        let start = Date()

        try await withThrowingTaskGroup(of: Void.self) { group in
            for range in ranges {
                group.addTask {
                    try await self.downloadSegment(range: range, into: handle, progress: progress, onProgress: onProgress)
                }
            }
            try await group.waitForAll()
        }

        if isCancelled { throw FetchError.cancelled }
        WFLog.fetch.debug("Segmented download finished (\(self.variant.codec, privacy: .public)/\(self.variant.container, privacy: .public)) in \(Date().timeIntervalSince(start), format: .fixed(precision: 1))s.")
        return destination
    }

    public func cancel() async {
        isCancelled = true
        await fallback?.cancel()
    }

    /// Same construction `Fetch.mediaFile(downloadCap:)` does — kept
    /// available here so `DownloadManager` doesn't need to know whether a
    /// given download actually segmented or fell back to plain `Fetch`.
    public func mediaFile(downloadCap: String?) -> MediaFile {
        MediaFile(codec: variant.codec, container: variant.container, shrunk: false, downloadCap: downloadCap)
    }

    // MARK: - Private

    private func downloadSegment(
        range: ByteRange,
        into handle: FileHandle,
        progress: SegmentedProgressTracker,
        onProgress: (@Sendable (FetchProgress) -> Void)?
    ) async throws {
        var request = URLRequest(url: variant.url)
        request.setValue("bytes=\(range.start)-\(range.end)", forHTTPHeaderField: "Range")

        // One shot per segment rather than iterating byte-by-byte:
        // `bytes(for:)`'s `AsyncSequence` awaits per single byte, and
        // Swift concurrency's per-iteration overhead at that granularity
        // dwarfs the actual network transfer time — segmenting into 4
        // connections was still bottlenecked on that loop, not the CDN.
        // A ~15-25MB chunk held briefly in memory is a non-issue; this is
        // 1/N of the file, not the whole thing.
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 206 else {
            throw FetchError.noResumeData // server ignored the Range request — caller should retry unsegmented
        }

        try await write(data, at: range.start, to: handle)
        if isCancelled { throw FetchError.cancelled }
        await progress.add(bytesWritten: Int64(data.count), report: onProgress)
    }

    private func write(_ data: Data, at offset: Int64, to handle: FileHandle) async throws {
        try handle.seek(toOffset: UInt64(offset))
        try handle.write(contentsOf: data)
    }

    private struct ByteRange {
        let start: Int64
        let end: Int64
    }

    private func byteRanges(totalBytes: Int64, segmentCount: Int) -> [ByteRange] {
        let chunkSize = totalBytes / Int64(segmentCount)
        var ranges: [ByteRange] = []
        var start: Int64 = 0
        for i in 0..<segmentCount {
            let end = (i == segmentCount - 1) ? totalBytes - 1 : start + chunkSize - 1
            ranges.append(ByteRange(start: start, end: end))
            start = end + 1
        }
        return ranges
    }

    /// A HEAD request checks both the total size and whether the server
    /// actually honors `Range` (via `Accept-Ranges: bytes`) before
    /// committing to segmented downloading — some CDNs report a length
    /// but silently ignore Range headers, which `downloadSegment` also
    /// detects per-segment (status 206 vs 200) as a second line of
    /// defense.
    private func probeRangeSupport() async throws -> (totalBytes: Int64, supportsRanges: Bool)? {
        var request = URLRequest(url: variant.url)
        request.httpMethod = "HEAD"
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              let lengthString = http.value(forHTTPHeaderField: "Content-Length"),
              let totalBytes = Int64(lengthString) else { return nil }
        let acceptsRanges = http.value(forHTTPHeaderField: "Accept-Ranges") == "bytes"
        return (totalBytes, acceptsRanges)
    }
}

private actor SegmentedProgressTracker {
    private let totalBytes: Int64
    private var bytesWritten: Int64 = 0

    init(totalBytes: Int64) {
        self.totalBytes = totalBytes
    }

    func add(bytesWritten delta: Int64, report: (@Sendable (FetchProgress) -> Void)?) {
        bytesWritten += delta
        report?(FetchProgress(bytesWritten: bytesWritten, totalBytes: totalBytes))
    }
}

/// Merges the two top-level legs of a `DownloadManager.download(_:kinds:)`
/// call — the "audio" `TrackKind` fetch and the "video" `TrackKind` fetch
/// (which may itself be an `AdaptiveFetch` combining a video-only stream
/// with its own audio-for-mux) — into one coherent `FetchProgress` before
/// it reaches `states[ref.id]`.
///
/// Without this, both legs called `states[ref.id] = .downloading(...)`
/// independently, so whichever leg's callback fired most recently won —
/// the progress bar flickered between two unrelated fractions (e.g. a
/// small standalone audio file's progress vs. an 83MB video's) rather
/// than showing one combined value, exactly like `CombinedFetchProgress`
/// exists to prevent *within* a single `AdaptiveFetch` — this is the same
/// fix one level up, across the audio-kind and video-kind fetches
/// themselves.
public actor TrackDownloadProgressCombiner {
    public enum Role: Sendable {
        case audio
        case video
    }

    private var audio: FetchProgress?
    private var video: FetchProgress?

    public init() {}

    public func update(role: Role, progress: FetchProgress, report: @Sendable (FetchProgress) -> Void) {
        switch role {
        case .audio: audio = progress
        case .video: video = progress
        }
        report(combined)
    }

    private var combined: FetchProgress {
        let bytesWritten = (audio?.bytesWritten ?? 0) + (video?.bytesWritten ?? 0)
        let totalBytes: Int64?
        if let audioTotal = audio?.totalBytes, let videoTotal = video?.totalBytes {
            totalBytes = audioTotal + videoTotal
        } else {
            totalBytes = nil
        }
        return FetchProgress(bytesWritten: bytesWritten, totalBytes: totalBytes)
    }
}

/// Downloads and muxes a `Resolve.DownloadPlan.adaptive` pair: runs two
/// `SegmentedFetch` instances concurrently for the video-only and
/// audio-only halves — each independently segmented if its CDN supports
/// ranges — hands both finished files to `Mux` (an `AVFoundation`
/// passthrough export — no ffmpeg, see `Mux.swift`) for a lossless
/// combine once they're done, and cleans up the two intermediate
/// per-track temp files regardless of whether the mux succeeds. One
/// instance per in-flight adaptive download.
public actor AdaptiveFetch {
    private let video: Resolve.PickedVariant
    private let audio: Resolve.PickedVariant
    private var videoFetch: SegmentedFetch?
    private var audioFetch: SegmentedFetch?

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
        let videoFetch = SegmentedFetch(variant: video)
        let audioFetch = SegmentedFetch(variant: audio)
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

    /// Cancels both halves outright — no resume data kept for either
    /// (segmented downloads don't support resume yet regardless).
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
/// `SegmentedFetch.run` progress callbacks — which can land on any
/// thread — can combine into one `FetchProgress` without a data race;
/// `@Sendable` closures can't otherwise safely share mutable state.
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
