import Foundation

public enum ShrinkError: Error, LocalizedError, Sendable {
    case missingSourceFile
    case ffmpegFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingSourceFile: "The file to shrink doesn't exist on disk."
        case .ffmpegFailed(let message): "Shrink failed: \(message)"
        }
    }
}

/// Runs one ffmpeg command line to completion, throwing on failure.
///
/// `Shrink`'s actual re-encode logic (arg-building, which knobs apply to
/// audio vs. video) is written against this protocol rather than a
/// concrete ffmpeg package directly, because §9 still has the actual SPM
/// ffmpeg dependency as 🔧 — swap the concrete runner passed in, not
/// `Shrink`'s call sites, once that's settled in Xcode.
///
/// **`kingslay/FFmpegKit`'s real API is now confirmed** (it wasn't in the
/// previous pass — the earlier commented-out `FFmpegKitRunner` sketch
/// below assumed the `arthenica/ffmpeg-kit` lineage's
/// `FFmpegKit`/`FFmpegSession`/`ReturnCode` object API, which is the
/// *wrong* shape for this package and, as of this pass, is also an
/// **archived/discontinued repo** — not something to depend on going
/// forward regardless). `kingslay/FFmpegKit`'s README instead documents a
/// single free function, `ffmpeg_execute(_ argc: Int32, _ argv: inout
/// [UnsafeMutablePointer<CChar>?]) -> Int32`, called directly with a
/// C-style `argv` (index 0 is the literal string `"ffmpeg"`, mirroring a
/// real CLI's `argv[0]`, *not* excluded the way this protocol's doc
/// comment used to say). It's a **synchronous, blocking** call — no
/// session object, no async completion handler, no `getFailStackTrace()`
/// to inspect. `FFmpegKitRunner` below is written against that real
/// shape. Two things it does **not** resolve, flagged rather than
/// guessed at:
/// - The function's return value isn't documented anywhere in the
///   README/wiki content available to port against — `FFmpegKitRunner`
///   treats non-zero as failure (the universal CLI-exit-code convention,
///   and ffmpeg's own convention specifically), but that's an assumption
///   to verify once the package is actually added in Xcode and can be
///   run against a real file.
/// - `kingslay/FFmpegKit` needs a manual post-`swift package resolve`
///   build step (`swift package --disable-sandbox BuildFFmpeg`) to
///   compile the native FFmpeg libraries the Swift target links against
///   — it isn't a drop-in "add to `Package.swift`, done" dependency the
///   way `YouTubeKit` was, so it hasn't been added there speculatively
///   in this pass either (see `Package.swift`'s comment). Also worth
///   carrying forward: its default build enables `libsmbclient`, which
///   puts the resulting binary under the GPL rather than LGPL — a
///   distribution-license fact to keep in mind even though direct
///   install/TestFlight avoids App Store review specifically.
public protocol FFmpegRunning: Sendable {
    /// `arguments` excludes the leading `ffmpeg` token itself (e.g.
    /// `["-y", "-i", "/path/in.mp4", ...]`) — `FFmpegKitRunner` is the
    /// one that prepends the literal `"ffmpeg"` argv[0] token
    /// `ffmpeg_execute` itself expects; callers of this protocol still
    /// only ever deal in the "real" arguments.
    func run(arguments: [String]) async throws
}

/// Explicit, user-initiated, per-item re-encode to AV1 (video) or Opus
/// (audio) — §3's "Shrink" action, the only place this app ever
/// transcodes anything (everything on the download hot path is a
/// stream-copy, see `Fetch.swift`). A direct port of `ffmpeg.js`'s
/// `toWebm`/`remuxWebm` encode arguments, minus the NVENC branch (no
/// discrete GPU to target on iOS) and minus the "try a copy remux
/// first" fallback (that only makes sense when the source *might*
/// already be AV1/Opus and a plain container remux would suffice —
/// `LibraryStore`/the Shrink UI is expected to check `media.codec`
/// itself and skip offering Shrink at all when it would have nothing to
/// do, rather than this type silently no-op'ing on a caller's behalf).
public enum Shrink {

    /// Mirrors `ffmpeg.js`'s `AV1_CRF`/`AV1_PRESET`/`OPUS_BITRATE`
    /// env-tunable defaults, now as a plain struct so the Shrink screen
    /// (§8 app-level) can offer them as editable fields with these as
    /// starting values, same as the spec describes.
    public struct Options: Sendable {
        /// libsvtav1's CRF scale: lower = higher quality/bigger file.
        /// 18-22 is a reasonable transparent range; 20 (ffmpeg.js's
        /// default) is used here too.
        public var av1CRF: Int
        /// libsvtav1's preset scale: 0 (slowest/best) to 13
        /// (fastest/worst). `ffmpeg.js` defaults to 4 on the assumption
        /// of server hardware; 6 is used here instead as a starting
        /// point leaning a little more toward "finishes in reasonable
        /// time on a phone" — worth real-device timing once Shrink is
        /// actually wired up and tunable via Settings.
        public var av1Preset: Int
        /// Opus bitrate in kbps — 128 is transparent for stereo music,
        /// matching `ffmpeg.js`'s `OPUS_BITRATE` default.
        public var opusBitrateKbps: Int

        public init(av1CRF: Int = 20, av1Preset: Int = 6, opusBitrateKbps: Int = 128) {
            self.av1CRF = av1CRF
            self.av1Preset = av1Preset
            self.opusBitrateKbps = opusBitrateKbps
        }

        public static let `default` = Options()
    }

    /// Re-encodes a downloaded video file to AV1/Opus in a `.webm`
    /// container. 10-bit output (`yuv420p10le`) prevents banding at no
    /// size cost, matching `toWebm` exactly.
    public static func shrinkVideo(
        at sourceURL: URL,
        options: Options = .default,
        runner: FFmpegRunning
    ) async throws -> URL {
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw ShrinkError.missingSourceFile
        }
        let destination = temporaryDestination(extension: "webm")
        do {
            try await runner.run(arguments: [
                "-y",
                "-i", sourceURL.path,
                "-c:v", "libsvtav1",
                "-crf", String(options.av1CRF),
                "-preset", String(options.av1Preset),
                "-pix_fmt", "yuv420p10le",
                "-c:a", "libopus",
                "-b:a", "\(options.opusBitrateKbps)k",
                destination.path,
            ])
        } catch {
            throw ShrinkError.ffmpegFailed(error.localizedDescription)
        }
        return destination
    }

    /// Re-encodes a downloaded audio file to Opus in a `.opus` container
    /// (`-vn` drops any attached video/cover-art stream some containers
    /// carry, so a stray cover image doesn't get treated as a video
    /// track). Audio-only counterpart of `shrinkVideo` — the spec's §7
    /// notes explicitly cover both `Audio/`/`Video/` files as Shrink
    /// targets, not just video.
    public static func shrinkAudio(
        at sourceURL: URL,
        options: Options = .default,
        runner: FFmpegRunning
    ) async throws -> URL {
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw ShrinkError.missingSourceFile
        }
        let destination = temporaryDestination(extension: "opus")
        do {
            try await runner.run(arguments: [
                "-y",
                "-i", sourceURL.path,
                "-vn",
                "-c:a", "libopus",
                "-b:a", "\(options.opusBitrateKbps)k",
                destination.path,
            ])
        } catch {
            throw ShrinkError.ffmpegFailed(error.localizedDescription)
        }
        return destination
    }

    /// The `MediaFile` `LibraryStore.replaceFile` should record once a
    /// shrink completes — `shrunk` always flips to `true` on this path
    /// (§3/§7), unlike `Fetch.mediaFile(downloadCap:)`, which always
    /// starts `false`. `downloadCap` is carried over from whatever the
    /// item's existing `MediaFile.downloadCap` was — Shrink doesn't
    /// change which source variant was originally downloaded, only how
    /// the file on disk is encoded now.
    public static func mediaFile(for kind: TrackKind, downloadCap: String?) -> MediaFile {
        switch kind {
        case .video:
            MediaFile(codec: "av1", container: "webm", shrunk: true, downloadCap: downloadCap)
        case .audio:
            MediaFile(codec: "opus", container: "opus", shrunk: true, downloadCap: downloadCap)
        }
    }

    private static func temporaryDestination(extension ext: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ext)
    }
}

/// Concrete `FFmpegRunning` implementation against `kingslay/FFmpegKit`'s
/// real, confirmed API (see the caveat on `FFmpegRunning` above for what
/// this pass verified and what it still couldn't, without the package
/// actually resolved in Xcode). `ffmpeg_execute` is a synchronous C
/// function, so the blocking call is wrapped in `Task.detached` to keep
/// it off whatever cooperative-pool thread called `run(arguments:)` —
/// `async throws` at the protocol boundary shouldn't itself block a
/// worker thread for however long a re-encode takes.
///
/// Not compiled into the target by default: `import FFmpegKit` would
/// fail until the package is both added to `Package.swift` *and* its
/// `BuildFFmpeg` step has been run once in Xcode (see `Package.swift`'s
/// comment) — kept here, commented out, as the concrete piece to
/// uncomment (and adjust if the real return-code convention turns out
/// to differ) once that's done, rather than leaving `FFmpegRunning`
/// with zero implementations to look at.
///
/// import FFmpegKit
///
/// public struct FFmpegKitRunner: FFmpegRunning {
///     public init() {}
///
///     public func run(arguments: [String]) async throws {
///         // argv[0] is the literal "ffmpeg" token — ffmpeg_execute
///         // expects a real CLI-style argv, not just the flags.
///         let fullArguments = ["ffmpeg"] + arguments
///         let exitCode: Int32 = try await Task.detached(priority: .utility) {
///             var argv = fullArguments.map {
///                 UnsafeMutablePointer(mutating: ($0 as NSString).utf8String)
///             }
///             return ffmpeg_execute(Int32(fullArguments.count), &argv)
///         }.value
///         // Unverified assumption (see FFmpegRunning's doc comment):
///         // treating non-zero as failure, since ffmpeg_execute's return
///         // value isn't documented and this is the standard CLI
///         // exit-code convention ffmpeg itself follows.
///         guard exitCode == 0 else {
///             throw ShrinkError.ffmpegFailed("ffmpeg_execute returned exit code \(exitCode)")
///         }
///     }
/// }
public enum FFmpegKitRunnerPlaceholder {}
