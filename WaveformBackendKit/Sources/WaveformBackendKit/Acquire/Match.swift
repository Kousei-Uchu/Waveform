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
    /// directly, matching `pickSource`'s `provided_youtube_id` fast path;
    /// a Spotify-origin `raw` always goes through the weighted search,
    /// since Spotify itself has no playable audio to fall back to.
    /// `youtubeSource` defaults to `Search.defaultYouTubeSource` — see
    /// that property's doc comment for the "use only YTM" switch.
    public static func pickAudioSource(
        for raw: SearchCandidate,
        target: MatchTarget,
        youtubeSource: YouTubeSearchSource = Search.defaultYouTubeSource
    ) async -> SourcePick {
        if raw.origin == .youtube {
            return SourcePick(candidate: raw, forced: true, ranked: [], strategy: "provided_youtube_id")
        }
        return await weightedSearch(for: raw, target: target, youtubeSource: youtubeSource)
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
            let candidate = SearchCandidate(
                id: "youtube:\(top.videoID)",
                origin: .youtube,
                title: top.title ?? target.title,
                author: target.author,
                rawTitle: top.title ?? target.title,
                channel: top.channel,
                url: "https://www.youtube.com/watch?v=\(top.videoID)",
                youtubeID: top.videoID
            )
            return VideoPick(
                sourcePick: SourcePick(candidate: candidate, forced: true, ranked: [], strategy: "genius"),
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
        var candidates = (try? await YouTubeSearch.search(query, source: youtubeSource)) ?? []
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
            return SourcePick(candidate: raw, forced: false, ranked: [], strategy: "fallback_url")
        }
        
        let winnerCandidate = SearchCandidate(
            id: winner.candidate.id,
            origin: winner.candidate.origin,
            title: raw.title,
            author: raw.author,
            rawTitle: raw.rawTitle,
            channel: winner.candidate.channel ?? raw.rawTitle,
            url: winner.candidate.url,
            youtubeID: winner.candidate.youtubeID ?? raw.youtubeID,
            spotifyID: winner.candidate.spotifyID ?? raw.spotifyID,
            isrc: winner.candidate.isrc,
            durationMS: winner.candidate.durationMS,
            viewCount: winner.candidate.viewCount,
            thumbnailURLString: winner.candidate.thumbnailURLString,
            albumName: winner.candidate.albumName
        )
        
        WFLog.match.debug("Weighted search for \"\(query, privacy: .public)\" picked \"\(winner.candidate.rawTitle, privacy: .public)\" (score \(winner.total, format: .fixed(precision: 2))) from \(ranked.count) candidate(s).")
        return SourcePick(candidate: winnerCandidate, forced: false, ranked: ranked, strategy: "weighted_search")
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
/// takes this as `nil` when the user hasn't entered a Genius access token
/// in Settings (§8), and falls back to the plain weighted search.
public actor GeniusClient {
    public let accessToken: String
    public init(accessToken: String) {
        self.accessToken = accessToken
    }

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

    private static let searchURL = URL(string: "https://api.genius.com/search")!
    private static let songBaseURLString = "https://api.genius.com/songs"

    private func search(_ query: String) async throws -> [SongHit] {
        guard var components = URLComponents(url: Self.searchURL, resolvingAgainstBaseURL: false) else {
            throw SearchError.unsupported("Malformed Genius search URL.")
        }
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = components.url else {
            throw SearchError.unsupported("Malformed Genius search URL.")
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SearchError.httpError((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        let decoded = try JSONDecoder().decode(GeniusSearchResponse.self, from: data)
        return decoded.response.hits.map(\.result)
    }

    private func song(id: Int) async throws -> GeniusSong {
        guard let url = URL(string: "\(Self.songBaseURLString)/\(id)") else {
            throw SearchError.unsupported("Malformed Genius song URL.")
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
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
