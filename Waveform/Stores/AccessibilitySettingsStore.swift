//
//  AccessibilitySettingsStore.swift
//  Waveform
//
//  Created by Aiden McGovern (School) on 9/9/2026.
//


import Foundation
import SwiftUI

/// User-facing accessibility/appearance overrides. Mirrors `PaletteStore`'s
/// singleton pattern (`.shared`) rather than `PlaybackSettingsStore`'s
/// environment-only one, because these toggles need to be read from places
/// that aren't wired into the SwiftUI environment at all — `Helpers.swift`'s
/// `LiquidGlass` view and `PaletteStore` itself both read `.shared` directly,
/// the same way they already read `PaletteStore.shared`. It's still handed
/// into the environment too (`WaveformApp`), so `SettingsView` can bind its
/// toggles to it normally.
public final class AccessibilitySettingsStore: ObservableObject {
    public static let shared = AccessibilitySettingsStore()

    /// Swaps body text to OpenDyslexic where views opt in via
    /// `Font.appBody`/`Font.appPreferred(_:)` (see `Font+Accessibility.swift`).
    /// This does **not** retroactively change every `.font(...)` call
    /// already hardcoded to a system text style elsewhere in the app —
    /// only call sites written against the `Font.app...` helpers respond
    /// to this toggle. Requires the actual OpenDyslexic font files to be
    /// added to the target and registered in Info.plist's
    /// `UIAppFonts`/`ATSApplicationFontsPath` — this store only flips the
    /// preference, it can't bundle a font it doesn't have.
    @Published public var useOpenDyslexicFont: Bool {
        didSet { UserDefaults.standard.set(useOpenDyslexicFont, forKey: Keys.openDyslexic) }
    }

    /// When true, `liquidGlassIfAvailable(...)` always takes its
    /// pre-iOS-26 fallback path (a plain material/background) even on
    /// devices that support real Liquid Glass — for people who find the
    /// translucency/motion distracting, or just prefer flat surfaces.
    @Published public var disableLiquidGlass: Bool {
        didSet { UserDefaults.standard.set(disableLiquidGlass, forKey: Keys.disableGlass) }
    }

    /// When true, `PaletteStore.currentTint`/`currentSecondaryTint` report
    /// `nil` regardless of what's actually been extracted from artwork —
    /// every existing call site in the app is already written as
    /// `palette.currentTint ?? .stableAccent` (and the secondary
    /// equivalent), so returning `nil` here makes the whole app fall back
    /// to the fixed system-theme accent/secondary colors for free,
    /// without needing to touch each call site individually.
    @Published public var disableAccentColorSwapping: Bool {
        didSet { UserDefaults.standard.set(disableAccentColorSwapping, forKey: Keys.disableAccentSwap) }
    }

    private enum Keys {
        static let openDyslexic = "waveform.accessibility.useOpenDyslexicFont"
        static let disableGlass = "waveform.accessibility.disableLiquidGlass"
        static let disableAccentSwap = "waveform.accessibility.disableAccentColorSwapping"
    }

    private init() {
        let defaults = UserDefaults.standard
        self.useOpenDyslexicFont = defaults.bool(forKey: Keys.openDyslexic)
        self.disableLiquidGlass = defaults.bool(forKey: Keys.disableGlass)
        self.disableAccentColorSwapping = defaults.bool(forKey: Keys.disableAccentSwap)
    }
}
