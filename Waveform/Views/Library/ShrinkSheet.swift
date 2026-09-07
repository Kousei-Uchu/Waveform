import Foundation
import SwiftUI
import WaveformBackendKit

/// The "Shrink" screen (§3/§8): re-encodes one already-downloaded
/// audio or video file to Opus/AV1 in place, with the CRF/preset/bitrate
/// knobs pre-filled from `PlaybackSettingsStore`'s defaults but
/// overridable per-item, matching the spec's "letting the user trigger
/// re-encode with the AV1/Opus knobs" (with the option to override
/// per-item).
struct ShrinkSheet: View {
    let item: MediaItem
    let kind: TrackKind
    let sourceURL: URL
    let currentMedia: MediaFile
    let runner: FFmpegRunning

    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss

    @State private var crf: Int
    @State private var preset: Int
    @State private var bitrateKbps: Int
    @State private var isRunning = false
    @State private var errorMessage: String?

    init(item: MediaItem, kind: TrackKind, sourceURL: URL, currentMedia: MediaFile, runner: FFmpegRunning, defaults: Shrink.Options) {
        self.item = item
        self.kind = kind
        self.sourceURL = sourceURL
        self.currentMedia = currentMedia
        self.runner = runner
        _crf = State(initialValue: defaults.av1CRF)
        _preset = State(initialValue: defaults.av1Preset)
        _bitrateKbps = State(initialValue: defaults.opusBitrateKbps)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Currently on Disk") {
                    LabeledContent("Codec", value: currentMedia.codec.uppercased())
                    LabeledContent("Container", value: currentMedia.container)
                    if let size = currentFileSize {
                        LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                    }
                }

                if kind == .video {
                    Section {
                        Stepper(value: $crf, in: 0...63) {
                            LabeledContent("Quality (CRF)", value: "\(crf)")
                        }

                        Stepper(value: $preset, in: 0...13) {
                            LabeledContent("Preset", value: "\(preset)")
                        }
                    } header: {
                        Text("AV1 Video")
                    } footer: {
                        Text("Lower quality numbers and lower presets mean bigger, higher-quality files.")
                    }
                }

                Section {
                    Stepper(value: $bitrateKbps, in: 64...320, step: 16) {
                        LabeledContent("Bitrate", value: "\(bitrateKbps) kbps")
                    }
                } header: {
                    Text("Opus Audio")
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Shrink \(kind == .video ? "Video" : "Audio")")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isRunning)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isRunning {
                        ProgressView()
                    } else {
                        Button("Shrink") { run() }
                    }
                }
            }
            .interactiveDismissDisabled(isRunning)
#if os(iOS)
.containerBackground(.clear, for: .navigation)
#endif
        }
    }

    private var currentFileSize: Int64? {
        (try? FileManager.default.attributesOfItem(atPath: sourceURL.path))?[.size] as? Int64
    }

    private func run() {
        isRunning = true
        errorMessage = nil
        let options = Shrink.Options(av1CRF: crf, av1Preset: preset, opusBitrateKbps: bitrateKbps)
        Task { @MainActor in
            do {
                let destination: URL
                switch kind {
                case .video:
                    destination = try await Shrink.shrinkVideo(at: sourceURL, options: options, runner: runner)
                case .audio:
                    destination = try await Shrink.shrinkAudio(at: sourceURL, options: options, runner: runner)
                }
                let newMedia = Shrink.mediaFile(for: kind, downloadCap: currentMedia.downloadCap)
                try library.replaceFile(forItemID: item.info.id, kind: kind, newFileURL: destination, newMedia: newMedia)
                isRunning = false
                dismiss()
            } catch {
                isRunning = false
                errorMessage = error.localizedDescription
            }
        }
    }
}
