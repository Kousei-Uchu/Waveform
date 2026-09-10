import SwiftUI
import WaveformBackendKit

/// Rewritten for v3 (§8): the old vault/single-file-import flow and
/// `MediaLibrary`-era stats ("Archives", "Duplicates Merged") are gone —
/// everything now arrives through the Search & Download screen, and the
/// library is one managed folder owned by `LibraryStore`/`VaultStore`.
/// Adds the three things spec §8 calls for that didn't exist before:
/// Spotify client id/secret + optional Genius token, a default download
/// resolution cap, and the Shrink AV1/Opus knobs (scoped to Shrink now,
/// not the download hot path — see `PlaybackSettingsStore`).
struct SettingsView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var vaultStore: VaultStore
    @EnvironmentObject private var settings: PlaybackSettingsStore
    @EnvironmentObject private var acquireSettings: AcquireSettingsStore
    @EnvironmentObject private var accessibility: AccessibilitySettingsStore

    #if os(macOS)
    @State private var showingFolderImporter = false
    #endif

    private let crossfadeOptions: [TimeInterval] = [0, 3, 6, 10]

    /// Shared glass panel used as each Section's `listRowBackground` so
    /// sections read as distinct frosted cards instead of one flat sheet
    /// (or a plain black rect once the Form's own background is hidden).
    ///
    /// Deliberately unrounded: a `RoundedRectangle` here would bake corners
    /// into *every row*, not just the section's outer edges — that's what
    /// produced the bumpy, non-joining seams. A flat `Rectangle` lets the
    /// Form's own grouped-style clipping round only the section as a whole,
    /// same as the system default look with a plain color/material fill.
    private var sectionGlassBackground: some View {
        Rectangle()
            .liquidGlassIfAvailable(in: Rectangle(), tinted: true)
    }

    var body: some View {
        NavigationStack {
            Form {
                librarySection
                acquireSection
                downloadsSection
                shrinkSection
                playbackSection
                accessibilitySection
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("Settings")
#if os(iOS)
.containerBackground(.clear, for: .navigation)
#endif
#if os(macOS)
            .fileImporter(
                isPresented: $showingFolderImporter,
                allowedContentTypes: [.folder]
            ) { result in
                if case .success(let url) = result {
                    vaultStore.relocate(to: url)
                }
            }
#endif
        }
    }

    // MARK: - Library

    @ViewBuilder
    private var librarySection: some View {
        Section {
            LabeledContent("Folder", value: vaultStore.libraryRootURL.lastPathComponent)
            #if os(macOS)
            Button("Change Library Folder…") { showingFolderImporter = true }
            #endif
            if let error = vaultStore.lastError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            LabeledContent("Items", value: "\(library.items.count)")
            LabeledContent("Albums", value: "\(library.albums.count)")
            LabeledContent("Artists", value: "\(library.artists.count)")
        } header: {
            Text("Library")
        } footer: {
            #if os(iOS)
            Text("Your library lives in this app's folder in the Files app, under \"On My iPhone → Waveform.\" Everything arrives through the Search tab — there's no separate import step.")
            #else
            Text("Everything arrives through the Search tab — there's no separate import step.")
            #endif
        }
        .listRowBackground(sectionGlassBackground)
    }

    // MARK: - Search & Download credentials (§8)

    @ViewBuilder
    private var acquireSection: some View {
        Section {
            LabeledContent {
                SecureField("Optional", text: $acquireSettings.geniusToken)
                    .multilineTextAlignment(.trailing)
            } label: {
                Text("Genius Token")
            }
            Toggle("Conservative Matching", isOn: $acquireSettings.conservativeMatching)
        } header: {
            Text("Search & Download")
        } footer: {
            Text(acquireFooter)
        }
        .listRowBackground(sectionGlassBackground)
    }

    private var acquireFooter: String {
        var lines = ["Spotify search requires a client id and secret from Spotify's developer dashboard. Genius is optional — it improves music-video matching when configured."]
        lines.append("Conservative Matching holds back a download whose audio or video match scored too low to trust, asking first instead of guessing — if only one of audio/video is confident, the other is skipped until you confirm.")
        return lines.joined(separator: " ")
    }

    // MARK: - Downloads

    @ViewBuilder
    private var downloadsSection: some View {
        Section {
            Picker("Resolution Cap", selection: $settings.downloadResolutionCap) {
                ForEach(DownloadResolutionCap.allCases) { cap in
                    Text(cap.label).tag(cap)
                }
            }
        } header: {
            Text("Downloads")
        } footer: {
            Text("Constrains which stream variant is picked when you download video — a selection filter, not a re-encode. Downloads always keep whatever codec YouTube served (§3); this just bounds file size up front. Audio downloads are never capped. You can override this per-download from the Search tab.")
        }
        .listRowBackground(sectionGlassBackground)
    }

    // MARK: - Shrink (§3)

    @ViewBuilder
    private var shrinkSection: some View {
        Section {
            Stepper(value: $settings.shrinkAV1CRF, in: 0...63) {
                LabeledContent("AV1 Quality (CRF)", value: "\(settings.shrinkAV1CRF)")
            }
            Stepper(value: $settings.shrinkAV1Preset, in: 0...13) {
                LabeledContent("AV1 Preset", value: "\(settings.shrinkAV1Preset)")
            }
            Stepper(value: $settings.shrinkOpusBitrateKbps, in: 64...320, step: 16) {
                LabeledContent("Opus Bitrate", value: "\(settings.shrinkOpusBitrateKbps) kbps")
            }
        } header: {
            Text("Shrink")
        } footer: {
            Text("These are the starting values offered on an item's Shrink screen — the rare re-encode-to-AV1/Opus action for an oversized download, not something every download pays for. Lower CRF and lower preset numbers mean higher quality and larger files; higher Opus bitrate means better audio quality and larger files.")
        }
        .listRowBackground(sectionGlassBackground)
    }

    // MARK: - Playback

    @ViewBuilder
    private var playbackSection: some View {
        Section {
            Toggle("Normalize Volume", isOn: $settings.normalizeVolume)
            Picker("Crossfade", selection: $settings.crossfadeDuration) {
                ForEach(crossfadeOptions, id: \.self) { duration in
                    Text(duration == 0 ? "Off" : "\(Int(duration))s").tag(duration)
                }
            }
        } header: {
            Text("Playback")
        } footer: {
            Text("Normalize Volume turns down tracks that are louder than average; it can't boost quiet tracks. Crossfade overlaps the end of one track with the start of the next — audio only.")
        }
        .listRowBackground(sectionGlassBackground)
    }

    // MARK: - Accessibility

    @ViewBuilder
    private var accessibilitySection: some View {
        Section {
            Toggle("Use OpenDyslexic Font", isOn: $accessibility.useOpenDyslexicFont)
            Toggle("Disable Liquid Glass", isOn: $accessibility.disableLiquidGlass)
            Toggle("Disable Accent Color Swapping", isOn: $accessibility.disableAccentColorSwapping)
        } header: {
            Text("Accessibility")
        } footer: {
            Text("OpenDyslexic requires the font to be added to the app first — this only sets the preference. Disabling accent color swapping keeps tint colors fixed to the app's default theme instead of shifting per track. Disabling Liquid Glass replaces frosted surfaces with a plain material.")
        }
        .listRowBackground(sectionGlassBackground)
    }
}
