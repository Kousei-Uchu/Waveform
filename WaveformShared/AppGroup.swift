import Foundation

/// The App Group shared between the main app and `WaveformWidgets`, used
/// to hand the current track's artwork file to the Live Activity (which
/// can't reach into a `.cmf` archive itself).
///
/// This identifier must exactly match what's registered in your Apple
/// Developer account and in **both** `Waveform/Waveform-iOS.entitlements`
/// and `WaveformWidgets/WaveformWidgets.entitlements` — all three need to
/// agree, or `containerURL(forSecurityApplicationGroupIdentifier:)` returns
/// `nil` on both sides and the Live Activity just shows no artwork.
enum AppGroup {
    static let identifier = "group.com.aspen.waveform"
}
