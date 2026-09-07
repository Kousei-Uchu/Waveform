import Foundation
import AVFoundation

/// Attenuation-only loudness leveling.
///
/// This is deliberately not full ReplayGain-style two-way normalization —
/// `AVPlayer.volume` only attenuates (0...1); it can't boost a quiet track
/// above its native level. So this measures a track's average RMS over
/// (up to) its first 30 seconds and, if it's louder than a fixed reference
/// target, returns a gain below 1.0 to bring it down closer to that target.
/// Quieter tracks are left alone at gain 1.0. Good enough to stop the
/// "one track is way louder than the rest" problem; not a substitute for
/// real LUFS-based loudness matching.
enum LoudnessAnalyzer {
    private static let targetRMSDecibels: Float = -18
    private static let minimumGain: Float = 0.2 // never attenuate below -14dB

    static func measureAttenuationGain(for fileURL: URL) async -> Float {
        (try? measure(fileURL)) ?? 1.0
    }

    private static func measure(_ fileURL: URL) throws -> Float {
        let file = try AVAudioFile(forReading: fileURL)
        let format = file.processingFormat
        let sampleRate = file.fileFormat.sampleRate
        guard sampleRate > 0 else { return 1.0 }

        let capFrames = AVAudioFrameCount(min(Double(file.length), sampleRate * 30))
        guard capFrames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capFrames) else {
            return 1.0
        }
        try file.read(into: buffer)

        guard let channelData = buffer.floatChannelData else { return 1.0 }
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 0 else { return 1.0 }

        var sumSquares: Double = 0
        for channel in 0..<channelCount {
            let samples = channelData[channel]
            for i in 0..<frameCount {
                let sample = Double(samples[i])
                sumSquares += sample * sample
            }
        }
        let meanSquare = sumSquares / Double(frameCount * channelCount)
        let rms = sqrt(meanSquare)
        guard rms > 0 else { return 1.0 }

        let rmsDecibels = Float(20 * log10(rms))
        let delta = rmsDecibels - targetRMSDecibels
        guard delta > 0 else { return 1.0 } // at or under target — leave it alone

        let attenuatedDecibels = -delta
        let gain = Float(pow(10, Double(attenuatedDecibels) / 20))
        return max(minimumGain, min(1.0, gain))
    }
}
