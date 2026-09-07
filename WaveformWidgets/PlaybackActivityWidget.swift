import ActivityKit
import WidgetKit
import SwiftUI

struct PlaybackActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PlaybackActivityAttributes.self) { context in
            LockScreenPlaybackView(context: context)
                .activityBackgroundTint(Color.black.opacity(0.85))
                .activitySystemActionForegroundColor(Color.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ActivityArtworkView(filename: context.state.artworkFilename)
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Image(systemName: context.state.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 2) {
                        Text(context.state.title)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                        Text(context.state.artist)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ProgressView(value: context.state.progress)
                        .tint(.white)
                        .padding(.top, 4)
                }
            } compactLeading: {
                ActivityArtworkView(filename: context.state.artworkFilename)
                    .frame(width: 20, height: 20)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } compactTrailing: {
                Image(systemName: context.state.isPlaying ? "waveform" : "pause.fill")
                    .font(.caption2)
            } minimal: {
                ActivityArtworkView(filename: context.state.artworkFilename)
                    .clipShape(Circle())
            }
            .widgetURL(URL(string: "waveform://now-playing"))
            .keylineTint(Color("AccentColor"))
        }
    }
}

/// The lock-screen / paired-device banner. Tapping anywhere on it opens
/// the app to Now Playing via the containing `Widget`'s implicit
/// `widgetURL` handling for the activity's primary content view.
private struct LockScreenPlaybackView: View {
    let context: ActivityViewContext<PlaybackActivityAttributes>

    var body: some View {
        HStack(spacing: 12) {
            ActivityArtworkView(filename: context.state.artworkFilename)
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text(context.state.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(context.state.artist)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                ProgressView(value: context.state.progress)
                    .tint(.white)
            }

            Spacer(minLength: 8)

            Image(systemName: context.state.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                .font(.system(size: 32))
        }
        .padding()
        .foregroundStyle(.white)
    }
}

/// Reads the current track's artwork out of the shared App Group
/// container (the extension has no way to reach into a `.cmf` archive
/// itself — the app writes this file whenever the track changes). Falls
/// back to a plain music-note glyph if there's no artwork or the App
/// Group container isn't reachable.
private struct ActivityArtworkView: View {
    let filename: String?

    var body: some View {
        if let filename,
           let containerURL = FileManager.default.containerURL(
               forSecurityApplicationGroupIdentifier: AppGroup.identifier
           ),
           let data = try? Data(contentsOf: containerURL.appendingPathComponent(filename)),
           let uiImage = UIImage(data: data) {
            Image(uiImage: uiImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                Color.gray.opacity(0.3)
                Image(systemName: "music.note")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
