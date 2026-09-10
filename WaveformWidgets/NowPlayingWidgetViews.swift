//
//  NowPlayingWidgetView.swift
//  Waveform
//
//  Created by Aiden McGovern (School) on 10/9/2026.
//


import WidgetKit
import SwiftUI

// MARK: - Placeholder data

extension NowPlayingSnapshot {
    /// Shown in the widget gallery and for the system's redacted
    /// placeholder render — deliberately generic rather than reusing any
    /// real track, since this is UI chrome, not user data.
    static let placeholder = NowPlayingSnapshot(
        itemID: "placeholder",
        title: "Song Title",
        author: "Artist Name",
        isPlaying: true,
        elapsedSeconds: 45,
        durationSeconds: 210,
        primaryColorHex: "#4A5B8C",
        secondaryColorHex: "#C97B5A"
    )
}

// MARK: - Top-level dispatch

struct NowPlayingWidgetView: View {
    let entry: NowPlayingWidgetEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            if let snapshot = entry.snapshot {
                content(for: snapshot)
            } else {
                EmptyNowPlayingView()
            }
        }
        .widgetURL(URL(string: "waveform://now-playing"))
    }

    @ViewBuilder
    private func content(for snapshot: NowPlayingSnapshot) -> some View {
        switch family {
        case .accessoryCircular:
            AccessoryCircularView(snapshot: snapshot)
        case .accessoryRectangular:
            AccessoryRectangularView(snapshot: snapshot)
        case .accessoryInline:
            AccessoryInlineView(snapshot: snapshot)
        case .systemLarge:
            HomeScreenView(snapshot: snapshot, format: entry.configuration.format, showsFullTransport: true, showsProgressBar: true)
        case .systemMedium:
            HomeScreenView(snapshot: snapshot, format: entry.configuration.format, showsFullTransport: true, showsProgressBar: true)
        default: // .systemSmall, and any future family this widget hasn't opted into a bespoke layout for
            HomeScreenView(snapshot: snapshot, format: entry.configuration.format, showsFullTransport: false, showsProgressBar: false)
        }
    }
}

/// Nothing playing — either playback never started this launch, or the
/// app hasn't been opened since install (`NowPlayingStore.read()` is
/// `nil` either way). Still respects the chosen colour style so the
/// widget doesn't jarringly flip to a totally different look the moment
/// something starts playing.
private struct EmptyNowPlayingView: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "music.note")
                .font(.title2)
            Text("Nothing Playing")
                .font(.caption)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Colour-changing background

/// The "colour changing" part of this widget — reads the two colours
/// `PaletteStore` already extracted for the current track (see
/// `NowPlayingSnapshot.primaryColorHex`/`secondaryColorHex`) and turns
/// them into a background gradient, so a Home Screen widget's colour
/// shifts along with whatever's playing.
///
/// Lock Screen/StandBy accessory families are deliberately excluded from
/// all of this: iOS always renders those in its own single-colour tinted
/// style for legibility against every possible wallpaper — a widget
/// can't (and, for accessory families specifically, shouldn't try to)
/// supply its own background colour there. `AccessoryWidgetBackground()`
/// is the correct, idiomatic choice for that family group regardless of
/// `colorStyle`.
struct NowPlayingWidgetBackground: View {
    let entry: NowPlayingWidgetEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryCircular, .accessoryRectangular, .accessoryInline:
            AccessoryWidgetBackground()
        default:
            homeScreenBackground
        }
    }

    @ViewBuilder
    private var homeScreenBackground: some View {
        switch entry.configuration.colorStyle {
        case .monochrome:
            Color(white: 0.12)
        case .accentColor:
            LinearGradient(
                colors: [Color("AccentColor"), Color("AccentColor").opacity(0.55)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .dynamic:
            let primary = entry.snapshot?.primaryColorHex.flatMap(Color.init(widgetHex:)) ?? Color(white: 0.15)
            let secondary = entry.snapshot?.secondaryColorHex.flatMap(Color.init(widgetHex:)) ?? primary.opacity(0.55)
            LinearGradient(colors: [primary, secondary], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}

// MARK: - Home Screen (.systemSmall / .systemMedium / .systemLarge)

/// Renders one of the three user-selectable `NowPlayingWidgetFormat`
/// layouts, adapting to whichever Home Screen family it's actually
/// drawn at via `showsFullTransport`/`showsProgressBar` (both `false`
/// only for `.systemSmall`, which doesn't have room for a previous
/// button or a separate progress bar alongside everything else).
struct HomeScreenView: View {
    let snapshot: NowPlayingSnapshot
    let format: NowPlayingWidgetFormat
    let showsFullTransport: Bool
    let showsProgressBar: Bool

    var body: some View {
        switch format {
        case .card:
            CardLayout(snapshot: snapshot, showsFullTransport: showsFullTransport, showsProgressBar: showsProgressBar)
        case .compact:
            CompactLayout(snapshot: snapshot, showsFullTransport: showsFullTransport, showsProgressBar: showsProgressBar)
        case .artworkFocused:
            ArtworkFocusedLayout(snapshot: snapshot, showsFullTransport: showsFullTransport, showsProgressBar: showsProgressBar)
        }
    }
}

private struct CardLayout: View {
    let snapshot: NowPlayingSnapshot
    let showsFullTransport: Bool
    let showsProgressBar: Bool
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if family == .systemSmall {
            VStack(alignment: .leading, spacing: 8) {
                WidgetArtworkView(filename: snapshot.artworkFilename)
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                TrackInfoText(snapshot: snapshot, titleFont: .caption.weight(.semibold), authorFont: .caption2)
                TransportRow(snapshot: snapshot, showsPrevious: false, size: .compact)
            }
            .widgetPadding()
        } else {
            HStack(alignment: .center, spacing: 14) {
                WidgetArtworkView(filename: snapshot.artworkFilename)
                    .frame(width: family == .systemLarge ? 120 : 76, height: family == .systemLarge ? 120 : 76)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 6) {
                    TrackInfoText(snapshot: snapshot, titleFont: .headline, authorFont: .subheadline)
                    if showsProgressBar {
                        PlaybackProgressBar(snapshot: snapshot)
                    }
                    Spacer(minLength: 0)
                    TransportRow(snapshot: snapshot, showsPrevious: showsFullTransport, size: .regular)
                }
            }
            .widgetPadding()
        }
    }
}

private struct CompactLayout: View {
    let snapshot: NowPlayingSnapshot
    let showsFullTransport: Bool
    let showsProgressBar: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TrackInfoText(snapshot: snapshot, titleFont: .headline, authorFont: .subheadline)
            if showsProgressBar {
                PlaybackProgressBar(snapshot: snapshot)
            }
            Spacer(minLength: 0)
            TransportRow(snapshot: snapshot, showsPrevious: showsFullTransport, size: .regular)
        }
        .widgetPadding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ArtworkFocusedLayout: View {
    let snapshot: NowPlayingSnapshot
    let showsFullTransport: Bool
    let showsProgressBar: Bool

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            WidgetArtworkView(filename: snapshot.artworkFilename)
                .aspectRatio(contentMode: .fill)

            LinearGradient(
                colors: [.clear, .black.opacity(0.75)],
                startPoint: .center,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 6) {
                TrackInfoText(snapshot: snapshot, titleFont: .subheadline.weight(.semibold), authorFont: .caption)
                if showsProgressBar {
                    PlaybackProgressBar(snapshot: snapshot)
                }
                TransportRow(snapshot: snapshot, showsPrevious: showsFullTransport, size: .regular)
            }
            .widgetPadding()
        }
        // Full-bleed art needs to reach every edge, so this format skips
        // `containerBackground`'s usual role entirely rather than
        // layering a colour behind an opaque image no one will ever see —
        // `NowPlayingWidgetBackground` still runs underneath, but only
        // matters here as the letterboxing color if the artwork doesn't
        // perfectly fill the frame.
    }
}

// MARK: - Lock Screen / StandBy (.accessoryCircular / .accessoryRectangular / .accessoryInline)

private struct AccessoryCircularView: View {
    let snapshot: NowPlayingSnapshot

    var body: some View {
        Button(intent: PlayPauseIntent()) {
            Gauge(value: snapshot.progress) {
                Image(systemName: snapshot.isPlaying ? "pause.fill" : "play.fill")
            }
            .gaugeStyle(.accessoryCircularCapacity)
        }
        .buttonStyle(.plain)
    }
}

private struct AccessoryRectangularView: View {
    let snapshot: NowPlayingSnapshot

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(snapshot.author)
                    .font(.caption2)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            HStack(spacing: 10) {
                Button(intent: SkipBackIntent()) {
                    Image(systemName: "backward.fill")
                }
                Button(intent: PlayPauseIntent()) {
                    Image(systemName: snapshot.isPlaying ? "pause.fill" : "play.fill")
                }
                Button(intent: SkipForwardIntent()) {
                    Image(systemName: "forward.fill")
                }
            }
            .font(.caption)
            .buttonStyle(.plain)
        }
    }
}

private struct AccessoryInlineView: View {
    let snapshot: NowPlayingSnapshot

    var body: some View {
        // `.accessoryInline` is a single text+icon slot the system lays
        // out itself (alongside the time, other complications, etc.) —
        // there's no room for, and no real precedent for, interactive
        // buttons at this size, so this one just opens the app on tap
        // (via `NowPlayingWidgetView`'s `widgetURL`) rather than trying
        // to cram a `Button(intent:)` in.
        Label("\(snapshot.title) — \(snapshot.author)", systemImage: snapshot.isPlaying ? "waveform" : "pause.fill")
    }
}

// MARK: - Shared subviews

private struct TrackInfoText: View {
    let snapshot: NowPlayingSnapshot
    let titleFont: Font
    let authorFont: Font

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(snapshot.title)
                .font(titleFont)
                .foregroundStyle(.white)
                .lineLimit(1)
            Text(snapshot.author)
                .font(authorFont)
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
        }
    }
}

/// Live-ticking while playing (`ProgressView(timerInterval:)` animates on
/// its own, no widget reload needed — see `NowPlayingSnapshot.timerRange`),
/// a plain static bar while paused.
private struct PlaybackProgressBar: View {
    let snapshot: NowPlayingSnapshot

    var body: some View {
        if let range = snapshot.timerRange {
            ProgressView(timerInterval: range, countsDown: false) { EmptyView() }
                .tint(.white)
                .labelsHidden()
        } else {
            ProgressView(value: snapshot.progress)
                .tint(.white)
        }
    }
}

private enum TransportButtonSize {
    case compact
    case regular

    var font: Font {
        switch self {
        case .compact: .body
        case .regular: .title3
        }
    }
}

/// Play/pause + (optionally) previous/next, as real interactive
/// `Button(intent:)`s — this is the "AppIntent buttons for interactive
/// features" ask. Each button's `perform()` runs in the main app's
/// process (`AudioPlaybackIntent`, see `NowPlayingIntents.swift`), so
/// tapping one controls whatever `MediaPlayerController` is actually
/// doing right now, without needing to open the app.
private struct TransportRow: View {
    let snapshot: NowPlayingSnapshot
    let showsPrevious: Bool
    let size: TransportButtonSize

    var body: some View {
        HStack(spacing: 16) {
            if showsPrevious {
                Button(intent: SkipBackIntent()) {
                    Image(systemName: "backward.fill")
                }
            }
            Button(intent: PlayPauseIntent()) {
                Image(systemName: snapshot.isPlaying ? "pause.fill" : "play.fill")
            }
            Button(intent: SkipForwardIntent()) {
                Image(systemName: "forward.fill")
            }
        }
        .font(size.font)
        .foregroundStyle(.white)
        .buttonStyle(.plain)
    }
}

/// Reads the current track's cover art out of the shared App Group
/// container — the widget extension has no way to reach into a `.cmf`
/// archive (or a remote thumbnail URL) itself, so the app writes a JPEG
/// there whenever the track changes (`NowPlayingWidgetSync`, reusing the
/// same file `LiveActivityManager` already writes). Falls back to a
/// plain music-note glyph over the current background colour if there's
/// no artwork yet or the App Group container isn't reachable — mirrors
/// `PlaybackActivityWidget.swift`'s `ActivityArtworkView` exactly, since
/// it's solving the identical problem.
struct WidgetArtworkView: View {
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
                Color.white.opacity(0.15)
                Image(systemName: "music.note")
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
    }
}

private extension View {
    /// The padding every Home Screen layout above uses around its
    /// content — factored out so the four formats/sizes stay visually
    /// consistent with each other and with a future fifth layout.
    func widgetPadding() -> some View {
        padding(14)
    }
}

private extension Color {
    /// Parses the `"#RRGGBB"` strings `PaletteStore` writes into
    /// `NowPlayingSnapshot` — a small, local, read-only counterpart to
    /// the app target's own (private, unexported) hex parser in
    /// `PaletteStore.swift`. Kept separate rather than shared: the app
    /// side only ever *writes* hex strings (from an already-a-`Color`
    /// value) and never needs to parse one back, so there's nothing
    /// small enough to be worth factoring into `WaveformShared` just for
    /// this one direction.
    init?(widgetHex hex: String) {
        var value = hex
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let rgb = UInt64(value, radix: 16) else { return nil }
        let r = Double((rgb & 0xFF0000) >> 16) / 255
        let g = Double((rgb & 0x00FF00) >> 8) / 255
        let b = Double(rgb & 0x0000FF) / 255
        self.init(red: r, green: g, blue: b)
    }
}