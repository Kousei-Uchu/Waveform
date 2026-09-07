import Foundation
import SwiftUI
import WaveformBackendKit

struct ItemDetailView: View {
    let item: MediaItem

    @EnvironmentObject private var queue: PlaybackQueue
    @EnvironmentObject private var player: MediaPlayerController
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var settings: PlaybackSettingsStore

    @State private var shrinkKind: TrackKind?

    /// Re-read from the library rather than trusting the `item` this view
    /// was constructed with, since Shrink (§3) mutates the entry's
    /// `paths`/`media` in place — without this, the file-size/codec/
    /// shrunk-state row would keep showing stale pre-Shrink values (or a
    /// path to a file that no longer exists) after a successful Shrink.
    private var currentItem: MediaItem { library.item(withID: item.id) ?? item }

    var body: some View {
        let item = currentItem
        ScrollView {
            VStack(spacing: 20) {
                ArtworkView(item: item, cornerRadius: 12)
                    .frame(width: 220, height: 220)
                    .shadow(radius: 8)

                VStack(spacing: 4) {
                    Text(item.title)
                        .font(.title2.weight(.semibold))
                        .multilineTextAlignment(.center)
                    
                    Text(item.author)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    if item.duration > 0 {
                        Text(TimeFormatting.string(from: item.duration))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 8) {
                    Text("Play")
                        .foregroundColor(PaletteStore.shared.currentSecondaryTint ?? .stableAccent)
                    
                    RoundedRectangle(cornerRadius: 20)
                        .frame(width: 2)
                        .padding(.horizontal, 8)
                        .foregroundColor(PaletteStore.shared.currentSecondaryTint ?? .stableAccent)
                    
                    if item.hasAudio {
                        Button {
                            playNow(item: item, kind: .audio)
                        } label: {
                            Image(systemName: "waveform")
                        }
                        .padding(8)
                        .scrollContentBackground(.hidden)
                        .liquidGlassIfAvailable(in: .circle, isInteractive: true, tinted: true)
                    }
                    if item.hasVideo {
                        Button {
                            playNow(item: item, kind: .video)
                        } label: {
                            Image(systemName: "film")
                        }
                        .padding(8)
                        .scrollContentBackground(.hidden)
                        .liquidGlassIfAvailable(in: .circle, isInteractive: true, tinted: true)
                    }
                }
                .padding(8)
                .padding(.horizontal, 8)
                .liquidGlassIfAvailable(in: RoundedRectangle(cornerRadius: 10), tinted: true)

                HStack(spacing: 8) {
                    Text("Add to Queue")
                        .foregroundColor(PaletteStore.shared.currentSecondaryTint ?? .stableAccent)
                    
                    RoundedRectangle(cornerRadius: 20)
                        .frame(width: 2)
                        .padding(.horizontal, 8)
                        .foregroundColor(PaletteStore.shared.currentSecondaryTint ?? .stableAccent)
                    
                    if item.hasAudio {
                        Button {
                            queue.append(QueueEntry(playable: .library(item), kind: .audio))
                        } label: {
                            Image(systemName: "waveform")
                        }
                        .padding(8)
                        .scrollContentBackground(.hidden)
                        .liquidGlassIfAvailable(in: .circle, isInteractive: true, tinted: true)
                    }
                    if item.hasVideo {
                        Button {
                            queue.append(QueueEntry(playable: .library(item), kind: .video))
                        } label: {
                            Image(systemName: "film")
                        }
                        .padding(8)
                        .scrollContentBackground(.hidden)
                        .liquidGlassIfAvailable(in: .circle, isInteractive: true, tinted: true)
                    }
                }
                .padding(8)
                .padding(.horizontal, 8)
                .liquidGlassIfAvailable(in: RoundedRectangle(cornerRadius: 10), tinted: true)


                mediaSection(for: item)
                detailsSection(for: item)
            }
            .padding()
        }
        .navigationTitle(item.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .sheet(item: $shrinkKind) { kind in
            if let runner = ShrinkSupport.runner,
               let sourceURL = item.fileURL(for: kind),
               let media = item.media(for: kind) {
                ShrinkSheet(
                    item: item,
                    kind: kind,
                    sourceURL: sourceURL,
                    currentMedia: media,
                    runner: runner,
                    defaults: Shrink.Options(
                        av1CRF: settings.shrinkAV1CRF,
                        av1Preset: settings.shrinkAV1Preset,
                        opusBitrateKbps: settings.shrinkOpusBitrateKbps
                    )
                )
            } else {
                // Reachable only if state gets out from under the disabled
                // "Shrink" button (e.g. the file vanished between tap and
                // sheet presentation) — the button itself is disabled
                // whenever `ShrinkSupport.runner` is nil (§9 not unblocked
                // yet), so this is a fallback, not the primary UI.
                ContentUnavailableView(
                    "Shrink Unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text("This build doesn't have the ffmpeg re-encoder available yet.")
                )
            }
        }
    }

    // MARK: - Media / Shrink (§3, §8: "Library item detail gains a
    // Shrink action ... showing current file size/codec")

    @ViewBuilder
    private func mediaSection(for item: MediaItem) -> some View {
        let rows: [(kind: TrackKind, media: MediaFile, url: URL)] = TrackKind.allCases.compactMap { kind in
            guard let media = item.media(for: kind), let url = item.fileURL(for: kind) else { return nil }
            return (kind, media, url)
        }
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("On This Device")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(rows, id: \.kind) { row in
                    mediaRow(kind: row.kind, media: row.media, url: row.url)
                    if row.kind != rows.last?.kind {
                        Divider()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
        }
    }

    @ViewBuilder
    private func mediaRow(kind: TrackKind, media: MediaFile, url: URL) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(kind == .audio ? "Audio" : "Video")
                    .font(.footnote.weight(.semibold))
                Text("\(media.codec.uppercased()) · \(media.container)\(fileSizeSuffix(url))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if media.shrunk {
                    Label("Shrunk", systemImage: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if ShrinkSupport.runner == nil {
                    Text("Shrink isn't available in this build yet.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if !media.shrunk {
                Button("Shrink") { shrinkKind = kind }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(ShrinkSupport.runner == nil)
            }
        }
    }

    private func fileSizeSuffix(_ url: URL) -> String {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64 else {
            return ""
        }
        return " · " + ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    // MARK: - Source / match details

    @ViewBuilder
    private func detailsSection(for item: MediaItem) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            sourceDetails(for: item)
            if let audio = item.info.match.audio {
                matchDetails(title: "Audio Match", note: audio)
            }
            if let video = item.info.match.video {
                matchDetails(title: "Video Match", note: video)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
    }

    @ViewBuilder
    private func sourceDetails(for item: MediaItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Source")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(item.info.source.origin.capitalized)
                .font(.footnote)
            if let url = item.info.source.url {
                Text(url)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if let isrc = item.info.source.isrc {
                Text("ISRC \(isrc)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// A collapsible breakdown of why this file was matched — strategy,
    /// score, and how many candidates were considered. Collapsed by
    /// default since most people never need to see it; there for the
    /// times something looks like a mismatch and you want to know why.
    private func matchDetails(title: String, note: MatchNote) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                if let query = note.query {
                    Text("Query: \(query)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let score = note.effectiveScore {
                    Text("Score: \(String(format: "%.2f", score.total))")
                        .font(.footnote)
                    scoreBreakdown(score.parts)
                }
                if let considered = note.considered, !considered.isEmpty {
                    Text("\(considered.count) candidate\(considered.count == 1 ? "" : "s") considered")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if note.waveformApplied == true {
                    Text("Waveform correlation applied")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 4)
        } label: {
            HStack {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(strategyLabel(note.strategy))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func strategyLabel(_ strategy: String) -> String {
        switch strategy {
        case "provided_youtube_id": "Direct pick"
        case "fallback_url": "Fallback"
        case "weighted_search": "Weighted search"
        default: strategy
        }
    }

    @ViewBuilder
    private func scoreBreakdown(_ parts: MatchScoreParts) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            scoreLine("Title", parts.title)
            scoreLine("Artist", parts.artist)
            scoreLine("Duration", parts.duration)
            scoreLine("Keywords", parts.keywords)
            scoreLine("Channel", parts.channel)
            scoreLine("Waveform", parts.waveform)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func scoreLine(_ label: String, _ value: Double?) -> some View {
        if let value {
            Text("\(label): \(String(format: "%.2f", value))")
        }
    }

    private func playNow(item: MediaItem, kind: TrackKind) {
        queue.append(QueueEntry(playable: .library(item), kind: kind))
        queue.jump(to: queue.entries.count - 1)
        player.play()
    }
}
