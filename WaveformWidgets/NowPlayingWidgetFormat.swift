//
//  NowPlayingWidgetFormat.swift
//  Waveform
//
//  Created by Aiden McGovern (School) on 10/9/2026.
//


import AppIntents
import WidgetKit

/// "Format" option: which layout the Home Screen widget renders. Only
/// affects the resizable `.systemSmall`/`.systemMedium`/`.systemLarge`
/// families — every Lock Screen/StandBy accessory family already has
/// exactly one system-mandated layout per family, so this has no visible
/// effect there (see `NowPlayingWidgetViews`).
public enum NowPlayingWidgetFormat: String, AppEnum {
    /// Artwork thumbnail + title/artist + transport controls, laid out
    /// side by side — the default, closest to how most system media
    /// widgets look.
    case card
    /// No artwork at all — just title/artist and transport, over the
    /// chosen colour background. Denser, and reads better at a glance for
    /// anyone who finds an extra image distracting.
    case compact
    /// Full-bleed album art as the entire background, with a scrim and
    /// minimal text/controls over it.
    case artworkFocused

    public static var typeDisplayRepresentation: TypeDisplayRepresentation = "Widget Format"
    public static var caseDisplayRepresentations: [NowPlayingWidgetFormat: DisplayRepresentation] = [
        .card: "Card (artwork + controls)",
        .compact: "Compact (text + controls only)",
        .artworkFocused: "Artwork Focused (full-bleed art)",
    ]
}

/// "Colour" option: where the widget's background colour comes from.
/// `.dynamic` is the actual "colour changing" behavior — the only one of
/// the three that varies per track — since `.accentColor` and
/// `.monochrome` are both deliberately track-independent, for anyone who
/// finds a shifting background distracting but still wants the widget.
public enum NowPlayingWidgetColorStyle: String, AppEnum {
    case dynamic
    case accentColor
    case monochrome

    public static var typeDisplayRepresentation: TypeDisplayRepresentation = "Colour Style"
    public static var caseDisplayRepresentations: [NowPlayingWidgetColorStyle: DisplayRepresentation] = [
        .dynamic: "Dynamic (matches album art)",
        .accentColor: "App Accent Colour",
        .monochrome: "Monochrome",
    ]
}

/// The widget's own per-instance configuration, set via the system's
/// "Edit Widget" sheet (long-press the widget → Edit Widget) — not
/// something whose `perform()` is ever meaningfully invoked the way a
/// button-tap intent's is; `AppIntentConfiguration`'s provider reads
/// these `@Parameter`s directly (as `context`'s `configuration`) when
/// building each timeline entry.
///
/// Lock Screen/StandBy accessory families ignore `format` (there's only
/// one layout per accessory family) but still honor `colorStyle` insofar
/// as the system allows (see `NowPlayingWidgetBackground`'s doc comment
/// on why accessory widgets can't actually go full-colour).
public struct NowPlayingWidgetConfigIntent: WidgetConfigurationIntent {
    public static var title: LocalizedStringResource = "Now Playing Options"
    public static var description = IntentDescription("Choose how the Now Playing widget looks.")

    @Parameter(title: "Format", default: .card)
    public var format: NowPlayingWidgetFormat

    @Parameter(title: "Colour", default: .dynamic)
    public var colorStyle: NowPlayingWidgetColorStyle

    public init() {
        self.format = .card
        self.colorStyle = .dynamic
    }

    public init(format: NowPlayingWidgetFormat, colorStyle: NowPlayingWidgetColorStyle) {
        self.format = format
        self.colorStyle = colorStyle
    }
}