import SwiftUI
import PaletteKit

@MainActor
final class PaletteStore: ObservableObject {
    static let shared = PaletteStore()

    enum SwatchKind: String, CaseIterable, Sendable {
        case dominant
        case vibrant
        case muted
        case darkVibrant
        case darkMuted
        case lightVibrant
        case lightMuted
    }

    // MARK: - Backwards-compatible surface

    @Published private var cache: [String: Color] = [:]
    @Published private var secondaryCache: [String: Color] = [:]

    /// The item currently considered "on screen" for tinting purposes.
    /// Set this (e.g. on track change) — `currentTint` derives itself live
    /// from this + `cache`, so it can never go stale while an async
    /// `load(itemID:image:)` is still in flight for this item. (A
    /// previous version snapshotted `currentTint` once at the moment the
    /// track changed, before the color had actually been extracted yet —
    /// that value then never updated once the load finished.)
    @Published var currentItemID: String?

    var currentTint: Color? {
        currentItemID.flatMap { cache[$0] }
    }

    /// The paired "contrast" color for the current item — drawn from the
    /// same swatch pool as `currentTint`, chosen for standing apart from it
    /// (hue + brightness distance) rather than for being independently
    /// interesting. Falls back to a synthesized complement only if nothing
    /// else in the image's swatches qualifies.
    var currentSecondaryTint: Color? {
        currentItemID.flatMap { secondaryCache[$0] }
    }

    func color(for itemID: String) -> Color? {
        cache[itemID]
    }

    func secondaryColor(for itemID: String) -> Color? {
        secondaryCache[itemID]
    }

    func load(itemID: String, image: PlatformImage) {
        guard cache[itemID] == nil else { return }

        Task {
            guard let source = imageSource(from: image), let cgImage = cgImage(from: image) else { return }
            do {
                async let paletteTask = extractor.palette(from: source)
                async let swatchesTask = extractor.swatches(from: source)
                let (palette, swatches) = try await (paletteTask, swatchesTask)

                guard cache[itemID] == nil else { return }
                palettes[itemID] = palette
                swatchMaps[itemID] = swatches

                let pair = accentPair(dominant: palette.dominant, swatches: swatches, sourceImage: cgImage)
                cache[itemID] = pair.primary
                secondaryCache[itemID] = pair.secondary
            } catch {
                // leave uncached
            }
        }
    }

    // MARK: - New: specific swatch kinds

    /// Fetch a specific swatch color for an item, once `load` has completed.
    /// `fallback` is PaletteKit's own `PaletteColor` type (matching what
    /// `SwatchMap.color(for:fallback:)` actually requires) so no lossy
    /// Color↔PaletteColor bridging happens on the way in.
    func color(for itemID: String, kind: SwatchKind, fallback: PaletteColor = .black) -> Color? {
        guard kind != .dominant else { return cache[itemID] }
        guard let swatches = swatchMaps[itemID] else { return nil }
        let paletteColor = rawSwatchColor(swatches, kind, fallback: fallback)
        return Color(paletteHex: paletteColor.hex)
    }

    /// Contrast-safe text/icon color over a given swatch.
    func textColor(for itemID: String, over kind: SwatchKind, fallback: PaletteColor = .black) -> Color {
        guard kind != .dominant, let swatches = swatchMaps[itemID] else {
            return Color(paletteHex: fallback.hex) ?? .clear
        }
        let textColor = rawTitleTextColor(swatches, kind, fallback: fallback)
        return Color(paletteHex: textColor.hex) ?? .clear
    }

    // MARK: - Forwards-compatible escape hatch

    func palette(for itemID: String) -> Palette? {
        palettes[itemID]
    }

    func swatchMap(for itemID: String) -> SwatchMap? {
        swatchMaps[itemID]
    }

    // MARK: - Private

    private let extractor = PaletteExtractor()
    private var palettes: [String: Palette] = [:]
    private var swatchMaps: [String: SwatchMap] = [:]

    private func imageSource(from image: PlatformImage) -> ImageSource? {
        #if os(macOS)
        guard let tiff = image.tiffRepresentation else { return nil }
        return .data(tiff)
        #else
        guard let cgImage = image.cgImage else { return nil }
        return .cgImage(cgImage)
        #endif
    }

    /// CGImage bridging used for pixel-prominence sampling. Separate from
    /// `imageSource(from:)` above (which feeds PaletteKit's own extractor
    /// and prefers TIFF data on macOS) — this always needs an actual
    /// `CGImage` to draw into a sampling context.
    private func cgImage(from image: PlatformImage) -> CGImage? {
        #if os(macOS)
        var rect = CGRect(x: 0, y: 0, width: image.size.width, height: image.size.height)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        #else
        return image.cgImage
        #endif
    }

    /// Switches on our own SwatchKind and writes the role as a bare `.case`
    /// at each call site, so Swift infers PaletteKit's actual role type
    /// from `color(for:fallback:)`'s parameter — we never have to name it.
    private func rawSwatchColor(_ swatches: SwatchMap, _ kind: SwatchKind, fallback: PaletteColor) -> PaletteColor {
        switch kind {
        case .dominant: fatalError("dominant has no swatch role")
        case .vibrant: return swatches.color(for: .vibrant, fallback: fallback)
        case .muted: return swatches.color(for: .muted, fallback: fallback)
        case .darkVibrant: return swatches.color(for: .darkVibrant, fallback: fallback)
        case .darkMuted: return swatches.color(for: .darkMuted, fallback: fallback)
        case .lightVibrant: return swatches.color(for: .lightVibrant, fallback: fallback)
        case .lightMuted: return swatches.color(for: .lightMuted, fallback: fallback)
        }
    }

    /// Same trick, for `titleTextColor(for:fallback:)`.
    private func rawTitleTextColor(_ swatches: SwatchMap, _ kind: SwatchKind, fallback: PaletteColor) -> PaletteColor {
        switch kind {
        case .dominant: fatalError("dominant has no swatch role")
        case .vibrant: return swatches.titleTextColor(for: .vibrant, fallback: fallback)
        case .muted: return swatches.titleTextColor(for: .muted, fallback: fallback)
        case .darkVibrant: return swatches.titleTextColor(for: .darkVibrant, fallback: fallback)
        case .darkMuted: return swatches.titleTextColor(for: .darkMuted, fallback: fallback)
        case .lightVibrant: return swatches.titleTextColor(for: .lightVibrant, fallback: fallback)
        case .lightMuted: return swatches.titleTextColor(for: .lightMuted, fallback: fallback)
        }
    }

    // MARK: - Interesting-color selection (primary + secondary)

    private struct ScoredCandidate {
        let kind: SwatchKind
        let color: Color
        let hue: Double
        let saturation: Double
        let brightness: Double
        let prominence: Double
    }

    /// Picks a primary accent color and a secondary "contrast" color, both
    /// drawn from the image's actual extracted swatches.
    ///
    /// Primary prefers saturated, moderately-bright swatches — what
    /// "vibrant" usually means — but never disqualifies a dark color
    /// outright, and is weighted by how much of the image the color
    /// actually covers (see `pixelProminence`) so a tiny fleck of color
    /// can't outscore a color that dominates a mostly-dark image.
    ///
    /// Secondary is chosen from the same pool (excluding primary's own
    /// swatch role), scored for hue + brightness distance from primary
    /// rather than for being independently interesting, and still
    /// prominence-gated for the same reason.
    ///
    /// `dominant` (PaletteKit's raw pixel-count winner) is only used as a
    /// last resort if every named swatch role is missing or filtered out.
    private func accentPair(dominant: PaletteColor?, swatches: SwatchMap, sourceImage: CGImage) -> (primary: Color, secondary: Color) {
        let candidateKinds: [SwatchKind] = [.lightVibrant, .vibrant, .darkVibrant, .lightMuted, .muted, .darkMuted]
        let sample = pixelSample(of: sourceImage, dimension: 40)

        var candidates: [ScoredCandidate] = []
        for kind in candidateKinds {
            let raw = rawSwatchColor(swatches, kind, fallback: .black)
            // PaletteKit hands back our own fallback (.black) when a role
            // wasn't actually present in the image — skip those rather
            // than scoring "true black" as if it were a real swatch.
            let normalizedHex = raw.hex.replacingOccurrences(of: "#", with: "").lowercased()
            guard normalizedHex != "000000", let color = Color(paletteHex: raw.hex) else { continue }

            let (hue, saturation, brightness) = hsbComponents(of: color)
            let prominence = pixelProminence(of: color, in: sample)
            candidates.append(ScoredCandidate(kind: kind, color: color, hue: hue, saturation: saturation, brightness: brightness, prominence: prominence))
        }

        let fallbackColor = dominant.flatMap { Color(paletteHex: $0.hex) } ?? .black

        guard let primary = candidates.max(by: { interestScore(for: $0) < interestScore(for: $1) }) else {
            return (fallbackColor, fallbackColor.pleasantComplement())
        }

        let secondaryPool = candidates.filter { $0.kind != primary.kind }
        let secondary = secondaryPool.max(by: {
            contrastScore(candidate: $0, against: primary) < contrastScore(candidate: $1, against: primary)
        })

        return (primary.color, secondary?.color ?? primary.color.pleasantComplement())
    }

    /// Weighted mostly toward saturation (that's what makes a color read
    /// as "vibrant" rather than muddy), with a smaller brightness term so
    /// that, among similarly-saturated candidates, the brighter one wins.
    /// Extremes get penalized: near-black rarely reads as an accent even
    /// if technically saturated, and near-white is never vibrant regardless
    /// of saturation. `prominence` then gates the whole thing — a small
    /// saturated fleck gets heavily discounted; a saturated color that
    /// covers real area keeps most of its score.
    private func interestScore(for candidate: ScoredCandidate) -> Double {
        let base = candidate.saturation * 0.75 + candidate.brightness * 0.25
        let darkPenalty = candidate.brightness < 0.15 ? (0.15 - candidate.brightness) * 2 : 0
        let blownOutPenalty = candidate.brightness > 0.95 ? (candidate.brightness - 0.95) * 4 : 0
        let visualScore = base - darkPenalty - blownOutPenalty

        // Floor of 0.35 so a genuinely-vibrant-but-modest area (say 15% of
        // the image) isn't crushed to near-zero just for not being the
        // majority — only truly negligible slivers get hit hard. Raise the
        // `* 4` multiplier below to require more coverage before a color
        // gets full credit.
        let prominenceWeight = 0.35 + 0.65 * min(candidate.prominence * 4, 1.0)

        return visualScore * prominenceWeight
    }

    /// Rewards hue distance from primary (circular, so 0.5 apart is max)
    /// and brightness separation (so text/background pairing actually
    /// works), then gates by the same prominence weight as `interestScore`
    /// — a contrasting color that barely appears in the image isn't a
    /// useful secondary color either.
    private func contrastScore(candidate: ScoredCandidate, against primary: ScoredCandidate) -> Double {
        var hueDelta = abs(candidate.hue - primary.hue)
        if hueDelta > 0.5 { hueDelta = 1.0 - hueDelta } // circular wrap
        let hueContrast = hueDelta * 2.0 // normalize 0...0.5 -> 0...1

        let brightnessContrast = abs(candidate.brightness - primary.brightness)

        let rawContrast = hueContrast * 0.6 + brightnessContrast * 0.4
        let prominenceWeight = 0.35 + 0.65 * min(candidate.prominence * 4, 1.0)
        return rawContrast * prominenceWeight
    }

    private func hsbComponents(of color: Color) -> (hue: Double, saturation: Double, brightness: Double) {
        #if canImport(UIKit)
        let native = UIColor(color)
        #elseif canImport(AppKit)
        let native = NSColor(color).usingColorSpace(.deviceRGB) ?? NSColor(color)
        #endif
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        native.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return (Double(hue), Double(saturation), Double(brightness))
    }

    private func rgbComponents(of color: Color) -> (red: Double, green: Double, blue: Double) {
        #if canImport(UIKit)
        let native = UIColor(color)
        #elseif canImport(AppKit)
        let native = NSColor(color).usingColorSpace(.deviceRGB) ?? NSColor(color)
        #endif
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        native.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Double(r * 255), Double(g * 255), Double(b * 255))
    }

    // MARK: - Pixel sampling for prominence
    //
    // PaletteKit's public API (Palette / SwatchMap / PaletteColor) doesn't
    // expose a population/pixel-count per swatch the way Android's Palette
    // library does — so "how much of the image is actually this color" has
    // to be measured directly by drawing the source image into a small
    // sampling context and counting matching pixels.

    private func pixelSample(of cgImage: CGImage, dimension: Int) -> [UInt8] {
        var pixelData = [UInt8](repeating: 0, count: dimension * dimension * 4)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: &pixelData,
                width: dimension,
                height: dimension,
                bitsPerComponent: 8,
                bytesPerRow: dimension * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return pixelData }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: dimension, height: dimension))
        return pixelData
    }

    /// Fraction (0...1) of sampled pixels within a rough color-distance
    /// tolerance of `color`. Not exact segmentation — a blunt Euclidean RGB
    /// distance is enough to separate "covers a real chunk of the image"
    /// from "barely present."
    private func pixelProminence(of color: Color, in sample: [UInt8]) -> Double {
        guard !sample.isEmpty else { return 0 }
        let (cr, cg, cb) = rgbComponents(of: color)
        let threshold: Double = 60 // 0-255 per channel

        var matching = 0
        let totalPixels = sample.count / 4
        for i in 0..<totalPixels {
            let offset = i * 4
            let r = Double(sample[offset])
            let g = Double(sample[offset + 1])
            let b = Double(sample[offset + 2])
            let distance = (pow(r - cr, 2) + pow(g - cg, 2) + pow(b - cb, 2)).squareRoot()
            if distance < threshold { matching += 1 }
        }
        return Double(matching) / Double(totalPixels)
    }
}

private extension Color {
    init?(paletteHex hex: String) {
        var value = hex
        if value.hasPrefix("#") { value.removeFirst() }
        guard let rgba = UInt64(value, radix: 16) else { return nil }

        let hasAlpha = value.count == 8
        let r, g, b, a: Double
        if hasAlpha {
            r = Double((rgba & 0xFF00_0000) >> 24) / 255
            g = Double((rgba & 0x00FF_0000) >> 16) / 255
            b = Double((rgba & 0x0000_FF00) >> 8) / 255
            a = Double(rgba & 0x0000_00FF) / 255
        } else {
            r = Double((rgba & 0xFF_0000) >> 16) / 255
            g = Double((rgba & 0x00_FF00) >> 8) / 255
            b = Double(rgba & 0x00_00FF) / 255
            a = 1
        }
        self.init(red: r, green: g, blue: b, opacity: a)
    }

    /// A complementary color designed to look reasonable next to *any*
    /// input — used only as a last-resort fallback when no image swatch
    /// qualifies for `accentPair`'s secondary color.
    func pleasantComplement() -> Color {
        let (hue, saturation, brightness, alpha) = hsbaComponents()

        if saturation < 0.08 {
            let invertedBrightness = brightness > 0.5 ? 0.15 : 0.85
            return Color(hue: 0.09, saturation: 0.06, brightness: invertedBrightness, opacity: alpha)
        }

        var newHue = (hue + 0.5).truncatingRemainder(dividingBy: 1.0)
        let newSaturation = min(max(saturation, 0.35), 0.85)

        var newBrightness = brightness
        if abs(newBrightness - brightness) < 0.35 {
            newBrightness = brightness > 0.5 ? brightness - 0.4 : brightness + 0.4
        }
        newBrightness = min(max(newBrightness, 0.15), 0.95)

        newHue = (newHue + 0.02).truncatingRemainder(dividingBy: 1.0)

        return Color(hue: newHue, saturation: newSaturation, brightness: newBrightness, opacity: alpha)
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
