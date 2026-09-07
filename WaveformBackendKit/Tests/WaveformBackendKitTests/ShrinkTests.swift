import XCTest
@testable import WaveformBackendKit

/// Records every `run(arguments:)` call and either succeeds or throws, so
/// `Shrink`'s arg-building and error paths are testable without a real
/// ffmpeg binary. The genuine "does this produce an actual AV1/Opus file"
/// assertion (spec §10's `ShrinkTests`) stays blocked on the real SPM
/// ffmpeg dependency — see the checklist — this covers everything else
/// `Shrink.swift` does that doesn't require one.
final actor FakeFFmpegRunner: FFmpegRunning {
    private(set) var calls: [[String]] = []
    private let shouldFail: Bool

    init(shouldFail: Bool = false) {
        self.shouldFail = shouldFail
    }

    func run(arguments: [String]) async throws {
        calls.append(arguments)
        if shouldFail {
            throw ShrinkError.ffmpegFailed("fake failure")
        }
    }
}

final class ShrinkTests: XCTestCase {

    func makeSourceFile(extension ext: String = "mp4") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ext)
        try Data("not real media, just needs to exist".utf8).write(to: url)
        return url
    }

    // MARK: - shrinkVideo

    func testShrinkVideoBuildsAV1OpusArgumentsWithSourceAndDestination() async throws {
        let source = try makeSourceFile(extension: "mp4")
        defer { try? FileManager.default.removeItem(at: source) }
        let runner = FakeFFmpegRunner()

        let destination = try await Shrink.shrinkVideo(at: source, runner: runner)

        XCTAssertEqual(destination.pathExtension, "webm")
        let calls = await runner.calls
        XCTAssertEqual(calls.count, 1)
        let args = calls[0]
        XCTAssertEqual(args.first, "-y")
        XCTAssertTrue(args.contains("-i"))
        XCTAssertTrue(args.contains(source.path))
        XCTAssertTrue(args.contains("libsvtav1"))
        XCTAssertTrue(args.contains("libopus"))
        XCTAssertTrue(args.contains("yuv420p10le"))
        XCTAssertEqual(args.last, destination.path)
    }

    func testShrinkVideoUsesProvidedOptionsInsteadOfDefaults() async throws {
        let source = try makeSourceFile(extension: "mp4")
        defer { try? FileManager.default.removeItem(at: source) }
        let runner = FakeFFmpegRunner()
        let options = Shrink.Options(av1CRF: 30, av1Preset: 2, opusBitrateKbps: 96)

        _ = try await Shrink.shrinkVideo(at: source, options: options, runner: runner)

        let args = await runner.calls[0]
        XCTAssertTrue(args.contains("30"))
        XCTAssertTrue(args.contains("2"))
        XCTAssertTrue(args.contains("96k"))
    }

    func testShrinkVideoWithMissingSourceThrowsWithoutInvokingRunner() async throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("does-not-exist.mp4")
        let runner = FakeFFmpegRunner()

        do {
            _ = try await Shrink.shrinkVideo(at: missing, runner: runner)
            XCTFail("expected missingSourceFile to be thrown")
        } catch ShrinkError.missingSourceFile {
            // expected
        }
        let calls = await runner.calls
        XCTAssertTrue(calls.isEmpty, "runner should never be invoked when the source file doesn't exist")
    }

    func testShrinkVideoPropagatesRunnerFailureAsFfmpegFailed() async throws {
        let source = try makeSourceFile(extension: "mp4")
        defer { try? FileManager.default.removeItem(at: source) }
        let runner = FakeFFmpegRunner(shouldFail: true)

        do {
            _ = try await Shrink.shrinkVideo(at: source, runner: runner)
            XCTFail("expected ffmpegFailed to be thrown")
        } catch ShrinkError.ffmpegFailed {
            // expected
        }
    }

    // MARK: - shrinkAudio

    func testShrinkAudioBuildsOpusOnlyArgumentsAndDropsVideoStream() async throws {
        let source = try makeSourceFile(extension: "webm")
        defer { try? FileManager.default.removeItem(at: source) }
        let runner = FakeFFmpegRunner()

        let destination = try await Shrink.shrinkAudio(at: source, runner: runner)

        XCTAssertEqual(destination.pathExtension, "opus")
        let args = await runner.calls[0]
        XCTAssertTrue(args.contains("-vn"), "audio shrink should drop any attached video/cover-art stream")
        XCTAssertTrue(args.contains("libopus"))
        XCTAssertFalse(args.contains("libsvtav1"), "audio shrink should never invoke the video encoder")
    }

    func testShrinkAudioWithMissingSourceThrows() async throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("does-not-exist.webm")
        let runner = FakeFFmpegRunner()

        do {
            _ = try await Shrink.shrinkAudio(at: missing, runner: runner)
            XCTFail("expected missingSourceFile to be thrown")
        } catch ShrinkError.missingSourceFile {
            // expected
        }
    }

    // MARK: - mediaFile(for:downloadCap:)

    func testMediaFileForVideoReportsAV1WebmShrunkTrue() {
        let file = Shrink.mediaFile(for: .video, downloadCap: "1080p")
        XCTAssertEqual(file.codec, "av1")
        XCTAssertEqual(file.container, "webm")
        XCTAssertTrue(file.shrunk)
        XCTAssertEqual(file.downloadCap, "1080p")
    }

    func testMediaFileForAudioReportsOpusShrunkTrue() {
        let file = Shrink.mediaFile(for: .audio, downloadCap: nil)
        XCTAssertEqual(file.codec, "opus")
        XCTAssertEqual(file.container, "opus")
        XCTAssertTrue(file.shrunk)
        XCTAssertNil(file.downloadCap)
    }

    func testMediaFileCarriesDownloadCapThroughUnchanged() {
        // Shrink doesn't change which source variant was originally
        // downloaded — only how the file on disk is encoded now.
        let file = Shrink.mediaFile(for: .video, downloadCap: "5000kbps")
        XCTAssertEqual(file.downloadCap, "5000kbps")
    }
}
