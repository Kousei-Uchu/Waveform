import SwiftUI
import WaveformBackendKit

/// A heart toggle bound to `PlaylistStore`'s liked-songs set. Uses a
/// text+icon `Label` (not just an icon) so it reads properly as a normal
/// menu row both visually and to VoiceOver.
struct LikeButton: View {
    let item: MediaItem
    @EnvironmentObject private var playlists: PlaylistStore

    var body: some View {
        Button {
            playlists.toggleLiked(item)
        } label: {
            Label(
                playlists.isLiked(item) ? "Unlike" : "Like",
                systemImage: playlists.isLiked(item) ? "heart.fill" : "heart"
            )
        }
        .accessibilityValue(playlists.isLiked(item) ? "Liked" : "")
    }
}

/// A submenu listing every playlist with an "add" action, plus a quick
/// "New Playlist" action. Meant to be used as menu content:
/// `Menu("Add to Playlist") { AddToPlaylistMenuItems(item: item) }`.
///
/// Deliberately doesn't prompt for a name inline — presenting an `.alert`
/// from state that lives inside a `Menu`'s content is unreliable in
/// SwiftUI. New playlists get a default name here and can be renamed from
/// `PlaylistsView`, where the alert is attached at the view level instead.
struct AddToPlaylistMenuItems: View {
    let item: MediaItem
    @EnvironmentObject private var playlists: PlaylistStore

    var body: some View {
        ForEach(playlists.playlists) { playlist in
            Button(playlist.name) {
                playlists.addItem(item, to: playlist)
            }
        }
        if !playlists.playlists.isEmpty {
            Divider()
        }
        Button("New Playlist") {
            let playlist = playlists.createPlaylist(name: nextDefaultName())
            playlists.addItem(item, to: playlist)
        }
    }

    private func nextDefaultName() -> String {
        let existing = Set(playlists.playlists.map(\.name))
        guard existing.contains("New Playlist") else { return "New Playlist" }
        var n = 2
        while existing.contains("New Playlist \(n)") { n += 1 }
        return "New Playlist \(n)"
    }
}
