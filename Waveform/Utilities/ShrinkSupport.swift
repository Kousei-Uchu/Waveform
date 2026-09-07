import Foundation
import WaveformBackendKit

/// The one place the app decides whether Shrink (§3) actually has an
/// `FFmpegRunning` implementation to call. Currently `nil`: §9's
/// `kingslay/FFmpegKit` dependency is still commented out in
/// `Package.swift` (it needs the manual `swift package --disable-sandbox
/// BuildFFmpeg` step run once in Xcode before it's importable — see that
/// file's comment and `Shrink.swift`'s `FFmpegKitRunner` sketch).
///
/// `ItemDetailView`'s Shrink action is written and wired end-to-end
/// against `FFmpegRunning` already, so flipping this from `nil` to
/// `FFmpegKitRunner()` (once that type is uncommented in `Shrink.swift`
/// and the package actually resolves) is the only change needed to turn
/// Shrink on for real — no UI/view-model work left to do at that point.
enum ShrinkSupport {
    static let runner: FFmpegRunning? = nil
}

/// Retroactive conformance so `ItemDetailView` can drive its Shrink sheet
/// with `.sheet(item:)` (one sheet, keyed on which kind was tapped)
/// instead of a separate `Bool` + stored-kind pair.
extension TrackKind: Identifiable {
    public var id: String { rawValue }
}
