import SwiftUI

// NOTE: this used to be a `ViewModifier` with `@ObservedObject private var
// palette = PaletteStore.shared` inside `body(content:)`. That doesn't
// reliably re-render — `ViewModifier.body` doesn't get the same guaranteed
// dependency-tracking SwiftUI gives an actual `View`'s `body`. Wrapping the
// content in a real `View` fixes it.
private struct LiquidGlass<Content: View, S: Shape>: View {
    let shape: S
    let isInteractive: Bool
    let tinted: Bool
    @ViewBuilder let content: () -> Content

    // Owned by an actual View now — this is what reliably re-renders when
    // currentTint changes.
    @ObservedObject private var palette = PaletteStore.shared

    var body: some View {
        #if compiler(>=6.0)
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, tvOS 26.0, watchOS 26.0, *) {
            content().glassEffect(resolvedGlass, in: shape)
                .animation(.easeInOut(duration: 1), value: palette.currentTint)
        } else {
            content().background(Color.clear)
        }
        #else
        content().background(Color.clear)
        #endif
    }

    @available(iOS 26.0, macOS 26.0, visionOS 26.0, tvOS 26.0, watchOS 26.0, *)
    private var resolvedGlass: Glass {
        var glass: Glass = tinted ? .clear.tint(palette.currentTint?.opacity(1) ?? .stableAccent.opacity(1)) : .clear
        if isInteractive { glass = glass.interactive() }
        return glass
    }
}

extension View {
    /// Applies the native Liquid Glass effect if available on the current platform, otherwise falls back to a clear background.
    /// - Parameters:
    ///   - shape: The shape to apply the glass background into.
    ///   - isInteractive: Enables native fluid reactions, light reflections, and squish states on tap/hover.
    ///   - tinted: Applies the current palette tint to the glass instead of the plain `.regular` variant.
    func liquidGlassIfAvailable<S: Shape>(
        in shape: S,
        isInteractive: Bool = false,
        tinted: Bool = false
    ) -> some View {
        LiquidGlass(shape: shape, isInteractive: isInteractive, tinted: tinted) { self }
    }

    /// Convenience overload that applies Liquid Glass inside the default Capsule shape if available.
    func liquidGlassIfAvailable(isInteractive: Bool = false, tinted: Bool = false) -> some View {
        LiquidGlass(shape: Capsule(), isInteractive: isInteractive, tinted: tinted) { self }
    }
}

extension Color {
    /// Convenience hex initializer. If you already have a `Color(hex:)` or
    /// `Color(paletteHex:)` initializer elsewhere in the project (e.g.
    /// `PaletteStore.swift`), don't duplicate this — just point
    /// `randomPaletteColors` at whichever one you keep.
    init?(hex: String) {
        var value = hex
        if value.hasPrefix("#") { value.removeFirst() }
        guard let rgba = UInt64(value, radix: 16) else { return nil }

        let r, g, b: Double
        switch value.count {
        case 6:
            r = Double((rgba & 0xFF0000) >> 16) / 255
            g = Double((rgba & 0x00FF00) >> 8) / 255
            b = Double(rgba & 0x0000FF) / 255
        case 8:
            r = Double((rgba & 0xFF00_0000) >> 24) / 255
            g = Double((rgba & 0x00FF_0000) >> 16) / 255
            b = Double((rgba & 0x0000_FF00) >> 8) / 255
        default:
            return nil
        }
        self.init(red: r, green: g, blue: b)
    }

    /// A large, curated set of distinct, reasonably vibrant hex colors —
    /// useful for placeholder artwork, avatar backgrounds, demo/preview
    /// data, chart series, etc. Deliberately avoids near-duplicate hues
    /// clustering in one spot on the wheel.
    static let paletteHexes: [String] = [
        // Reds / pinks
        "E63946", "D62828", "F94144", "FF6B6B", "E5383B", "C9184A", "FF4D6D", "FB6F92",
        "F72585", "D00000", "9D0208", "780000",
        // Oranges
        "F3722C", "F8961E", "F9844A", "FB8500", "FFB703", "F77F00", "E85D04", "DC2F02",
        // Yellows
        "FFD60A", "FFCA3A", "FFE066", "F9C74F", "FFDD00", "EAB308",
        // Greens
        "90BE6D", "43AA8B", "4D908E", "2D6A4F", "40916C", "52B788", "74C69D", "80ED99",
        "38B000", "70E000", "9EF01A", "606C38",
        // Teals / cyans
        "277DA1", "168AAD", "1A759F", "34A0A4", "0A9396", "005F73", "00B4D8", "48CAE4",
        "90E0EF", "ADE8F4",
        // Blues
        "3A86FF", "4361EE", "4895EF", "4CC9F0", "023E8A", "0077B6", "1D3557", "457B9D",
        "5390D9", "6930C3",
        // Purples / violets
        "7209B7", "7B2CBF", "9D4EDD", "C77DFF", "B5179E", "560BAD", "480CA8", "3A0CA3",
        "8338EC", "5F0F40",
        // Neutrals with personality (not pure gray)
        "6D6875", "B5838D", "E5989B", "FFB4A2", "FFCDB2", "735D78",
    ]

    /// A random color from `paletteHexes`. Force-unwrapped because every
    /// entry above is a valid, hand-checked 6-digit hex string — if you
    /// add entries, keep that guarantee or switch this to return `Color?`.
    static var randomPalette: Color {
        Color(hex: paletteHexes.randomElement()!)!
    }

    /// Deterministic variant — same input always maps to the same palette
    /// color, useful for e.g. "give this playlist/artist a stable color
    /// based on its id" instead of a fresh random one every render.
    static func stablePaletteColor(seed: some Hashable) -> Color {
        var hasher = Hasher()
        hasher.combine(seed)
        let index = abs(hasher.finalize()) % paletteHexes.count
        return Color(hex: paletteHexes[index])!
    }

    /// A random shade "near" `color` — each RGB channel is jittered
    /// independently by up to `±maxVariance` (on a 0...255 scale, same
    /// scale hex digits use), then clamped back into range. Alpha is
    /// preserved as-is, not jittered.
    ///
    /// `maxVariance: 0` always returns the exact input color back.
    /// `maxVariance: 255` can in principle land anywhere, since every
    /// channel's full range becomes reachable — it's a soft radius, not a
    /// hard guarantee of visible similarity at the high end.
    static func randomShade(of color: Color, maxVariance: Int = 40) -> Color {
        let variance = Double(min(max(maxVariance, 0), 255))
        let (r, g, b, a) = color.rgba255Components()

        func jittered(_ component: Double) -> Double {
            let delta = Double.random(in: -variance...variance)
            return min(max(component + delta, 0), 255)
        }

        return Color(
            red: jittered(r) / 255,
            green: jittered(g) / 255,
            blue: jittered(b) / 255,
            opacity: a
        )
    }
}

private extension Color {
    /// RGBA on a 0...255 scale (alpha stays 0...1) — matches the scale hex
    /// strings and `maxVariance` are expressed in, so callers don't have to
    /// think in 0...1 floats when reasoning about "how far can this drift."
    func rgba255Components() -> (red: Double, green: Double, blue: Double, alpha: Double) {
        #if canImport(UIKit)
        let native = UIColor(self)
        #elseif canImport(AppKit)
        let native = NSColor(self).usingColorSpace(.deviceRGB) ?? NSColor(self)
        #endif
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        native.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Double(r) * 255, Double(g) * 255, Double(b) * 255, Double(a))
    }
}
