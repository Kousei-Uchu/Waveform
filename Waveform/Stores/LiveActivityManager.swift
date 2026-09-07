import Foundation
import Combine
import WaveformBackendKit

#if os(iOS)
import ActivityKit
import UIKit
#endif

/// Mirrors `MediaPlayerController`/`PlaybackQueue` state into a
/// Dynamic Island / Lock Screen Live Activity, Spotify-style. Lives in the
/// app layer (not `VaultDeckKit`) because ActivityKit is iOS-only and this
/// is platform/UI integration, not media-library backend logic.
@MainActor
final class LiveActivityManager: ObservableObject {
    #if os(iOS)
    private var activity: Activity<PlaybackActivityAttributes>?
    private var trackedItemID: String?
    private var cancellables: Set<AnyCancellable> = []
    #endif

    init() {}

    /// Call once at launch. Reacts to track changes and play/pause
    /// immediately; elapsed-time-only updates are throttled to once every
    /// 5 seconds so this isn't pushing a new Activity update dozens of
    /// times a second off the player's tick loop.
    func start(player: MediaPlayerController, queue: PlaybackQueue, artwork: ArtworkStore) {
        #if os(iOS)
        guard false else { return }
        guard #available(iOS 16.2, *) else { return }

        let immediate = queue.$currentIndex
            .combineLatest(player.$status)
            .map { _ in () }

        let throttled = player.$currentTime
            .throttle(for: .seconds(5), scheduler: DispatchQueue.main, latest: true)
            .map { _ in () }

        immediate.merge(with: throttled)
            .sink { [weak self] in
                guard let self else { return }
                Task { await self.sync(player: player, queue: queue, artwork: artwork) }
            }
            .store(in: &cancellables)
        #endif
    }

    #if os(iOS)
    @available(iOS 16.2, *)
    private func sync(player: MediaPlayerController, queue: PlaybackQueue, artwork: ArtworkStore) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        guard let entry = queue.current else {
            await endActivity()
            return
        }

        let artworkFilename = await writeSharedArtworkIfNeeded(for: entry.playable, artwork: artwork)
        let state = PlaybackActivityAttributes.ContentState(
            title: entry.playable.title,
            artist: entry.playable.author,
            isPlaying: player.status == .playing,
            elapsedSeconds: player.currentTime,
            durationSeconds: player.duration,
            artworkFilename: artworkFilename
        )
        let content = ActivityContent(state: state, staleDate: nil)

        if let activity, trackedItemID == entry.playable.id {
            await activity.update(content)
            return
        }

        // Either no activity yet, or the track changed under us — end
        // whatever was running and start fresh so the Dynamic Island swaps
        // to the new track immediately rather than waiting for an update.
        await endActivity()
        do {
            activity = try Activity.request(
                attributes: PlaybackActivityAttributes(itemID: entry.playable.id),
                content: content,
                pushType: nil
            )
            trackedItemID = entry.playable.id
        } catch {
            activity = nil
            trackedItemID = nil
        }
    }

    @available(iOS 16.2, *)
    private func endActivity() async {
        guard let activity else { return }
        await activity.end(activity.content, dismissalPolicy: .immediate)
        self.activity = nil
        trackedItemID = nil
    }

    /// Writes the current track's cover art into the shared App Group
    /// container as a JPEG, reusing the same fixed filename each time
    /// (only one Live Activity is ever active for this app, so there's no
    /// need to key it per track). Returns the filename on success, `nil`
    /// if there's no artwork, the App Group isn't set up, or `playable`
    /// is a not-yet-downloaded remote item (nothing local to read art
    /// from — a remote item's only artwork is a thumbnail URL, not a
    /// file `ArtworkStore` can load).
    private func writeSharedArtworkIfNeeded(for playable: Playable, artwork: ArtworkStore) async -> String? {
        guard let item = playable.libraryItem else { return nil }
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppGroup.identifier
        ) else {
            return nil
        }

        await artwork.load(for: item)
        guard let image = artwork.image(for: item), let data = image.jpegData(compressionQuality: 0.7) else {
            return nil
        }

        let filename = "now-playing-artwork.jpg"
        do {
            try data.write(to: containerURL.appendingPathComponent(filename), options: .atomic)
            return filename
        } catch {
            return nil
        }
    }
    #endif
}
