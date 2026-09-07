import XCTest
import AVFoundation
@testable import WaveformBackendKit

final class WaveformCorrelationTests: XCTestCase {

    // MARK: - correlation(_:_:) — pure, no audio file needed

    func testIdenticalEnvelopesCorrelatePerfectly() {
        let envelope: [Float] = (0..<64).map { Float(sin(Double($0) * 0.3)) + 1.5 }
        let score = WaveformCorrelation.correlation(envelope, envelope)
        XCTAssertEqual(score, 1.0, accuracy: 0.0001)
    }

    func testUnrelatedNoiseEnvelopesScoreLow() {
        // Two fixed, unrelated-looking sequences rather than random data,
        // so the test is deterministic.
        let a: [Float] = [1, 5, 2, 8, 3, 9, 1, 6, 4, 7, 2, 8, 1, 5, 3, 9]
        let b: [Float] = [9, 1, 8, 2, 7, 3, 6, 1, 5, 4, 9, 2, 8, 1, 7, 3]
        let score = WaveformCorrelation.correlation(a, b)
        XCTAssertLessThan(score, 0.5)
    }

    func testShiftedCopyStillCorrelatesWellWithinLagWindow() {
        // b is a is delayed by 3 samples (a cold open, e.g.) — the
        // two-direction lag search should still find a strong match.
        let a: [Float] = (0..<40).map { Float(sin(Double($0) * 0.4)) + 2 }
        let b: [Float] = [0, 0, 0] + a.dropLast(3)
        let score = WaveformCorrelation.correlation(a, b)
        XCTAssertGreaterThan(score, 0.7)
    }

    func testEmptyEnvelopesScoreZero() {
        XCTAssertEqual(WaveformCorrelation.correlation([], [1, 2, 3]), 0)
        XCTAssertEqual(WaveformCorrelation.correlation([1, 2, 3], []), 0)
        XCTAssertEqual(WaveformCorrelation.correlation([], []), 0)
    }

    func testTooShortEnvelopesScoreZeroRatherThanCrashing() {
        // Below the n >= 8 floor.
        let score = WaveformCorrelation.correlation([1, 2, 3], [1, 2, 3])
        XCTAssertEqual(score, 0)
    }

    func testZeroVarianceEnvelopeScoresZeroRatherThanNaN() {
        // A flat (silent) envelope has no variance to correlate against.
        let flat = [Float](repeating: 0.5, count: 20)
        let varying: [Float] = (0..<20).map { Float(sin(Double($0) * 0.3)) + 1 }
        let score = WaveformCorrelation.correlation(flat, varying)
        XCTAssertEqual(score, 0)
        XCTAssertFalse(score.isNaN)
    }

    // MARK: - envelope(of:) — decode path, against synthesized audio

    func makeTempURL(extension ext: String = "caf") -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ext)
    }

    /// Same synthetic-sine-wave trick `LoudnessAnalyzerTests` uses — a
    /// native `.caf` container round-trips float PCM through
    /// `AVAudioFile` with no format-tag ambiguity, so `envelope(of:)`
    /// has something real to decode without needing a bundled fixture.
    func writeSineWave(seconds: Double = 2, sampleRate: Double = 44100) throws -> URL {
        let url = makeTempURL()
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)

        let frameCount = AVAudioFrameCount(seconds * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount

        let channel = buffer.floatChannelData![0]
        let frequency: Float = 440
        for i in 0..<Int(frameCount) {
            let t = Float(i) / Float(sampleRate)
            channel[i] = 0.6 * sin(2 * Float.pi * frequency * t)
        }
        try file.write(from: buffer)
        return url
    }

    func testEnvelopeOfTwoSecondClipHasExpectedWindowCount() throws {
        let url = try writeSineWave(seconds: 2)
        defer { try? FileManager.default.removeItem(at: url) }

        let envelope = try WaveformCorrelation.envelope(of: url, seconds: 30)
        // 2s at 8kHz / 400-sample (50ms) windows = 40 windows.
        XCTAssertEqual(envelope.count, 40)
        XCTAssertTrue(envelope.allSatisfy { $0 > 0 && $0.isFinite })
    }

    func testEnvelopeRespectsSecondsCapOnLongerClip() throws {
        let url = try writeSineWave(seconds: 5)
        defer { try? FileManager.default.removeItem(at: url) }

        let envelope = try WaveformCorrelation.envelope(of: url, seconds: 1)
        // Capped to ~1s of audio: roughly 20 windows (50ms each), not 100.
        XCTAssertLessThan(envelope.count, 30)
        XCTAssertGreaterThan(envelope.count, 10)
    }

    func testEnvelopeOfMissingFileThrows() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("does-not-exist.caf")
        XCTAssertThrowsError(try WaveformCorrelation.envelope(of: missing)) { error in
            XCTAssertTrue(error is WaveformCorrelationError)
        }
    }

    func testSameClipCorrelatesWithItselfThroughFullPipeline() throws {
        let url = try writeSineWave(seconds: 3)
        defer { try? FileManager.default.removeItem(at: url) }

        let envelope = try WaveformCorrelation.envelope(of: url)
        let score = try WaveformCorrelation.score(against: envelope, candidateAudioURL: url)
        XCTAssertEqual(score, 1.0, accuracy: 0.01)
    }
}
