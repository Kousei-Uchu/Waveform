import Foundation
import os

/// A track we're trying to find a YouTube source for — the Swift-side
/// `target` object threaded through the old pipeline's `matcher.js`/
/// `jobs.js`. `intent` decides which keyword bonus/penalty list applies
/// in `Match.scoreCandidate`.
public struct MatchTarget: Sendable {
    public var title: String
    public var author: String
    public var durationMS: Double?
    public var intent: TrackKind

    public init(title: String, author: String, durationMS: Double?, intent: TrackKind) {
        self.title = title
        self.author = author
        self.durationMS = durationMS
        self.intent = intent
    }
}

/// Mirrors `matcher.js`'s `WEIGHTS` exactly, `views` included (see the
/// amendment note on `MatchScoreParts`).
public struct MatchWeights: Sendable {
    public var title = 0.27
    public var artist = 0.18
    public var duration = 0.09
    public var keywords = 0.20
    public var channel = 0.20
    public var views = 0.22
    public var waveform = 0.15
}

public struct ScoredCandidate: Sendable {
    public var candidate: SearchCandidate
    public var total: Double
    public var parts: MatchScoreParts
}

/// A chosen source for one track/kind — the Swift-side return shape of
/// `jobs.js`'s `pickSource`.
public struct SourcePick: Sendable {
    public var candidate: SearchCandidate
    /// `true` when this pick bypasses the score threshold entirely
    /// (the raw item was already a direct YouTube pick, or Genius
    /// identified it) — the caller should trust it rather than checking
    /// `Match.qualifies`.
    public var forced: Bool
    public var ranked: [ScoredCandidate]
    public var strategy: String
    /// `Match.qualifies(_:)` run against the winning candidate — `true`
    /// for every `forced` pick (there's no ranking to check), otherwise
    /// reflects whether the #1-ranked candidate actually cleared the
    /// confidence floor. Previously nothing checked this at all:
    /// `weightedSearch` returned the top-ranked candidate unconditionally,
    /// so a thin/irrelevant result pool for an obscure artist could win
    /// with a low score and nobody downstream would know. Callers should
    /// treat `confident == false` as "this might be the wrong track" —
    /// worth surfacing to the user rather than silently downloading.
    public var confident: Bool
    /// The literal text (or ISRC) searched for, when this pick came from
    /// an actual search — `nil` for a direct/forced pick where no search
    /// happened at all. Carried here (rather than recomputed at the call
    /// site) so `Match.matchNote(for:)` can record it in the persisted
    /// `MatchNote.query` field without callers needing to know how each
    /// strategy built its query string.
    public var query: String?

    public init(
        candidate: SearchCandidate,
        forced: Bool,
        ranked: [ScoredCandidate],
        strategy: String,
        confident: Bool,
        query: String? = nil
    ) {
        self.candidate = candidate
        self.forced = forced
        self.ranked = ranked
        self.strategy = strategy
        self.confident = confident
        self.query = query
    }
}

/// Return shape of `Match.pickVideoSource` — mirrors `jobs.js`'s
/// `pickVideoSource` three-way outcome (see that function's doc comment
/// in the reference code): a normal/forced pick, or `skip` when Genius
/// has confirmed no official music video exists for this song at all.
public struct VideoPick: Sendable {
    public var sourcePick: SourcePick?
    public var skip: Bool
}

/// Weighted candidate scoring (a direct port of `matcher.js`) plus the
/// source-picking orchestration around it (`jobs.js`'s `pickSource` /
/// `pickVideoSource`), including the optional Genius-assisted video
/// lookup. `Search.swift` finds candidates; this decides which one is
/// actually the thing the user meant.
public enum Match {
    public static let weights = MatchWeights()

    /// Confidence floor below which a video candidate is treated as
    /// "probably not the thing we wanted" (fan edit, cover, reaction,
    /// lyric video) rather than forced through. Mirrors `jobs.js`'s
    /// env-tunable `MIN_VIDEO_MATCH_SCORE`/`MIN_VIDEO_KEYWORD_SCORE`,
    /// hardcoded here since there's no server env file in the app —
    /// Settings (§8) is the right place to expose these later if a real
    /// need for tuning them shows up.
    public static let minVideoMatchScore = 0.55
    public static let minVideoKeywordScore = 0.35

    /// `true` when a ranked candidate is confident enough to trust
    /// without Genius/forced backing — both the total score and the
    /// keyword signal specifically (the strongest available signal
    /// against fan edits/covers/reactions) need to clear their floors.
    public static func qualifies(_ scored: ScoredCandidate) -> Bool {
        scored.total >= minVideoMatchScore && (scored.parts.keywords ?? 0) >= minVideoKeywordScore
    }

    private static let videoBonusPatterns = [
        #"official\s*(music\s*)?video"#, #"music\s*video"#, #"\bomv\b"#, #"\bmv\b"#,
    ]
    private static let videoPenaltyPatterns = [
        #"lyric"#, #"audio\s*only"#, #"sped\s*up"#, #"nightcore"#, #"slowed"#, #"8d\s*audio"#,
        #"cover"#, #"karaoke"#, #"live\s*(at|from|on)"#, #"performance"#, #"reaction"#,
        #"hour\s*version"#, #"official\s*audio"#, #"provided to youtube"#, #"topic"#,
        #"visualizer"#, #"fan\s*(made|video|edit|art)"#, #"unofficial"#, #"tribute"#,
        #"type\s*beat"#, #"instrumental"#, #"\bremix\b"#, #"\bmashup\b"#, #"\bedit\b"#, #"\btiktok\b"#,
    ]
    private static let audioBonusPatterns = [
        #"official\s*audio"#, #"provided to youtube"#, #"topic"#, #"visualizer"#,
    ]
    /// `videoPenaltyPatterns` minus the four patterns that are actually
    /// *good* signals for an audio pick (`official audio`/`provided to
    /// youtube`/`topic`/`visualizer` — see `audioBonusPatterns` above)
    /// and minus `lyric`/`audio\s*only`, which describe perfectly usable
    /// audio. Everything left here (karaoke, instrumental, cover, live,
    /// remix, sped up/slowed/nightcore, etc.) is still exactly as
    /// undesirable for an audio pick as it is for a video one.
    private static let audioPenaltyPatterns = [
        #"sped\s*up"#, #"nightcore"#, #"slowed"#, #"8d\s*audio"#,
        #"cover"#, #"karaoke"#, #"live\s*(at|from|on)"#, #"performance"#, #"reaction"#,
        #"hour\s*version"#, #"fan\s*(made|video|edit|art)"#, #"unofficial"#, #"tribute"#,
        #"type\s*beat"#, #"instrumental"#, #"\bremix\b"#, #"\bmashup\b"#, #"\bedit\b"#, #"\btiktok\b"#,
    ]

    // MARK: - Scoring (matcher.js)

    /// Weighted match between `target` and one candidate. `waveform` is a
    /// 0...1 Pearson correlation of RMS envelopes from
    /// `WaveformCorrelation`, or `nil` when it hasn't been computed for
    /// this candidate — in which case the waveform weight is redistributed
    /// across the other parts rather than counted as a zero/bad score.
    public static func scoreCandidate(
        target: MatchTarget,
        candidate: SearchCandidate,
        waveform: Double? = nil,
        relativeViews: Double = 0.25
    ) -> ScoredCandidate {
        let targetTitle = TextMatching.stripTitleNoise(target.title)
        let candTitle = TextMatching.stripTitleNoise(candidate.title.isEmpty ? candidate.rawTitle : candidate.title)
        let title = TextMatching.diceCoefficient(targetTitle, candTitle)

        let artistHaystack = [candidate.author, candidate.channel, candidate.rawTitle, candidate.title]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let artist = max(
            artistIn(artistHaystack, artist: target.author),
            TextMatching.diceCoefficient(target.author, candidate.author)
        )

        let expectedSec = target.durationMS.map { $0 / 1000 }
        let actualSec = candidate.durationMS.map { $0 / 1000 }
        let duration = TextMatching.durationScore(expectedSec: expectedSec, actualSec: actualSec)

        let haystack = "\(candidate.rawTitle) \(candidate.title) \(candidate.channel ?? "")"
        let wantVideo = target.intent == .video
        let keywords = keywordScore(
            haystack,
            bonus: wantVideo ? videoBonusPatterns : audioBonusPatterns,
            penalty: wantVideo ? videoPenaltyPatterns : audioPenaltyPatterns
        )

        let channelName = candidate.channel ?? ""
        let channel: Double
        if channelName.range(of: "topic", options: .caseInsensitive) != nil {
            channel = wantVideo ? 0.2 : 0.9
        } else if channelName.range(of: "vevo", options: .caseInsensitive) != nil {
            channel = wantVideo ? 0.95 : 0.6
        } else {
            channel = 0.5
        }

        let wave = waveform ?? 0.5
        let useWave = waveform == nil ? 0 : weights.waveform
        let restScale = 1 - useWave

        let base =
            weights.title * title +
            weights.artist * artist +
            weights.duration * duration +
            weights.keywords * keywords +
            weights.views * relativeViews +
            weights.channel * channel
        let total = base * restScale + useWave * wave

        let parts = MatchScoreParts(
            title: title, artist: artist, duration: duration, keywords: keywords,
            channel: channel, waveform: waveform, views: relativeViews
        )
        return ScoredCandidate(candidate: candidate, total: total, parts: parts)
    }

    /// Ranks every candidate against `target`, best first.
    /// `waveforms[candidate.id]` supplies a precomputed correlation for
    /// whichever candidates `WaveformCorrelation` has already probed
    /// (typically just the top few, per the old pipeline's "waveform-match
    /// the top 3" behavior) — everything else scores with `waveform: nil`.
    public static func rankCandidates(
        target: MatchTarget,
        candidates: [SearchCandidate],
        waveforms: [String: Double] = [:]
    ) -> [ScoredCandidate] {
        let viewScores = relativeViewScores(candidates)
        return candidates.enumerated()
            .map { index, candidate in
                scoreCandidate(
                    target: target,
                    candidate: candidate,
                    waveform: waveforms[candidate.id],
                    relativeViews: viewScores[index]
                )
            }
            .sorted { $0.total > $1.total }
    }

    // MARK: - Source picking (jobs.js: pickSource / pickVideoSource)

    /// Picks an audio source for `target`. A YouTube-origin `raw` (the
    /// item the user actually tapped in Search & Download) is trusted
    /// directly, matching `pickSource`'s `provided_youtube_id` fast path.
    /// A Spotify-origin `raw` tries an ISRC search first when it has one
    /// (`isrcSearch` below) — a far stronger signal than free-text
    /// title/artist matching — and only falls back to the weighted
    /// text search when that doesn't land a confident pick (no ISRC, no
    /// results, or a duration mismatch). `youtubeSource` defaults to
    /// `Search.defaultYouTubeSource` — see that property's doc comment
    /// for the "use only YTM" switch.
    public static func pickAudioSource(
        for raw: SearchCandidate,
        target: MatchTarget,
        youtubeSource: YouTubeSearchSource = Search.defaultYouTubeSource
    ) async -> SourcePick {
        if raw.origin == .youtube {
            return SourcePick(candidate: raw, forced: true, ranked: [], strategy: "provided_youtube_id", confident: true)
        }
        if let isrc = raw.isrc, !isrc.isEmpty,
           let pick = await isrcSearch(isrc: isrc, raw: raw, target: target, youtubeSource: youtubeSource) {
            return pick
        }
        return await weightedSearch(for: raw, target: target, youtubeSource: youtubeSource)
    }

    /// Tries to resolve `target`'s audio by searching YouTube for its
    /// Spotify ISRC directly, rather than free-text title/artist —
    /// `raw.isrc` is only ever populated for a Spotify-origin candidate
    /// (`SpotifyClient.mapTrack`), so this is purely an audio-matching
    /// upgrade for Spotify-sourced searches, matches, and library items.
    /// An ISRC uniquely identifies the *recording*, and searching for it
    /// verbatim frequently surfaces the exact Content-ID-matched
    /// "<Artist> - Topic" upload for that recording — a candidate pool
    /// that's already scoped to (in principle) just this one song,
    /// unlike a title search's pool of covers/remixes/fan edits that
    /// merely share a name. Returns `nil` (meaning: fall back to
    /// `weightedSearch`) whenever that doesn't pan out — no results, or
    /// nothing in the results actually looks like the right recording.
    private static func isrcSearch(
        isrc: String,
        raw: SearchCandidate,
        target: MatchTarget,
        youtubeSource: YouTubeSearchSource
    ) async -> SourcePick? {
        guard let candidates = try? await YouTubeSearch.search(isrc, source: youtubeSource), !candidates.isEmpty else {
            return nil
        }

        let ranked = rankCandidates(target: target, candidates: candidates)
        guard let winner = ranked.first, isrcQualifies(winner) else {
            WFLog.match.info("ISRC search for \"\(isrc, privacy: .public)\" returned no confident match for \"\(target.author, privacy: .public) - \(target.title, privacy: .public)\" — falling back to weighted text search.")
            return nil
        }

        let winnerCandidate = mergedCandidate(raw: raw, winner: winner.candidate)

        WFLog.match.debug("ISRC search for \"\(isrc, privacy: .public)\" picked \"\(winner.candidate.rawTitle, privacy: .public)\" (score \(winner.total, format: .fixed(precision: 2))) for \"\(target.author, privacy: .public) - \(target.title, privacy: .public)\".")

        return SourcePick(candidate: winnerCandidate, forced: false, ranked: ranked, strategy: "isrc_search", confident: true, query: isrc)
    }

    /// A looser floor than `Match.qualifies`: an ISRC search's result
    /// pool is already scoped to one recording, so a weak title/keyword
    /// score here usually just means an oddly-formatted upload title,
    /// not the wrong song — unlike a free-text search, where that's the
    /// main signal against covers/fan edits. Duration is the one thing
    /// that still reliably catches a genuine mismatch (YouTube returning
    /// something unrelated for the ISRC text), so this checks that alone.
    private static func isrcQualifies(_ scored: ScoredCandidate) -> Bool {
        (scored.parts.duration ?? 0) >= 0.75
    }

    /// Combines a matched YouTube `winner` with the original `raw`
    /// candidate that was searched for — the single place both
    /// `isrcSearch` and `weightedSearch` build the `SearchCandidate` a
    /// pick actually returns, so the merge logic (and any bug in it)
    /// only exists once.
    ///
    /// The rule: anything that describes *the track itself* — title,
    /// author, ISRC, album name/metadata, the full artist list — comes
    /// from `raw` whenever `raw` actually has it (a Spotify-origin `raw`
    /// always does; a YouTube-origin `raw` never does, so `winner`'s
    /// value — usually just as empty — is the harmless fallback).
    /// Anything that describes *which YouTube upload this is* — id, url,
    /// channel, view count, the matched duration — comes from `winner`,
    /// since that's the whole point of having searched in the first
    /// place. Getting this backwards (preferring `winner`'s essentially-
    /// always-`nil` `isrc`/`albumName`/`artists`/`albumMeta` over `raw`'s
    /// real Spotify data) was a real bug here: every Spotify-matched
    /// download silently lost its ISRC and album metadata the moment it
    /// resolved to a YouTube source, even though `raw` had it the whole
    /// time.
    private static func mergedCandidate(raw: SearchCandidate, winner: SearchCandidate) -> SearchCandidate {
        SearchCandidate(
            id: winner.id,
            origin: winner.origin,
            title: raw.title,
            author: raw.author,
            rawTitle: raw.rawTitle,
            channel: winner.channel ?? raw.rawTitle,
            url: winner.url,
            youtubeID: winner.youtubeID ?? raw.youtubeID,
            spotifyID: winner.spotifyID ?? raw.spotifyID,
            isrc: raw.isrc ?? winner.isrc,
            durationMS: winner.durationMS,
            viewCount: winner.viewCount,
            thumbnailURLString: winner.thumbnailURLString,
            albumName: raw.albumName ?? winner.albumName,
            artists: raw.artists.isEmpty ? winner.artists : raw.artists,
            albumMeta: raw.albumMeta.isEmpty ? winner.albumMeta : raw.albumMeta
        )
    }

    /// Prefers Genius (when `genius` is non-nil) over the weighted
    /// YouTube search below — a Genius song page's YouTube media links,
    /// filtered to non-"- Topic" channels, are a stronger "does an MV
    /// exist, and which upload is it" signal than free-text search
    /// scoring. Mirrors `jobs.js`'s `pickVideoSource`; see `VideoPick`'s
    /// doc comment for the three possible outcomes. `youtubeSource` only
    /// affects the weighted-search fallback paths below — a Genius hit
    /// resolves directly to a specific video ID regardless of it, and
    /// realistically video content (an actual music video) is less
    /// likely to exist in YTM's catalog-first search than in plain
    /// YouTube search anyway, so `.music` is probably the wrong choice
    /// for this particular call even when it's the app-wide default for
    /// audio matching — left as the caller's call, not hardcoded here.
    public static func pickVideoSource(
        for raw: SearchCandidate,
        target: MatchTarget,
        genius: GeniusClient?,
        youtubeSource: YouTubeSearchSource = Search.defaultYouTubeSource
    ) async -> VideoPick {
        guard let genius else {
            return VideoPick(sourcePick: await weightedSearch(for: raw, target: target, youtubeSource: youtubeSource), skip: false)
        }

        guard let lookup = try? await genius.findOfficialVideo(query: "\(target.author) \(target.title)") else {
            WFLog.match.info("Genius lookup failed/no hit for \"\(target.author, privacy: .public) - \(target.title, privacy: .public)\" — falling back to weighted YouTube search for video.")
            var pick = await weightedSearch(for: raw, target: target, youtubeSource: youtubeSource)
            pick.strategy += "+genius_no_match"
            return VideoPick(sourcePick: pick, skip: false)
        }

        WFLog.match.debug("Genius lookup for \"\(target.author, privacy: .public) - \(target.title, privacy: .public)\": \(lookup.all.count) YouTube link(s), \(lookup.filtered.count) non-Topic, noMV=\(lookup.noMV).")
        if lookup.noMV {
            WFLog.match.info("Genius confirms no official video exists for \"\(target.author, privacy: .public) - \(target.title, privacy: .public)\" — skipping video.")
            return VideoPick(sourcePick: nil, skip: true)
        }

        if let top = lookup.filtered.first {
            let geniusCandidate = SearchCandidate(
                id: "youtube:\(top.videoID)",
                origin: .youtube,
                title: top.title ?? target.title,
                author: target.author,
                rawTitle: top.title ?? target.title,
                channel: top.channel,
                url: "https://www.youtube.com/watch?v=\(top.videoID)",
                youtubeID: top.videoID
            )
            // Merged the same way `weightedSearch`/`isrcSearch` merge
            // their winner — a Genius-identified video is still a match
            // *for* `raw`, so it should carry `raw`'s ISRC/album/artist
            // data forward too, not just its own bare id/title/channel.
            let candidate = mergedCandidate(raw: raw, winner: geniusCandidate)
            return VideoPick(
                sourcePick: SourcePick(candidate: candidate, forced: true, ranked: [], strategy: "genius", confident: true, query: "\(target.author) \(target.title)"),
                skip: false
            )
        }

        // Genius has media for this song but every linked video is a
        // "- Topic" upload the current lookup already filtered out — an
        // MV may still exist that Genius simply hasn't linked, so fall
        // back to the weighted search rather than treating this the same
        // as `noMV` (which `findOfficialVideo` only reports when *every*
        // linked upload is Topic, i.e. it positively confirmed no MV).
        var pick = await weightedSearch(for: raw, target: target, youtubeSource: youtubeSource)
        pick.strategy += "+genius_no_qualifying_candidate"
        return VideoPick(sourcePick: pick, skip: false)
    }

    private static func weightedSearch(
        for raw: SearchCandidate,
        target: MatchTarget,
        youtubeSource: YouTubeSearchSource
    ) async -> SourcePick {
        let query = "\(target.author) \(target.title)"
        var candidates: [SearchCandidate]
        do {
            candidates = try await YouTubeSearch.search(query, source: youtubeSource)
        } catch {
            // Previously swallowed via `try?` — the only symptom was a
            // generic "returned no candidates" a few lines down, with
            // no way to tell a real network/backend failure apart from
            // a legitimately empty result. Log the actual error here
            // so a broken backend connection (auth, sandboxing, DNS,
            // timeout, etc.) is visible immediately instead of looking
            // identical to "nothing matched."
            WFLog.match.error("YouTube search backend request for \"\(query, privacy: .public)\" failed: \(error.localizedDescription, privacy: .public)")
            candidates = []
        }
        if raw.origin == .youtube {
            candidates.insert(raw, at: 0)
        }
        var seen: Set<String> = []
        let deduped = candidates.filter { seen.insert($0.id).inserted }

        let ranked = rankCandidates(target: target, candidates: deduped)
        guard let winner = ranked.first else {
            // No candidates at all — fall back to whatever URL `raw`
            // already has, same as `pickSource`'s `fallback_url` strategy.
            WFLog.match.warning("Weighted search for \"\(query, privacy: .public)\" returned no candidates — falling back to raw URL.")
            return SourcePick(candidate: raw, forced: false, ranked: [], strategy: "fallback_url", confident: false, query: query)
        }
        
        let winnerCandidate = mergedCandidate(raw: raw, winner: winner.candidate)
        
        WFLog.match.debug("Weighted search for \"\(query, privacy: .public)\" picked \"\(winner.candidate.rawTitle, privacy: .public)\" (score \(winner.total, format: .fixed(precision: 2))) from \(ranked.count) candidate(s).")

        // Full ranked-candidate breakdown — this is the "how did it
        // search, what were the candidates" diagnostic. Logged
        // unconditionally at .debug rather than gated behind a separate
        // verbose flag: it's exactly the information needed to explain a
        // wrong pick after the fact, and os.Logger's .debug level is
        // already how the rest of this pipeline's verbose detail flows
        // (filter Console.app/Xcode's console by subsystem if it's noisy
        // for everyday use).
        for (index, scored) in ranked.prefix(8).enumerated() {
            let p = scored.parts
            func fmt(_ value: Double?) -> String { value.map { String(format: "%.2f", $0) } ?? "n/a" }
            WFLog.match.debug("""
                [\(index)] "\(scored.candidate.rawTitle, privacy: .public)" — \
                channel: \(scored.candidate.channel ?? "?", privacy: .public), \
                total: \(scored.total, format: .fixed(precision: 3)), \
                title: \(fmt(p.title), privacy: .public), \
                artist: \(fmt(p.artist), privacy: .public), \
                duration: \(fmt(p.duration), privacy: .public), \
                keywords: \(fmt(p.keywords), privacy: .public), \
                channelScore: \(fmt(p.channel), privacy: .public), \
                views: \(fmt(p.views), privacy: .public), \
                waveform: \(fmt(p.waveform), privacy: .public)
                """)
        }

        let confident = Match.qualifies(winner)
        if !confident {
            WFLog.match.warning("Weighted search winner for \"\(query, privacy: .public)\" scored below the confidence floor (\(winner.total, format: .fixed(precision: 2)) < \(Match.minVideoMatchScore, format: .fixed(precision: 2)), or keyword score \(winner.parts.keywords ?? 0, format: .fixed(precision: 2)) < \(Match.minVideoKeywordScore, format: .fixed(precision: 2))) — this pick may be the wrong track. See the ranked breakdown above.")
        }

        return SourcePick(candidate: winnerCandidate, forced: false, ranked: ranked, strategy: "weighted_search", confident: confident, query: query)
    }

    // MARK: - Persisted match diagnostics

    /// Turns a completed `SourcePick` into the `MatchNote` shape
    /// `MediaInfoDocument.match.audio`/`.video` actually stores — the one
    /// place `Match`'s internal `ScoredCandidate`/`SourcePick` types get
    /// converted into the `Codable` record written to `library.json`.
    /// Previously nothing ever called this (there was no "this" to call
    /// at all): every downloaded item's `match` block stayed empty, and
    /// `ItemDetailView`'s "why was this matched this way" disclosure had
    /// nothing to show.
    public static func matchNote(for pick: SourcePick) -> MatchNote {
        guard let winner = pick.ranked.first else {
            // "provided_youtube_id"/"fallback_url"/a bare Genius hit —
            // only `strategy` (and `query`, when there was one) means
            // anything; there's no ranked candidate pool to report.
            return MatchNote(strategy: pick.strategy, query: pick.query)
        }
        let considered = pick.ranked.prefix(8).map { scored in
            MatchCandidate(
                title: scored.candidate.rawTitle,
                url: scored.candidate.url,
                total: scored.total,
                parts: scored.parts
            )
        }
        let score = MatchScore(total: winner.total, parts: winner.parts, weights: weightsAsScoreParts)
        return MatchNote(strategy: pick.strategy, query: pick.query, score: score, considered: Array(considered))
    }

    /// `weights` (a `MatchWeights`) repackaged as a `MatchScoreParts` —
    /// same six-ish numbers, just the shape `MatchNote.score.weights`
    /// wants so `parts`/`weights` can share one type.
    private static var weightsAsScoreParts: MatchScoreParts {
        MatchScoreParts(
            title: weights.title,
            artist: weights.artist,
            duration: weights.duration,
            keywords: weights.keywords,
            channel: weights.channel,
            waveform: weights.waveform,
            views: weights.views
        )
    }

    // MARK: - Private scoring helpers

    private static func artistIn(_ text: String, artist: String) -> Double {
        let a = TextMatching.normalizeText(artist)
        let t = TextMatching.normalizeText(text)
        guard !a.isEmpty, !t.isEmpty else { return 0 }
        if t.contains(a) { return 1 }
        return TextMatching.diceCoefficient(a, t)
    }

    private static func keywordScore(_ text: String, bonus: [String], penalty: [String]) -> Double {
        var value = 0.45
        if bonus.contains(where: { text.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }) {
            value += 0.45
        }
        if penalty.contains(where: { text.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }) {
            value -= 0.5
        }
        return max(0, min(1, value))
    }

    /// Log10-scales raw view counts across one candidate set, mapping the
    /// lowest to 0.25 and the highest to 1.0 — never punishes a candidate
    /// to 0 just for having fewer views than its rivals. Candidates with
    /// no usable view count get a flat 0.25 (matches `matcher.js`
    /// exactly); if *none* of the candidates report a usable count, every
    /// candidate gets 0.25 rather than arbitrarily favoring one.
    private static func relativeViewScores(_ candidates: [SearchCandidate]) -> [Double] {
        let values: [Double?] = candidates.map { candidate in
            guard let v = candidate.viewCount, v > 0 else { return nil }
            return log10(v)
        }
        let valid = values.compactMap { $0 }
        guard !valid.isEmpty else { return candidates.map { _ in 0.25 } }
        let lo = valid.min()!
        let hi = valid.max()!
        if hi == lo { return candidates.map { _ in 1 } }
        return values.map { value in
            guard let value else { return 0.25 }
            return 0.25 + ((value - lo) / (hi - lo)) * 0.75
        }
    }
}

/// Genius-driven official music video lookup — a direct port of
/// `server/lib/genius.js`. A Genius song page lists "media" links
/// (YouTube, SoundCloud, etc.) its editors have attached to that song;
/// this uses the YouTube entries there — filtered to non-"- Topic"
/// channels, since a "<Artist> - Topic" upload is YouTube's
/// auto-generated audio track, never an actual video — as a higher-trust
/// source for "does an official MV exist, and if so which upload is it"
/// than free-text YouTube search. Optional throughout: `Match.pickVideoSource`
/// takes this as `nil` when the user has Genius-assisted matching turned
/// off in Settings, and falls back to the plain weighted search.
///
/// Talks to `waveform-search-backend`'s `/api/genius/*` passthrough
/// rather than `api.genius.com` directly — same official Genius API,
/// same response shapes (`GeniusSearchResponse`/`GeniusSongResponse`
/// below are unchanged), just no per-user access token: the backend
/// holds a pool of tokens and rotates past a rate-limited one itself.
public actor GeniusClient {
    public init() {}

    public struct VideoResult: Sendable {
        public var videoID: String
        public var title: String?
        public var channel: String?
        public var isTopicChannel: Bool
    }

    /// `noMV` is `true` only when Genius positively confirms no MV
    /// exists — every YouTube link on the song page is a "- Topic"
    /// upload. `filtered` is `all` minus those Topic uploads;
    /// `filtered.first` is the best guess at the actual official video.
    public struct Lookup: Sendable {
        public var noMV: Bool
        public var all: [VideoResult]
        public var filtered: [VideoResult]
        public var geniusURL: String?
        public var geniusFullTitle: String?
    }

    /// Returns `nil` whenever Genius can't help at all: no search hit, a
    /// request failed, or the matched song has no YouTube media — callers
    /// should treat that the same as "fall back to YouTube search".
    public func findOfficialVideo(query: String) async throws -> Lookup? {
        let hits = try await search(query)
        guard let top = hits.first else { return nil }

        let song = try await song(id: top.id)
        let ytMedia = (song.media ?? []).filter { $0.provider == "youtube" }
        guard !ytMedia.isEmpty else { return nil }

        var results: [VideoResult] = []
        for media in ytMedia {
            guard let videoID = Self.extractYouTubeID(media.url) else { continue }
            // Best-effort: a failed oEmbed lookup just means this
            // particular media link is skipped, not that the whole
            // lookup fails.
            let details = try? await Search.videoDetails(videoID)
            let channel = details?.channel
            let isTopic = channel.map { $0.range(of: #"-\s*Topic$"#, options: [.regularExpression, .caseInsensitive]) != nil } ?? false
            results.append(VideoResult(videoID: videoID, title: details?.rawTitle, channel: channel, isTopicChannel: isTopic))
        }

        let filtered = results.filter { !$0.isTopicChannel }
        let noMV = filtered.isEmpty && !results.isEmpty
        return Lookup(noMV: noMV, all: results, filtered: filtered, geniusURL: top.url, geniusFullTitle: top.fullTitle)
    }

    // MARK: - Private

    private func search(_ query: String) async throws -> [SongHit] {
        guard var components = URLComponents(
            url: BackendConfig.baseURL.appendingPathComponent("api/genius/search"),
            resolvingAgainstBaseURL: false
        ) else {
            throw SearchError.unsupported("Malformed Genius search backend URL.")
        }
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = components.url else {
            throw SearchError.unsupported("Malformed Genius search backend URL.")
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SearchError.httpError((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        let decoded = try JSONDecoder().decode(GeniusSearchResponse.self, from: data)
        return decoded.response.hits.map(\.result)
    }

    private func song(id: Int) async throws -> GeniusSong {
        guard var components = URLComponents(
            url: BackendConfig.baseURL.appendingPathComponent("api/genius/song"),
            resolvingAgainstBaseURL: false
        ) else {
            throw SearchError.unsupported("Malformed Genius song backend URL.")
        }
        components.queryItems = [URLQueryItem(name: "id", value: String(id))]
        guard let url = components.url else {
            throw SearchError.unsupported("Malformed Genius song backend URL.")
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SearchError.httpError((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return try JSONDecoder().decode(GeniusSongResponse.self, from: data).response.song
    }

    /// Matches both `.../watch?v=<id>` and `youtu.be/<id>` link shapes.
    private static func extractYouTubeID(_ urlString: String) -> String? {
        guard let range = urlString.range(of: #"(?:v=|youtu\.be/)([\w-]{11})"#, options: .regularExpression) else {
            return nil
        }
        let matched = String(urlString[range])
        return matched.components(separatedBy: CharacterSet(charactersIn: "=/")).last
    }

    private struct SongHit: Decodable {
        let id: Int
        let url: String
        let fullTitle: String
        enum CodingKeys: String, CodingKey {
            case id, url
            case fullTitle = "full_title"
        }
    }

    private struct GeniusSearchResponse: Decodable {
        struct Response: Decodable {
            struct Hit: Decodable { let result: SongHit }
            let hits: [Hit]
        }
        let response: Response
    }

    private struct GeniusSong: Decodable {
        struct Media: Decodable { let provider: String; let url: String }
        let media: [Media]?
    }

    private struct GeniusSongResponse: Decodable {
        struct Response: Decodable { let song: GeniusSong }
        let response: Response
    }
}
