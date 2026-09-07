import Foundation

/// The five/six weighted components of a match score. Reused for both
/// `parts` (the actual measured values) and `weights` (how much each part
/// counted for a given score) — same shape, different meaning, per the
/// spec.
public struct MatchScoreParts: Codable, Hashable, Sendable {
    public var title: Double?
    public var artist: Double?
    public var duration: Double?
    public var keywords: Double?
    public var channel: Double?
    public var waveform: Double?
    /// Relative view-count signal (0.25...1, log-scaled against the other
    /// candidates in the same ranking pass) — added alongside `Match.swift`
    /// (this pass) to carry over `matcher.js`'s `views` weight (0.22, tied
    /// for second-highest), which the original port of this struct had
    /// dropped. Optional/absent-safe like the rest of these fields so old
    /// `library.json` entries persisted before this field existed still
    /// decode fine.
    public var views: Double?

    public init(
        title: Double? = nil,
        artist: Double? = nil,
        duration: Double? = nil,
        keywords: Double? = nil,
        channel: Double? = nil,
        waveform: Double? = nil,
        views: Double? = nil
    ) {
        self.title = title
        self.artist = artist
        self.duration = duration
        self.keywords = keywords
        self.channel = channel
        self.waveform = waveform
        self.views = views
    }
}

public struct MatchScore: Codable, Hashable, Sendable {
    public var total: Double
    public var parts: MatchScoreParts
    public var weights: MatchScoreParts

    public init(total: Double, parts: MatchScoreParts, weights: MatchScoreParts) {
        self.total = total
        self.parts = parts
        self.weights = weights
    }
}

/// One ranked candidate from `match.*.considered` (top 8, best-first).
public struct MatchCandidate: Codable, Hashable, Sendable {
    public var title: String
    public var url: String
    public var total: Double
    public var parts: MatchScoreParts

    public init(title: String, url: String, total: Double, parts: MatchScoreParts) {
        self.title = title
        self.url = url
        self.total = total
        self.parts = parts
    }
}

/// `match.audio` / `match.video` — one of three shapes depending on
/// `strategy`:
/// - `"provided_youtube_id"` — direct pick, no search; only `strategy` is set.
/// - `"fallback_url"` — search found nothing usable; only `strategy` is set.
/// - `"weighted_search"` — the common case; `query`/`score`/`considered` are
///   set, and for video-with-waveform, `waveformApplied`/`winner` too.
///
/// Modeled as one struct with optional fields rather than three separate
/// types since which fields are present is fully determined by `strategy`,
/// and callers generally want to switch on `strategy` anyway.
public struct MatchNote: Codable, Hashable, Sendable {
    public var strategy: String
    public var query: String?
    public var score: MatchScore?
    public var considered: [MatchCandidate]?
    public var waveformApplied: Bool?
    public var winner: MatchScore?

    enum CodingKeys: String, CodingKey {
        case strategy, query, score, considered
        case waveformApplied = "waveform_applied"
        case winner
    }

    public init(
        strategy: String,
        query: String? = nil,
        score: MatchScore? = nil,
        considered: [MatchCandidate]? = nil,
        waveformApplied: Bool? = nil,
        winner: MatchScore? = nil
    ) {
        self.strategy = strategy
        self.query = query
        self.score = score
        self.considered = considered
        self.waveformApplied = waveformApplied
        self.winner = winner
    }

    /// The score to actually show/rank by — `winner` (post-waveform, when
    /// present) takes priority over the pre-waveform `score`, per the spec's
    /// note that these can differ.
    public var effectiveScore: MatchScore? { winner ?? score }
}

/// The `match` block — present keys depend on `mode`.
public struct MediaMatch: Codable, Hashable, Sendable {
    public var audio: MatchNote?
    public var video: MatchNote?

    public init(audio: MatchNote? = nil, video: MatchNote? = nil) {
        self.audio = audio
        self.video = video
    }
}
