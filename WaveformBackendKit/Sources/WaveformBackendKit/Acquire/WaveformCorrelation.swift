import Foundation
import AVFoundation
import Accelerate

public enum WaveformCorrelationError: Error, LocalizedError, Sendable {
    case decodeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .decodeFailed(let reason): "Couldn't decode audio for waveform matching: \(reason)"
        }
    }
}

/// RMS-envelope waveform matching — the Swift-side port of the old
/// pipeline's `ffmpeg.js` (`extractPcmEnvelope`/`envelopeCorrelation`),
/// but decoding via `AVFoundation` + computing via `Accelerate`/vDSP
/// instead of shelling out to ffmpeg. That's a deliberate difference,
/// not an oversight: ffmpeg isn't wired into this app until
/// `Shrink.swift`/its SPM dependency land (§9), and waveform-assisted
/// video matching (`Match.swift`) needs to work well before that —
/// `AVAudioFile` already opens everything `Fetch.swift` can download
/// (mp3/m4a/webm/opus) without an extra native dependency.
///
/// Used to break ties that title/artist/view scoring alone can't: the
/// old pipeline's `jobs.js` waveform-probes the top 3 ranked video
/// candidates' first ~30s of audio against the already-downloaded audio
/// pick, and re-sorts by the blended score. `Match.rankCandidates`
/// accepts precomputed correlations the same way (`waveforms:` keyed by
/// candidate id) — this type only computes them, it doesn't decide which
/// candidates are worth probing.
public enum WaveformCorrelation {

    /// Decodes up to `seconds` of `url`'s audio down to mono/8kHz and
    /// reduces it to a 50ms-window RMS envelope (400 samples/window at
    /// 8kHz — matches `extractPcmEnvelope` exactly), rather than keeping
    /// raw samples, so `correlation(_:_:)`'s lag search stays cheap.
    ///
    /// Caveat worth flagging rather than discovering later: `AVAudioFile`
    /// only opens containers/codecs AVFoundation natively supports
    /// (mp4/m4a-aac, mp3, wav/aiff/caf) — it does **not** open a bare
    /// `.webm`/Opus file, which is exactly what `Resolve.downloadVariant`
    /// often picks for `kind: .audio` (YouTube's highest-quality audio is
    /// usually webm/Opus). Callers doing waveform probing likely need to
    /// either request an AAC/m4a-container audio variant specifically for
    /// the probe clip (accepting lower quality just for the correlation
    /// check, never for the actual saved file), or wait until
    /// `Shrink.swift`'s bundled ffmpeg exists and route through that
    /// instead. Not resolved in this pass — flagging it here (and in the
    /// checklist) so it isn't a surprise the first time waveform matching
    /// is actually wired up end-to-end.
    public static func envelope(of url: URL, seconds: Double = 30) throws -> [Float] {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw WaveformCorrelationError.decodeFailed(error.localizedDescription)
        }

        let sourceFormat = file.processingFormat
        let framesToRead = AVAudioFrameCount(min(Double(file.length), seconds * sourceFormat.sampleRate))
        guard framesToRead > 0,
              let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: framesToRead)
        else {
            throw WaveformCorrelationError.decodeFailed("Empty or unreadable audio file.")
        }
        do {
            try file.read(into: sourceBuffer, frameCount: framesToRead)
        } catch {
            throw WaveformCorrelationError.decodeFailed(error.localizedDescription)
        }

        let targetSampleRate = 8000.0
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw WaveformCorrelationError.decodeFailed("Couldn't build a mono 8kHz converter for this file's format.")
        }

        // A little slack (+1024) over the exact ratio-scaled estimate —
        // the converter's actual output frame count can round up slightly.
        let estimatedOutFrames = (Double(sourceBuffer.frameLength) / sourceFormat.sampleRate) * targetSampleRate
        guard let targetBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: AVAudioFrameCount(estimatedOutFrames) + 1024
        ) else {
            throw WaveformCorrelationError.decodeFailed("Couldn't allocate the resampled buffer.")
        }

        var suppliedInput = false
        var conversionError: NSError?
        converter.convert(to: targetBuffer, error: &conversionError) { _, outStatus in
            if suppliedInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            outStatus.pointee = .haveData
            return sourceBuffer
        }
        if let conversionError {
            throw WaveformCorrelationError.decodeFailed(conversionError.localizedDescription)
        }

        guard let channelData = targetBuffer.floatChannelData, targetBuffer.frameLength > 0 else {
            throw WaveformCorrelationError.decodeFailed("Resampled buffer had no audio data.")
        }
        let samples = UnsafeBufferPointer(start: channelData[0], count: Int(targetBuffer.frameLength))

        let window = 400 // 50ms at 8kHz
        var result: [Float] = []
        result.reserveCapacity(samples.count / window)
        var i = 0
        while i + window <= samples.count {
            var sumOfSquares: Float = 0
            vDSP_svesq(samples.baseAddress! + i, 1, &sumOfSquares, vDSP_Length(window))
            result.append(sqrtf(sumOfSquares / Float(window)))
            i += window
        }
        return result
    }

    /// Pearson correlation between two RMS envelopes, 0...1 — tries a
    /// small set of alignments in both directions (a video candidate may
    /// have a cold open the reference audio doesn't), mirroring
    /// `envelopeCorrelation`'s `maxLag = min(40, n/4)` search exactly.
    /// Returns 0 for too-short or degenerate (zero-variance) input rather
    /// than throwing — a failed/uncertain waveform probe should read as
    /// "no signal", not an error the caller has to handle specially.
    public static func correlation(_ a: [Float], _ b: [Float]) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        let n = min(a.count, b.count)
        guard n >= 8 else { return 0 }

        var best: Double = 0
        let maxLag = min(40, n / 4)
        for (x, y) in [(a, b), (b, a)] {
            for lag in 0...maxLag {
                let len = n - lag
                guard len > 0 else { continue }
                let xs = Array(x[0..<len])
                let ys = Array(y[lag..<(lag + len)])

                var sx: Float = 0, sy: Float = 0, sxx: Float = 0, syy: Float = 0, sxy: Float = 0
                vDSP_sve(xs, 1, &sx, vDSP_Length(len))
                vDSP_sve(ys, 1, &sy, vDSP_Length(len))
                vDSP_svesq(xs, 1, &sxx, vDSP_Length(len))
                vDSP_svesq(ys, 1, &syy, vDSP_Length(len))
                vDSP_dotpr(xs, 1, ys, 1, &sxy, vDSP_Length(len))

                let lenF = Float(len)
                let cov = sxy - (sx * sy) / lenF
                let vx = sxx - (sx * sx) / lenF
                let vy = syy - (sy * sy) / lenF
                guard vx > 0, vy > 0 else { continue }
                let r = Double(cov / sqrtf(vx * vy))
                if r > best { best = r }
            }
        }
        return max(0, best)
    }

    /// Convenience for the common case: decode `candidateAudioURL`'s
    /// envelope and correlate it against an already-computed
    /// `referenceEnvelope` (the downloaded audio pick's envelope, decoded
    /// once and reused across every candidate probe).
    public static func score(against referenceEnvelope: [Float], candidateAudioURL: URL, seconds: Double = 30) throws -> Double {
        let candidateEnvelope = try envelope(of: candidateAudioURL, seconds: seconds)
        return correlation(referenceEnvelope, candidateEnvelope)
    }
}
