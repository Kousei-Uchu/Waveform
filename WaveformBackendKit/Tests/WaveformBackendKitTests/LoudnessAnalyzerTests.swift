import XCTest
import AVFoundation
@testable import WaveformBackendKit

final class LoudnessAnalyzerTests: XCTestCase {
    func makeTempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("caf")
    }

    /// Writes a short synthetic sine-wave audio file at a given peak
    /// amplitude (0...1), so `LoudnessAnalyzer` has something real to
    /// measure without needing a bundled fixture. `.caf` since it's a
    /// native Core Audio container that round-trips float PCM cleanly
    /// through AVAudioFile without any format-tag ambiguity.
    func writeSineWave(amplitude: Float, seconds: Double = 2, sampleRate: Double = 44100) throws -> URL {
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
            channel[i] = amplitude * sin(2 * Float.pi * frequency * t)
        }
        try file.write(from: buffer)
        return url
    }

    func testLoudSignalGetsAttenuated() async throws {
        let url = try writeSineWave(amplitude: 0.9) // very loud, near clipping
        defer { try? FileManager.default.removeItem(at: url) }

        let gain = await LoudnessAnalyzer.measureAttenuationGain(for: url)
        XCTAssertLessThan(gain, 1.0, "a track this loud should be turned down")
        XCTAssertGreaterThanOrEqual(gain, 0.2, "should never attenuate below the documented floor")
    }

    func testQuietSignalIsLeftAlone() async throws {
        let url = try writeSineWave(amplitude: 0.02) // very quiet
        defer { try? FileManager.default.removeItem(at: url) }

        let gain = await LoudnessAnalyzer.measureAttenuationGain(for: url)
        XCTAssertEqual(gain, 1.0, "quiet tracks should never be boosted or attenuated")
    }

    func testLouderSignalGetsMoreAttenuationThanQuieterOne() async throws {
        let loudURL = try writeSineWave(amplitude: 0.9)
        let mediumURL = try writeSineWave(amplitude: 0.5)
        defer {
            try? FileManager.default.removeItem(at: loudURL)
            try? FileManager.default.removeItem(at: mediumURL)
        }

        let loudGain = await LoudnessAnalyzer.measureAttenuationGain(for: loudURL)
        let mediumGain = await LoudnessAnalyzer.measureAttenuationGain(for: mediumURL)
        XCTAssertLessThan(loudGain, mediumGain, "louder input should end up attenuated more, not less")
    }

    func testMissingFileFailsGracefullyToUnityGain() async {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("does-not-exist.caf")
        let gain = await LoudnessAnalyzer.measureAttenuationGain(for: missing)
        XCTAssertEqual(gain, 1.0, "measurement failures should never crash or silence playback")
    }
}
