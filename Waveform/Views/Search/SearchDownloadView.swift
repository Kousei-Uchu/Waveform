import SwiftUI
import WaveformBackendKit

/// The Search & Download screen (§8): free-text search (or a pasted
/// YouTube/Spotify link) whose results are immediately playable via
/// streaming, with a per-track Download action that promotes a result
/// into the permanent library (§4, stream-copy by default — §3).
struct SearchDownloadView: View {
    @EnvironmentObject private var queue: PlaybackQueue
    @EnvironmentObject private var player: MediaPlayerController
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var acquireSettings: AcquireSettingsStore
    @EnvironmentObject private var playbackSettings: PlaybackSettingsStore

    @State private var query = ""
    @State private var result: SearchResult?
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?

    /// Candidates that aren't YouTube-backed on their own (Spotify search
    /// results) need an async weighted-search resolve before they're
    /// playable at all (§4/§8) — resolved once per candidate and cached
    /// here so a row's Play/Download state stays consistent between taps.
    @State private var resolvedRefs: [String: RemoteRef] = [:]
    /// Same idea as `resolvedRefs`, but for the independently-matched
    /// video source used by the "Watch" action — see
    /// `resolvedVideoRef(for:)`. Kept separate because the audio and
    /// video matches for the same candidate can legitimately resolve to
    /// two different YouTube videos.
    @State private var resolvedVideoRefs: [String: RemoteRef] = [:]
    @State private var resolving: Set<String> = []
    @State private var resolveErrors: [String: String] = [:]

    var body: some View {
        NavigationStack {
            Group {
                if let result, !result.groups.isEmpty {
                    resultsList(result)
                } else if isSearching {
                    ProgressView("Searching…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    emptyState
                }
            }
            .navigationTitle("Search & Download")
#if os(iOS)
.containerBackground(.clear, for: .navigation)
#endif
            .searchable(text: $query, prompt: "Search, or paste a YouTube/Spotify link")
            .onChange(of: query) { _ in scheduleSearch() }
        }
    }

    private func resultsList(_ result: SearchResult) -> some View {
        List {
            ForEach(result.groups) { group in
                Section(group.label) {
                    if let error = group.error {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if group.label == "Playlist" {
                        Button {
                            Task {
                                for item in result.items {
                                    await download(item)
                                }
                            }
                        } label: {
                            Label("Download All", systemImage: "square.and.arrow.down.on.square.fill")
                                .font(.body.weight(.semibold)) // Helps visibility against lensed backgrounds
                                .foregroundStyle(.primary)
                                .padding(.vertical, 14)       // Gives breathing room inside the 3D bubble
                                .frame(maxWidth: .infinity)
                                // 1. Apply the glass effect directly to the content layer for native depth mapping
                                .liquidGlassIfAvailable(in: .capsule, isInteractive: true)
                        }
                        .buttonStyle(.plain) // Prevents standard list button highlights from interfering
                        // 2. Add padding to separate the capsule from row edges, triggering edge aberration
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        // 3. Keep the underlying system row perfectly empty
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                    }
                    Group {
                        ForEach(group.items) { candidate in
                            SearchResultRow(
                                candidate: candidate,
                                ref: resolvedRefs[candidate.id] ?? candidate.remoteRef(),
                                isResolving: resolving.contains(candidate.id),
                                resolveError: resolveErrors[candidate.id],
                                downloadState: (resolvedRefs[candidate.id] ?? candidate.remoteRef())
                                    .map { downloads.state(for: $0) } ?? .idle,
                                confidenceIssue: (resolvedRefs[candidate.id] ?? candidate.remoteRef())
                                    .flatMap { downloads.confidenceIssues[$0.id] },
                                onPlay: { play(candidate) },
                                onWatch: { playVideo(candidate) },
                                onDownload: { Task { await download(candidate) } },
                                onDownloadAnyway: { Task { await download(candidate, forceAll: true) } }
                            )
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets())
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
                    .liquidGlassIfAvailable(in: .rect(cornerRadius: 16), isInteractive: true)
                    .listRowBackground(Color.clear)
                }
            }
            .listRowBackground(Color.clear)
        }
        #if os(iOS)
        .listRowSpacing(4)
        #endif
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }
    
    func waitForDownloadToFinish(for item: SearchCandidate) async {
        // 1. Safely unwrap the optional RemoteRef
        guard let remoteRef = (resolvedRefs[item.id] ?? item.remoteRef()) else {
            print("Skipping download check: RemoteRef is nil")
            return
        }
        
        // 2. Poll the state using the unwrapped remoteRef
        while true {
            let state = downloads.state(for: remoteRef)
            
            // 3. Check for your completion state
            if state == .done { // 👈 Replace .completed with your actual enum case (e.g., .finished, .success)
                break
            }
            
            // Pause briefly before checking again to avoid pegging the CPU
            try? await Task.sleep(for: .seconds(0.5))
        }
    }


    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Search YouTube and Spotify")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Search

    private func scheduleSearch() {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            result = nil
            isSearching = false
            return
        }
        searchTask = Task {
            // Debounce so every keystroke doesn't fire a network search.
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            isSearching = true
            let outcome = await Search.pipeline(query: trimmed, spotify: acquireSettings.spotifyClient)
            guard !Task.isCancelled else { return }
            result = outcome
            isSearching = false
        }
    }

    // MARK: - Resolving a candidate to a playable RemoteRef

    /// A YouTube-origin candidate already carries everything needed
    /// (`SearchCandidate.remoteRef()`). A Spotify-origin one has no
    /// playable media of its own — it needs a weighted (optionally
    /// Genius-assisted) search for a backing YouTube video first
    /// (`Match.pickAudioSource`/`pickVideoSource`), same as the old
    /// pipeline did before a download could even start.
    private func resolvedRef(for candidate: SearchCandidate) async -> RemoteRef? {
        // A direct YouTube pick already carries everything needed
        // (`raw == matched`, so `ArtworkSelection` just hands back the
        // candidate's own thumbnail — this call is here for consistency,
        // not because it changes anything in this branch). No search
        // happened, so it's trusted outright (`matchConfident` defaults
        // to `true`).
        if let ref = candidate.remoteRef(artworkURLOverride: ArtworkSelection.preferredArtworkURL(raw: candidate)) {
            return ref
        }
        if let cached = resolvedRefs[candidate.id] { return cached }

        let target = MatchTarget(
            title: candidate.title,
            author: candidate.author,
            durationMS: candidate.durationMS,
            intent: .audio
        )
        let pick = await Match.pickAudioSource(for: candidate, target: target)
        // Prefer the original Spotify candidate's own (reliably
        // higher-res, correctly-cropped) album art over whatever
        // thumbnail the matched YouTube video happens to have — see
        // `ArtworkSelection`'s doc comment.
        let artworkURL = ArtworkSelection.preferredArtworkURL(raw: candidate, matched: pick.candidate)
        guard let ref = pick.candidate.remoteRef(
            artworkURLOverride: artworkURL,
            matchConfident: pick.confident,
            matchNote: Match.matchNote(for: pick)
        ) else { return nil }
        resolvedRefs[candidate.id] = ref
        return ref
    }

    /// Separately matches a *video* source for `candidate` — used by the
    /// "Watch" action so streaming a video actually goes through
    /// `Match.pickVideoSource` (Genius-assisted when configured, §4)
    /// instead of there being no way to stream remote video at all. A
    /// direct YouTube pick is trusted as-is (it's already the exact video
    /// tapped in search results); a Spotify-origin candidate has no video
    /// of its own and needs the real match.
    private func resolvedVideoRef(for candidate: SearchCandidate) async -> RemoteRef? {
        if candidate.origin == .youtube {
            let ref = candidate.remoteRef(
                availableKinds: [.video],
                artworkURLOverride: ArtworkSelection.preferredArtworkURL(raw: candidate)
            )
            if let ref { resolvedVideoRefs[candidate.id] = ref }
            return ref
        }
        if let cached = resolvedVideoRefs[candidate.id] { return cached }

        let target = MatchTarget(
            title: candidate.title,
            author: candidate.author,
            durationMS: candidate.durationMS,
            intent: .video
        )
        let videoPick = await Match.pickVideoSource(for: candidate, target: target, genius: acquireSettings.geniusClient)
        guard !videoPick.skip, let pick = videoPick.sourcePick else { return nil }
        let artworkURL = ArtworkSelection.preferredArtworkURL(raw: candidate, matched: pick.candidate)
        guard let ref = pick.candidate.remoteRef(
            availableKinds: [.video],
            artworkURLOverride: artworkURL,
            matchConfident: pick.confident,
            matchNote: Match.matchNote(for: pick)
        ) else {
            return nil
        }
        resolvedVideoRefs[candidate.id] = ref
        return ref
    }

    private func play(_ candidate: SearchCandidate) {
        Task {
            resolving.insert(candidate.id)
            resolveErrors[candidate.id] = nil
            defer { resolving.remove(candidate.id) }
            guard let ref = await resolvedRef(for: candidate) else {
                resolveErrors[candidate.id] = "Couldn't find a playable source for this."
                return
            }
            queue.append(QueueEntry(playable: .remote(ref), kind: .audio))
            queue.jump(to: queue.entries.count - 1)
            player.play()
        }
    }

    /// Streams a music video for `candidate` without downloading it
    /// first — previously there was no code path that created a
    /// `.video`-kind queue entry for a `.remote` playable at all, so
    /// "watching" anything not already downloaded just showed the
    /// artwork fallback in Now Playing (`NowPlayingView` only swaps in
    /// the real video renderer once `player.currentKind == .video`).
    private func playVideo(_ candidate: SearchCandidate) {
        Task {
            resolving.insert(candidate.id)
            resolveErrors[candidate.id] = nil
            defer { resolving.remove(candidate.id) }
            guard let ref = await resolvedVideoRef(for: candidate) else {
                resolveErrors[candidate.id] = "Couldn't find a music video for this."
                return
            }
            queue.append(QueueEntry(playable: .remote(ref), kind: .video))
            queue.jump(to: queue.entries.count - 1)
            player.play()
        }
    }

    private func download(_ candidate: SearchCandidate, forceAll: Bool = false) async {
        resolving.insert(candidate.id)
        resolveErrors[candidate.id] = nil
        defer { resolving.remove(candidate.id) }

        guard let ref = await resolvedRef(for: candidate) else {
            resolveErrors[candidate.id] = "Couldn't find a playable source for this."
            return
        }

        await downloads.download(
            ref,
            kinds: ref.availableKinds,
            capOverride: playbackSettings.downloadResolutionCap,
            forceKinds: forceAll ? ref.availableKinds : []
        )
    }
}

/// One search result: thumbnail, title/author/duration, and Play/Download
/// actions. Shows a spinner while an unresolved Spotify candidate is
/// being matched to a YouTube source, and reflects `DownloadManager`'s
/// live state (idle/downloading/done/failed) on the Download button once
/// a `RemoteRef` exists to key that state by.
private struct SearchResultRow: View {
    let candidate: SearchCandidate
    let ref: RemoteRef?
    let isResolving: Bool
    let resolveError: String?
    let downloadState: DownloadManager.State
    var confidenceIssue: DownloadManager.ConfidenceIssue?
    let onPlay: () -> Void
    let onWatch: () -> Void
    let onDownload: () -> Void
    var onDownloadAnyway: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            row
            if let confidenceIssue {
                confidenceWarning(confidenceIssue)
            }
        }
    }

    private var row: some View {
        HStack(spacing: 12) {
            thumbnail
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.title).lineLimit(1)
                Text(candidate.author)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let resolveError {
                    Text(resolveError)
                        .font(.caption2)
                        .foregroundStyle(.red)
                } else if case .failed(let message) = downloadState {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
            }

            Spacer()

            if isResolving {
                ProgressView()
            } else {
                HStack(spacing: 16) {
                    Button(action: onWatch) {
                        Image(systemName: "play.rectangle")
                            .padding(8)
                            .liquidGlassIfAvailable(in: .rect(cornerRadius: 8), isInteractive: true)
                    }
                    .buttonStyle(.plain) // Prevents standard list button highlights from interfering
                    // 2. Add padding to separate the capsule from row edges, triggering edge aberration
                    // 3. Keep the underlying system row perfectly empty
                    .listRowBackground(Color.clear)
                    .accessibilityLabel("Watch music video")
                    

                    downloadButton
                }
            }
        }
        .onTapGesture { onPlay() }
    }

    @ViewBuilder
    private func confidenceWarning(_ issue: DownloadManager.ConfidenceIssue) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Text(issue.message)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
            if let onDownloadAnyway {
                Button("Download Anyway", action: onDownloadAnyway)
                    .font(.caption2.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private var downloadButton: some View {
        switch downloadState {
        case .idle:
            Button(action: onDownload) {
                Image(systemName: "arrow.down.circle")
                    .padding(8)
                    .liquidGlassIfAvailable(in: .capsule, isInteractive: true)
            }
            .buttonStyle(.plain) // Prevents standard list button highlights from interfering
            // 2. Add padding to separate the capsule from row edges, triggering edge aberration
            // 3. Keep the underlying system row perfectly empty
            .listRowBackground(Color.clear)
            .accessibilityLabel("Download")
            
        case .downloading(let progress):
            if let fraction = progress?.fraction {
                ProgressView(value: fraction)
                    .frame(width: 32)
            } else {
                ProgressView()
            }
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityLabel("Downloaded")
        case .failed:
            Button(action: onDownload) {
                Image(systemName: "exclamationmark.arrow.circlepath")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
            .accessibilityLabel("Retry download")
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let url = candidate.thumbnailURL {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().aspectRatio(contentMode: .fill)
                } else {
                    placeholder
                }
            }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            Image(systemName: "music.note")
                .foregroundStyle(.secondary)
        }
    }
}
