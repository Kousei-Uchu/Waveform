import ActivityKit
import Foundation

/// The Live Activity's data model. `itemID` is fixed for the activity's
/// whole lifetime (static, per `ActivityAttributes`); everything that
/// changes as playback progresses lives in `ContentState`.
///
/// Kept deliberately small — ActivityKit content has a strict ~4KB size
/// limit, so artwork is *not* embedded here as raw bytes. Instead the app
/// writes a JPEG into the shared App Group container (see `AppGroup`) and
/// this only carries the filename; the widget extension reads the file
/// itself.
public struct PlaybackActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public var title: String
        public var artist: String
        public var isPlaying: Bool
        public var elapsedSeconds: Double
        public var durationSeconds: Double
        public var artworkFilename: String?

        public init(
            title: String,
            artist: String,
            isPlaying: Bool,
            elapsedSeconds: Double,
            durationSeconds: Double,
            artworkFilename: String?
        ) {
            self.title = title
            self.artist = artist
            self.isPlaying = isPlaying
            self.elapsedSeconds = elapsedSeconds
            self.durationSeconds = durationSeconds
            self.artworkFilename = artworkFilename
        }

        /// 0...1, clamped — safe to hand straight to `ProgressView(value:)`.
        public var progress: Double {
            guard durationSeconds > 0 else { return 0 }
            return min(max(elapsedSeconds / durationSeconds, 0), 1)
        }
    }

    public var itemID: String

    public init(itemID: String) {
        self.itemID = itemID
    }
}
