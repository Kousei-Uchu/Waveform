import Foundation

/// Handles `waveform://` URLs — currently just `waveform://now-playing`,
/// opened via `.widgetURL(...)` on the Dynamic Island / Live Activity.
/// `openNowPlayingRequestID` increments on each request rather than being
/// a plain `Bool` so a second tap while the sheet is already open still
/// triggers a fresh `.onChange`.
@MainActor
final class DeepLinkRouter: ObservableObject {
    @Published private(set) var openNowPlayingRequestID = 0

    func handle(_ url: URL) {
        guard url.scheme == "waveform", url.host == "now-playing" else { return }
        openNowPlayingRequestID += 1
    }
}
