//
//  WCAGCompliance.swift
//  Waveform
//
//  Created by Aiden McGovern (School) on 9/9/2026.
//


import SwiftUI

/// Direct port of the WCAG 2.x relative-luminance/contrast-ratio formulas
/// (same math the reference JS `getLuminance`/`getContrastRatio` used),
/// operating on `Color` instead of hex strings so it composes with
/// `PaletteStore`'s already-extracted `Color` values without a round-trip
/// through hex.
public struct WCAGCompliance: Sendable, Equatable {
    public let ratio: Double
    /// 4.5:1 — normal-sized text.
    public let aaNormal: Bool
    /// 3:1 — large text (18pt+, or 14pt+ bold).
    public let aaLarge: Bool
    /// 7:1 — normal-sized text.
    public let aaaNormal: Bool
    /// 4.5:1 — large text.
    public let aaaLarge: Bool

    fileprivate init(ratio: Double) {
        self.ratio = (ratio * 100).rounded() / 100 // matches the reference's `toFixed(2)`
        self.aaNormal = ratio >= 4.5
        self.aaLarge = ratio >= 3.0
        self.aaaNormal = ratio >= 7.0
        self.aaaLarge = ratio >= 4.5
    }
}

extension Color {
    /// WCAG relative luminance (0...1). Same per-channel sRGB→linear
    /// transform as the reference `channelLuminance`, applied to each of
    /// R/G/B and combined with the standard 0.2126/0.7152/0.0722 weights.
    var wcagRelativeLuminance: Double {
        let (r, g, b, _) = rgba01Components()
        func channel(_ value: Double) -> Double {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
    }

    /// (lighter luminance + 0.05) / (darker luminance + 0.05) — the WCAG
    /// contrast ratio formula, symmetric regardless of call order.
    func wcagContrastRatio(against other: Color) -> Double {
        let lum1 = wcagRelativeLuminance
        let lum2 = other.wcagRelativeLuminance
        let lighter = max(lum1, lum2)
        let darker = min(lum1, lum2)
        return (lighter + 0.05) / (darker + 0.05)
    }

    /// Full AA/AAA breakdown for `self` used as text/foreground against
    /// `background`. Direct equivalent of the reference `checkReadability`.
    func wcagCompliance(against background: Color) -> WCAGCompliance {
        WCAGCompliance(ratio: wcagContrastRatio(against: background))
    }

    /// Whichever of pure white or pure black reads better as text over
    /// `self` used as a background — the "using white vs black" check —
    /// along with that pairing's full compliance breakdown.
    func bestReadableTextColor() -> (color: Color, compliance: WCAGCompliance) {
        let whiteCompliance = wcagCompliance(against: .white)
        let blackCompliance = wcagCompliance(against: .black)
        return whiteCompliance.ratio >= blackCompliance.ratio
            ? (.white, whiteCompliance)
            : (.black, blackCompliance)
    }

    /// Automatic correction: if neither white nor black text would reach
    /// `minimumRatio` against `self`, nudge `self`'s own brightness toward
    /// whichever extreme (darker, favoring white text; lighter, favoring
    /// black text) reaches compliance fastest, and return the corrected
    /// color. Hue and saturation are preserved — this only trades
    /// brightness for legibility, so a corrected accent still reads as
    /// "the same color," just shifted enough to be usable as a background.
    ///
    /// Returns `self` unchanged if it already passes, or if simulation
    /// hits pure black/white without reaching `minimumRatio` (a
    /// vanishingly rare case, since white-on-black is always 21:1) — in
    /// that failure case, a `nil` in the returned tuple's `pairing` marks
    /// that white/black were both re-evaluated as the fallback.
    func wcagCorrected(minimumRatio: Double = 4.5, step: Double = 0.02) -> Color {
        let (_, initialCompliance) = bestReadableTextColor()
        guard initialCompliance.ratio < minimumRatio else { return self }

        let (hue, saturation, brightness, alpha) = hsbaComponents()

        // Try darkening (helps white-text contrast) and lightening (helps
        // black-text contrast) independently; each stops as soon as it
        // reaches `minimumRatio` or hits its brightness bound. Whichever
        // required fewer steps to reach compliance is the smaller visual
        // change, so it wins.
        let darkened = searchBrightness(hue: hue, saturation: saturation, startBrightness: brightness, alpha: alpha, direction: -1, step: step, minimumRatio: minimumRatio)
        let lightened = searchBrightness(hue: hue, saturation: saturation, startBrightness: brightness, alpha: alpha, direction: 1, step: step, minimumRatio: minimumRatio)

        switch (darkened, lightened) {
        case (let d?, let l?):
            return d.stepsFromOriginal <= l.stepsFromOriginal ? d.color : l.color
        case (let d?, nil):
            return d.color
        case (nil, let l?):
            return l.color
        case (nil, nil):
            // Neither direction reached the target ratio at all — return
            // whichever extreme (pure black or pure white brightness) got
            // furthest, rather than silently giving up and returning the
            // original non-compliant color.
            return brightness > 0.5 ? Color(hue: hue, saturation: saturation, brightness: 0, opacity: alpha) : Color(hue: hue, saturation: saturation, brightness: 1, opacity: alpha)
        }
    }

    // MARK: - Private

    private func searchBrightness(
        hue: Double,
        saturation: Double,
        startBrightness: Double,
        alpha: Double,
        direction: Double, // -1 darkening, +1 lightening
        step: Double,
        minimumRatio: Double
    ) -> (color: Color, stepsFromOriginal: Int)? {
        var brightness = startBrightness
        var steps = 0
        let maxSteps = Int(1.0 / step) + 1

        while steps < maxSteps {
            brightness = min(max(brightness + direction * step, 0), 1)
            steps += 1
            let candidate = Color(hue: hue, saturation: saturation, brightness: brightness, opacity: alpha)
            let (_, compliance) = candidate.bestReadableTextColor()
            if compliance.ratio >= minimumRatio {
                return (candidate, steps)
            }
            if brightness <= 0 || brightness >= 1 { return nil }
        }
        return nil
    }

    private func rgba01Components() -> (red: Double, green: Double, blue: Double, alpha: Double) {
        #if canImport(UIKit)
        let native = UIColor(self)
        #elseif canImport(AppKit)
        let native = NSColor(self).usingColorSpace(.deviceRGB) ?? NSColor(self)
        #endif
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        native.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Double(r), Double(g), Double(b), Double(a))
    }

    private func hsbaComponents() -> (hue: Double, saturation: Double, brightness: Double, alpha: Double) {
        #if canImport(UIKit)
        let native = UIColor(self)
        #elseif canImport(AppKit)
        let native = NSColor(self).usingColorSpace(.deviceRGB) ?? NSColor(self)
        #endif
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        native.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return (Double(hue), Double(saturation), Double(brightness), Double(alpha))
    }
}