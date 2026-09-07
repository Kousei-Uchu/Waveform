import Foundation

/// Pure text-normalization and fuzzy-scoring helpers shared by `Search`
/// and `Match` — a direct port of `CMF Pipeline/server/lib/text.js`, kept
/// in its own file for the same reason the old pipeline split it out of
/// `matcher.js`: none of this is YouTube/Spotify-specific, it's just
/// string munging that both the search-result mapping and the match
/// scoring need.
public enum TextMatching {

    /// Title/description noise phrases stripped before comparing two
    /// titles — "(Official Music Video)", "[Lyrics]", etc. Order doesn't
    /// matter; every pattern is applied.
    private static let noisePatterns: [String] = [
        #"official\s*(music\s*)?video"#,
        #"official\s*audio"#,
        #"official\s*lyric\s*video"#,
        #"lyric\s*video"#,
        #"visualizer"#,
        #"audio\s*only"#,
        #"hq\s*audio"#,
        #"topic"#,
        #"remaster(ed)?(\s*\d{2,4})?"#,
        #"\bhd\b"#,
        #"\b4k\b"#,
        #"\blyrics?\b"#,
        #"\(explicit\)"#,
        #"\[explicit\]"#,
    ]

    private static let bracketedNoisePattern =
        #"\s*[\[(][^)\]]*(official|audio|video|lyric|visualizer|hd|4k|topic)[^)\]]*[\])]\s*"#

    private static let trailingDashPattern = #"\s*[-–—]\s*$"#

    /// Lowercases, strips diacritics/apostrophes, and collapses everything
    /// that isn't a letter or digit down to single spaces — the shared
    /// normal form `diceCoefficient` compares against.
    public static func normalizeText(_ value: String) -> String {
        let folded = value.lowercased().folding(options: .diacriticInsensitive, locale: nil)
        let noApostrophes = folded.replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")
        let collapsed = noApostrophes.replacingOccurrences(
            of: #"[^\p{L}\p{N}]+"#,
            with: " ",
            options: .regularExpression
        )
        return collapsed.trimmingCharacters(in: .whitespaces)
    }

    /// Strips "(Official Video)"-style noise from a title, falling back to
    /// the original (trimmed) string if stripping would leave it empty.
    public static func stripTitleNoise(_ title: String) -> String {
        var t = title
        t = t.replacingOccurrences(of: bracketedNoisePattern, with: " ", options: [.regularExpression, .caseInsensitive])
        for pattern in noisePatterns {
            t = t.replacingOccurrences(of: pattern, with: " ", options: [.regularExpression, .caseInsensitive])
        }
        t = t.replacingOccurrences(of: trailingDashPattern, with: "", options: .regularExpression)
        let collapsed = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return collapsed.isEmpty ? title.trimmingCharacters(in: .whitespaces) : collapsed
    }

    /// YouTube Music auto-uploads often surface as "Artist - Topic" for the
    /// channel and "Song (Official Audio)" for the title — prefer a real
    /// artist name over either of those.
    public static func cleanArtistName(_ artist: String?, channel: String?, title: String?) -> String {
        var name = (artist?.isEmpty == false ? artist : channel) ?? ""
        name = name.trimmingCharacters(in: .whitespaces)
        name = name.replacingOccurrences(of: #"\s*-\s*topic$"#, with: "", options: [.regularExpression, .caseInsensitive])
        name = name.replacingOccurrences(of: #"\s*vevo$"#, with: "", options: [.regularExpression, .caseInsensitive])
        name = name.trimmingCharacters(in: .whitespaces)

        let looksEmpty = name.isEmpty
            || name.range(of: #"^topic$"#, options: [.regularExpression, .caseInsensitive]) != nil
            || (title ?? "").range(of: #"provided to youtube"#, options: [.regularExpression, .caseInsensitive]) != nil

        if looksEmpty {
            let fromTitle = (title ?? "").splitOnDashSeparator().first ?? ""
            name = stripTitleNoise(fromTitle)
        }
        return name.isEmpty ? "Unknown Artist" : name
    }

    /// Splits "Artist - Title" style raw titles, falling back to using the
    /// channel as the author when there's no dash-separated form (or the
    /// first segment looks like a "- Topic" auto-channel label).
    public static func parseArtistTitle(_ rawTitle: String, channel: String?) -> (author: String, title: String) {
        let title = rawTitle.trimmingCharacters(in: .whitespaces)
        let parts = title.splitOnDashSeparator()
        if parts.count >= 2, parts[0].range(of: "topic", options: .caseInsensitive) == nil {
            let author = cleanArtistName(parts[0], channel: channel, title: title)
            let restTitle = stripTitleNoise(parts.dropFirst().joined(separator: " - "))
            return (author, restTitle)
        }
        let author = cleanArtistName(channel, channel: channel, title: title)
        return (author, stripTitleNoise(title))
    }

    /// Sørensen–Dice bigram similarity, 0...1 — a cheap, diacritic- and
    /// case-insensitive fuzzy string match used for both title and artist
    /// comparisons in `Match.scoreCandidate`.
    public static func diceCoefficient(_ a: String, _ b: String) -> Double {
        let s1 = Array(normalizeText(a))
        let s2 = Array(normalizeText(b))
        if s1.isEmpty || s2.isEmpty { return 0 }
        if s1 == s2 { return 1 }
        if s1.count < 2 || s2.count < 2 { return s1 == s2 ? 1 : 0 }

        var bigrams: [String: Int] = [:]
        for i in 0..<(s1.count - 1) {
            let gram = String(s1[i...i + 1])
            bigrams[gram, default: 0] += 1
        }
        var overlap = 0
        for i in 0..<(s2.count - 1) {
            let gram = String(s2[i...i + 1])
            if let count = bigrams[gram], count > 0 {
                bigrams[gram] = count - 1
                overlap += 1
            }
        }
        return Double(2 * overlap) / Double((s1.count - 1) + (s2.count - 1))
    }

    /// 1.0 for an exact-enough duration match, decaying linearly to 0 by
    /// `window` seconds apart; `0.35` (neither confidently right nor
    /// wrong) when either duration is unknown.
    public static func durationScore(expectedSec: Double?, actualSec: Double?, window: Double = 120) -> Double {
        guard let expectedSec, let actualSec, expectedSec > 0, actualSec > 0 else { return 0.35 }
        let delta = abs(expectedSec - actualSec)
        if delta <= 2 { return 1 }
        if delta >= window { return 0 }
        return 1 - delta / window
    }

    /// Parses a YouTube-style clock string ("3:42", "1:02:03") or a bare
    /// number of seconds into seconds. Returns `nil` for anything else.
    public static func parseClockDuration(_ text: String?) -> Double? {
        guard let text, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let s = text.trimmingCharacters(in: .whitespaces)
        if let bare = Double(s) { return bare }
        let parts = s.split(separator: ":").map { Double($0) }
        guard parts.allSatisfy({ $0 != nil }) else { return nil }
        let values = parts.compactMap { $0 }
        switch values.count {
        case 3: return values[0] * 3600 + values[1] * 60 + values[2]
        case 2: return values[0] * 60 + values[1]
        default: return nil
        }
    }
}

private extension String {
    /// `" - "` / `" – "` / `" — "` (space-dash-space, any dash variant) —
    /// the separator `parseArtistTitle` splits "Artist - Title" raw
    /// titles on. A bare dash character-set (no space requirement) would
    /// also split words like "co-writer", so this matches the JS
    /// `/\s[-–—]\s/` regex exactly: a dash with a single space on both
    /// sides.
    func splitOnDashSeparator() -> [String] {
        let pattern = #"\s[-–—]\s"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [self] }
        let nsString = self as NSString
        var result: [String] = []
        var lastEnd = 0
        regex.enumerateMatches(in: self, range: NSRange(location: 0, length: nsString.length)) { match, _, _ in
            guard let match else { return }
            result.append(nsString.substring(with: NSRange(location: lastEnd, length: match.range.location - lastEnd)))
            lastEnd = match.range.location + match.range.length
        }
        result.append(nsString.substring(from: lastEnd))
        return result
    }
}
