import Foundation
import os
import YouTubeSDK

public enum SearchError: Error, LocalizedError, Sendable {
    case httpError(Int)
    case notConfigured(String)
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .httpError(let code): "Search request failed (HTTP \(code))."
        case .notConfigured(let message): message
        case .unsupported(let message): message
        }
    }
}

public enum SearchOrigin: String, Sendable {
    case youtube
    case spotify
}

/// One contributing artist on a Spotify track — `id` is Spotify's own
/// artist id (present for every Spotify-sourced artist; `nil` for a
/// name-only artist, e.g. one recovered from a non-Spotify source that
/// has no stable id to offer). Kept as its own small type rather than
/// two parallel `[String]` arrays (names/ids) so a track's artists stay
/// paired correctly as one list.
public struct ArtistRef: Sendable, Hashable, Codable {
    public var id: String?
    public var name: String

    public init(id: String? = nil, name: String) {
        self.id = id
        self.name = name
    }
}

public extension ArtistRef {
    /// Reconstructs the list `SearchCandidate.libraryAuthorMeta` encodes
    /// into an `"artists"` key — the inverse of that encoding. Needed
    /// wherever a `RemoteRef`'s already-resolved `authorMeta` has to be
    /// turned back into a `SearchCandidate` (e.g. `DownloadManager`
    /// independently re-matching a video source for a track whose audio
    /// side already carries the real Spotify artist list) without losing
    /// that list in the round trip.
    static func array(from authorMeta: [String: JSONValue]) -> [ArtistRef] {
        guard let entries = authorMeta["artists"]?.arrayValue else { return [] }
        return entries.compactMap { entry in
            guard let object = entry.objectValue, let name = object["name"]?.stringValue else { return nil }
            return ArtistRef(id: object["id"]?.stringValue, name: name)
        }
    }
}

/// One item surfaced by search, a URL resolve, or a Spotify collection
/// expand — the Swift-side equivalent of the plain-object shape threaded
/// through the old pipeline's `resolve.js`/`innertube.js`/`spotify.js`
/// (`mapYtdlpToItem`/`asItem`/`mapTrack`). `Match.swift` scores these,
/// and a YouTube-backed one ultimately becomes a `RemoteRef` (§4) via
/// `remoteRef(availableKinds:)`.
public struct SearchCandidate: Sendable, Hashable, Identifiable {
    public var id: String
    public var origin: SearchOrigin
    public var title: String
    public var author: String
    public var rawTitle: String
    public var channel: String?
    public var url: String
    public var youtubeID: String?
    public var spotifyID: String?
    public var isrc: String?
    public var durationMS: Double?
    /// Raw view count (not log-scaled) — `Match.relativeViewScores` does
    /// the log-scaling/normalization across a candidate set.
    public var viewCount: Double?
    public var thumbnailURLString: String?
    public var albumName: String?
    /// Every contributing artist, in Spotify's own order — only ever
    /// populated for a Spotify-origin candidate (`SpotifyClient.mapTrack`);
    /// `author` above stays the flattened, comma-joined *display* string
    /// (used for search matching/UI) regardless, so this doesn't replace
    /// it — it's the structured list `author` used to collapse into with
    /// no way back. Empty for a YouTube-origin candidate, same as `isrc`/
    /// `spotifyID`.
    public var artists: [ArtistRef]
    /// The raw Spotify album object (or Spotify's own simplified/embedded
    /// album shape, for a track fetched as part of an album/playlist) —
    /// only ever populated for a Spotify-origin candidate. `albumName`
    /// above is kept as a quick-access convenience even though it's
    /// almost always also present in here as `albumMeta["name"]`.
    public var albumMeta: [String: JSONValue]

    public init(
        id: String,
        origin: SearchOrigin,
        title: String,
        author: String,
        rawTitle: String,
        channel: String? = nil,
        url: String,
        youtubeID: String? = nil,
        spotifyID: String? = nil,
        isrc: String? = nil,
        durationMS: Double? = nil,
        viewCount: Double? = nil,
        thumbnailURLString: String? = nil,
        albumName: String? = nil,
        artists: [ArtistRef] = [],
        albumMeta: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.origin = origin
        self.title = title
        self.author = author
        self.rawTitle = rawTitle
        self.channel = channel
        self.url = url
        self.youtubeID = youtubeID
        self.spotifyID = spotifyID
        self.isrc = isrc
        self.durationMS = durationMS
        self.viewCount = viewCount
        self.thumbnailURLString = thumbnailURLString
        self.albumName = albumName
        self.artists = artists
        self.albumMeta = albumMeta
    }

    public var thumbnailURL: URL? { thumbnailURLString.flatMap(URL.init(string:)) }

    /// The `source` block (§5/§7) this candidate would carry if it became
    /// a library entry — what `LibraryStore`'s dedup compares against.
    public var mediaSource: MediaSource {
        MediaSource(origin: origin.rawValue, url: url, spotifyID: spotifyID, youtubeID: youtubeID, isrc: isrc)
    }

    /// The `author_meta` block (§7) this candidate would carry into the
    /// library — three-tier, same idea as `MediaInfoDocument.authorMeta`'s
    /// doc comment: the primary (first) artist's `id`/`name` plus the
    /// *full* artist list under `"artists"` when `artists` is populated
    /// (Spotify-origin), a bare `{ "name": author }` fallback when it
    /// isn't (YouTube-origin, or a Spotify response with an empty artist
    /// list), or `{}` when there's no author at all to report.
    public var libraryAuthorMeta: [String: JSONValue] {
        guard let primary = artists.first else {
            return author.isEmpty ? [:] : ["name": .string(author)]
        }
        var meta: [String: JSONValue] = ["name": .string(primary.name)]
        if let id = primary.id { meta["id"] = .string(id) }
        meta["artists"] = .array(artists.map { artist in
            var object: [String: JSONValue] = ["name": .string(artist.name)]
            if let id = artist.id { object["id"] = .string(id) }
            return .object(object)
        })
        return meta
    }

    /// The `album_meta` block (§7) this candidate would carry into the
    /// library: `albumMeta` verbatim when it's populated (Spotify-origin),
    /// otherwise a bare `{ "name": albumName }` fallback for a source that
    /// only ever offers a plain album name (currently just YouTube Music),
    /// or `{}` when there's no album information at all.
    public var libraryAlbumMeta: [String: JSONValue] {
        if !albumMeta.isEmpty { return albumMeta }
        if let albumName, !albumName.isEmpty { return ["name": .string(albumName)] }
        return [:]
    }

    /// A not-yet-downloaded `Playable.remote` reference (§4) — only
    /// meaningful for YouTube-backed candidates, since only those can be
    /// resolved to a stream (`Resolve.swift` keys off `RemoteRef.id`'s
    /// `"youtube:<id>"` prefix). `nil` for a bare Spotify candidate that
    /// hasn't been matched to a YouTube video yet (`Match.swift`'s job).
    ///
    /// `artworkURLOverride` exists so a caller that matched this
    /// candidate from an original Spotify search result can pass
    /// `ArtworkSelection.preferredArtworkURL(raw:matched:)`'s answer here
    /// instead of settling for `self.thumbnailURL` (this candidate's own
    /// — typically a YouTube thumbnail once matching has happened) —
    /// see `ArtworkSelection`'s doc comment for why that distinction
    /// matters for streamed (not-yet-downloaded) playback specifically.
    ///
    /// `matchConfident`/`matchNote` carry `Match`'s verdict on however
    /// this candidate was arrived at — `true`/`nil` by default (no
    /// ambiguity: this is either a direct user pick or a candidate that
    /// hasn't gone through `Match` at all yet), overridden by
    /// `Match.pickAudioSource`/`pickVideoSource` callers once a weighted
    /// search has actually happened. `DownloadManager`'s Conservative
    /// Matching setting reads `matchConfident` off the `RemoteRef` this
    /// produces before committing a download.
    public func remoteRef(
        availableKinds: Set<TrackKind> = [.audio, .video],
        artworkURLOverride: URL? = nil,
        matchConfident: Bool = true,
        matchNote: MatchNote? = nil
    ) -> RemoteRef? {
        guard let youtubeID else { return nil }
        return RemoteRef(
            id: "youtube:\(youtubeID)",
            title: title,
            author: author,
            duration: (durationMS ?? 0) / 1000,
            source: mediaSource,
            availableKinds: availableKinds,
            thumbnailURL: artworkURLOverride ?? thumbnailURL,
            albumMeta: libraryAlbumMeta,
            authorMeta: libraryAuthorMeta,
            matchConfident: matchConfident,
            matchNote: matchNote
        )
    }
}

public struct SearchGroup: Sendable, Identifiable {
    public var id: String
    public var label: String
    public var items: [SearchCandidate]
    public var error: String?

    public init(id: String, label: String, items: [SearchCandidate], error: String? = nil) {
        self.id = id
        self.label = label
        self.items = items
        self.error = error
    }
}

public struct SearchResult: Sendable {
    public var query: String
    public var items: [SearchCandidate]
    public var groups: [SearchGroup]
}

/// Entry point for the Search & Download screen (§8) — free-text search
/// (`pipeline`) and pasted-URL resolution (`resolveURL`), mirroring
/// `resolve.js`'s `searchPipeline`/`resolveUrl`. Neither call touches the
/// library or does any downloading; that's `Fetch.swift`'s job once the
/// user picks a result.
public enum Search {

    /// The single global switch behind "use only YTM": defaults to
    /// `.web` (regular YouTube search) for backward compatibility, but
    /// every `youtubeSource:` parameter on `Search`/`Match`'s search
    /// entry points defaults to whatever this is set to — so setting
    /// `Search.defaultYouTubeSource = .music` once (from a future
    /// Settings toggle, or just at app launch/in a debug build) routes
    /// every subsequent free-text YouTube search and every Genius-less
    /// weighted-search match through YouTube Music instead, with no
    /// other call site changes needed. A `mutable` static rather than a
    /// constant precisely so it can be flipped at runtime once Settings
    /// (§8) exists to back it with a real UI control.
    public static var defaultYouTubeSource: YouTubeSearchSource = .music

    /// Runs YouTube + (if configured) Spotify search concurrently and
    /// groups the results. `spotify` is `nil` when the user hasn't
    /// entered Spotify credentials in Settings (§8) — Spotify search is
    /// silently skipped in that case, matching `spotifyConfigured()`'s
    /// short-circuit in the old pipeline, rather than erroring.
    public static func pipeline(
        query: String,
        spotify: SpotifyClient?,
        youtubeSource: YouTubeSearchSource = Search.defaultYouTubeSource
    ) async -> SearchResult {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return SearchResult(query: trimmed, items: [], groups: [])
        }

        if looksLikeURL(trimmed) {
            do {
                return try await resolveURL(trimmed, spotify: spotify)
            } catch {
                return SearchResult(
                    query: trimmed,
                    items: [],
                    groups: [SearchGroup(id: "url", label: "Link", items: [], error: error.localizedDescription)]
                )
            }
        }

        async let youtubeAttempt = attemptYouTube(trimmed, source: youtubeSource)
        async let spotifyAttempt = attemptSpotify(trimmed, client: spotify)

        let (ytCandidates, ytError) = await youtubeAttempt
        let (spCandidates, spError) = await spotifyAttempt

        var groups: [SearchGroup] = []
        var items: [SearchCandidate] = []

        let ytLabel = youtubeSource == .music ? "YouTube Music" : "YouTube"
        groups.append(SearchGroup(id: "yt", label: ytLabel, items: ytCandidates, error: ytError))
        items.append(contentsOf: ytCandidates)

        if !spCandidates.isEmpty {
            groups.append(SearchGroup(id: "sp-tracks", label: "Spotify tracks", items: spCandidates))
            items.append(contentsOf: spCandidates)
        } else if let spError {
            groups.append(SearchGroup(id: "spotify", label: "Spotify", items: [], error: spError))
        }

        return SearchResult(query: trimmed, items: items, groups: groups)
    }

    /// Resolves a pasted YouTube or Spotify URL (track/album/playlist/
    /// artist, or a single video) into its constituent tracks — the
    /// counterpart of `resolve.js`'s `resolveUrl`. Not affected by
    /// `youtubeSource`/`defaultYouTubeSource` at all: a pasted YouTube
    /// URL is looked up directly by video ID via oEmbed
    /// (`videoDetails(_:)`), it never goes through either search backend.
    public static func resolveURL(_ urlString: String, spotify: SpotifyClient?) async throws -> SearchResult {
        if let ref = parseSpotifyURL(urlString) {
            guard let spotify else {
                throw SearchError.notConfigured(
                    "This is a Spotify link, but Spotify credentials aren't configured in Settings yet."
                )
            }
            let items = try await spotify.resolveRef(type: ref.type, id: ref.id)
            return SearchResult(
                query: urlString,
                items: items,
                groups: [SearchGroup(id: "spotify", label: ref.type.capitalized(with: nil), items: items)]
            )
        }

        if let videoID = parseYouTubeVideoID(urlString) {
            let candidate = try await videoDetails(videoID)
            return SearchResult(
                query: urlString,
                items: [candidate],
                groups: [SearchGroup(id: "youtube", label: candidate.title, items: [candidate])]
            )
        }

        throw SearchError.unsupported("That doesn't look like a YouTube or Spotify link.")
    }

    // MARK: - Private helpers

    private static func looksLikeURL(_ query: String) -> Bool {
        query.range(of: #"^https?://"#, options: [.regularExpression, .caseInsensitive]) != nil
            || query.range(of: #"^spotify:"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func attemptYouTube(
        _ query: String,
        source: YouTubeSearchSource
    ) async -> (candidates: [SearchCandidate], error: String?) {
        do {
            let results = try await YouTubeSearch.search(query, source: source)
            WFLog.search.debug("YouTube (\(String(describing: source), privacy: .public)) search for \"\(query, privacy: .public)\" returned \(results.count) result(s).")
            return (results, nil)
        } catch {
            WFLog.search.error("YouTube search for \"\(query, privacy: .public)\" failed: \(error.localizedDescription, privacy: .public)")
            return ([], error.localizedDescription)
        }
    }

    private static func attemptSpotify(
        _ query: String,
        client: SpotifyClient?
    ) async -> (candidates: [SearchCandidate], error: String?) {
        guard let client else { return ([], nil) }
        do {
            let results = try await client.search(query)
            WFLog.search.debug("Spotify search for \"\(query, privacy: .public)\" returned \(results.count) result(s).")
            return (results, nil)
        } catch {
            WFLog.search.error("Spotify search for \"\(query, privacy: .public)\" failed: \(error.localizedDescription, privacy: .public)")
            return ([], error.localizedDescription)
        }
    }

    /// oEmbed (`https://www.youtube.com/oembed`) is YouTube's actual
    /// public, documented, stable endpoint for single-video metadata —
    /// used here instead of `YouTubeSearch`'s internal-API parsing, since
    /// a single-video lookup doesn't need to lean on that fragile path
    /// when a stable one exists. Doesn't report duration, so this
    /// candidate's `durationMS` stays `nil` until playback/download
    /// (`Resolve.swift`) reports the real thing.
    ///
    /// Internal rather than private: `Match.swift`'s `GeniusClient` also
    /// calls this, to resolve a Genius-linked video ID down to its
    /// channel name (needed to detect "- Topic" auto-upload channels).
    static func videoDetails(_ videoID: String) async throws -> SearchCandidate {
        var components = URLComponents(string: "https://www.youtube.com/oembed")!
        components.queryItems = [
            URLQueryItem(name: "url", value: "https://www.youtube.com/watch?v=\(videoID)"),
            URLQueryItem(name: "format", value: "json"),
        ]
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SearchError.httpError((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        let decoded = try JSONDecoder().decode(OEmbedResponse.self, from: data)
        let parsed = TextMatching.parseArtistTitle(decoded.title, channel: decoded.authorName)
        return SearchCandidate(
            id: "youtube:\(videoID)",
            origin: .youtube,
            title: parsed.title,
            author: parsed.author,
            rawTitle: decoded.title,
            channel: decoded.authorName,
            url: "https://www.youtube.com/watch?v=\(videoID)",
            youtubeID: videoID,
            thumbnailURLString: decoded.thumbnailURL
        )
    }

    private struct OEmbedResponse: Decodable {
        let title: String
        let authorName: String
        let thumbnailURL: String?
        enum CodingKeys: String, CodingKey {
            case title
            case authorName = "author_name"
            case thumbnailURL = "thumbnail_url"
        }
    }

    // MARK: - URL parsing

    private static let recognizedYouTubeHosts: Set<String> = [
        "youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com", "youtu.be", "www.youtu.be",
    ]

    static func parseYouTubeVideoID(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: trimmed), let host = url.host?.lowercased(),
              recognizedYouTubeHosts.contains(host) else { return nil }

        if host.contains("youtu.be") {
            return url.pathComponents.first { $0 != "/" }
        }
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let v = components.queryItems?.first(where: { $0.name == "v" })?.value {
            return v
        }
        if let range = trimmed.range(of: #"/shorts/([^/?]+)"#, options: .regularExpression) {
            return String(trimmed[range]).replacingOccurrences(of: "/shorts/", with: "")
        }
        return nil
    }

    static func parseSpotifyURL(_ input: String) -> (type: String, id: String)? {
        let raw = input.trimmingCharacters(in: .whitespaces)
        let normalized = raw.hasPrefix("spotify:")
            ? raw.replacingOccurrences(of: "spotify:", with: "https://open.spotify.com/")
            : raw
        guard let url = URL(string: normalized), let host = url.host?.lowercased(),
              host.contains("spotify.com") else { return nil }

        let recognizedTypes: Set<String> = ["track", "album", "playlist", "artist"]
        let parts = url.pathComponents.filter { $0 != "/" }
        guard let typeIndex = parts.firstIndex(where: { recognizedTypes.contains($0) }),
              parts.indices.contains(typeIndex + 1) else { return nil }
        let id = parts[typeIndex + 1].components(separatedBy: "?").first ?? parts[typeIndex + 1]
        return (parts[typeIndex], id)
    }
}

/// Which YouTube search backend `YouTubeSearch`/`Match`'s weighted search
/// hits. `.web` is regular youtube.com search (videos — anything from
/// official uploads to covers/reactions/fan edits); `.music` is YouTube
/// Music's search (music.youtube.com — catalog-curated songs/albums/
/// artists, generally far less junk to filter for audio matching, at
/// the cost of sometimes not finding a video that only exists on
/// regular YouTube, e.g. a live performance or fan edit).
///
/// `Search.defaultYouTubeSource` is the single switch: set it once
/// (e.g. from a future Settings toggle, or just at app launch) and both
/// `Search.pipeline`/`.resolveURL`'s free-text search and `Match`'s
/// `pickAudioSource`/`pickVideoSource` weighted search pick it up
/// automatically, since every one of their `youtubeSource:` parameters
/// defaults to it. Pass an explicit `youtubeSource:` at a call site to
/// override just that call without touching the global default.
public enum YouTubeSearchSource: Sendable, Equatable {
    case web
    case music
}

/// Both search backends (`.web` = youtube.com, `.music` = YouTube
/// Music) are now backed by `atpugvaraa/YouTubeSDK` rather than a
/// hand-rolled Innertube POST — that package already does the same
/// "walk the response tree generically" work `collectWebRenderers`/
/// `collectMusicRenderers` used to do here (and carries the same
/// maintenance burden: it's reverse-engineered, unofficial, and can
/// need touch-ups when YouTube changes its response shape), so there's
/// no reason to maintain a second copy of that parsing in this repo.
/// `YouTubeSearch` below is now just a thin adapter from the SDK's own
/// models (`YouTubeItem`/`YouTubeVideo`/`YouTubeMusicSong`) to this
/// package's `SearchCandidate`, which is all `Match.swift`/the rest of
/// `Search.swift` know how to score.
enum YouTubeSearch {
    /// One instance per backend, reused across calls rather than
    /// constructed per-search — cheap either way (no persistent
    /// connection/session state beyond the actor's own `NetworkClient`),
    /// but there's no reason to throw one away after a single search.
    /// Neither is constructed with cookies: `YouTubeOAuthClient`/signed-in
    /// features (liked songs, etc.) aren't wired into this app yet — see
    /// `YouTubeSDK`'s README §3 if that becomes worth adding later.
    private static let webClient = YouTubeClient()
    private static let musicClient = YouTubeMusicClient()

    static func search(_ query: String, source: YouTubeSearchSource) async throws -> [SearchCandidate] {
        switch source {
        case .web: return try await searchWeb(query)
        case .music: return try await searchMusic(query)
        }
    }

    // MARK: - .web (youtube.com)

    /// `YouTubeClient.search` returns a `YouTubeContinuation<YouTubeItem>`
    /// — `YouTubeItem` is a five-case enum (`.video`/`.song`/`.playlist`/
    /// `.channel`/`.shelf`) rather than a flat video list, since a plain
    /// web search page can mix in channel/playlist shelves alongside
    /// videos. `flattenItems` below recurses into `.shelf` (a shelf's
    /// `items` can itself contain more shelves) and keeps only the two
    /// cases that can actually become a playable `RemoteRef`: `.video`
    /// and (rare on `.web`, but harmless to also accept) `.song`.
    /// `.playlist`/`.channel` results are dropped — this is track search,
    /// not a browse UI.
    private static func searchWeb(_ query: String) async throws -> [SearchCandidate] {
        let result = try await webClient.search(query)
        return flattenItems(result.items).compactMap(candidate(from:))
    }

    private static func flattenItems(_ items: [YouTubeItem]) -> [YouTubeItem] {
        items.flatMap { item -> [YouTubeItem] in
            if case .shelf(let shelf) = item {
                return flattenItems(shelf.items)
            }
            return [item]
        }
    }

    private static func candidate(from item: YouTubeItem) -> SearchCandidate? {
        switch item {
        case .video(let video): return candidate(from: video)
        case .song(let song): return candidate(from: song)
        case .playlist, .channel, .shelf: return nil
        }
    }

    /// `video.title` is the raw, unsplit title text a search result
    /// renders (same shape the old hand-rolled parsing pulled out of
    /// `videoRenderer.title`) — still needs `TextMatching.parseArtistTitle`
    /// to split an "Artist - Title" raw title into `title`/`author`, same
    /// as before.
    ///
    /// `video.lengthInSeconds` is a misleading name for search-result
    /// videos specifically: `YouTubeSDK`'s own manual `YouTubeVideo(from:)`
    /// initializer (used here) keeps it as clock-format text ("3:45"),
    /// *not* a real seconds count — only the `player`-endpoint-backed
    /// `YouTubeClient.video(id:)` path gets a true seconds string. So this
    /// still needs `TextMatching.parseClockDuration`, exactly like the old
    /// `lengthText.simpleText` parsing did.
    private static func candidate(from video: YouTubeVideo) -> SearchCandidate {
        let parsed = TextMatching.parseArtistTitle(video.title, channel: video.author)
        let durationSeconds = TextMatching.parseClockDuration(video.lengthInSeconds)
        return SearchCandidate(
            id: "youtube:\(video.id)",
            origin: .youtube,
            title: parsed.title,
            author: parsed.author,
            rawTitle: video.title,
            channel: video.author,
            url: "https://www.youtube.com/watch?v=\(video.id)",
            youtubeID: video.id,
            durationMS: durationSeconds.map { $0 * 1000 },
            viewCount: parseViewCount(video.viewCount),
            thumbnailURLString: video.thumbnailURL
        )
    }

    // MARK: - .music (music.youtube.com)

    /// `YouTubeMusicClient.search` already returns a flat
    /// `[YouTubeMusicSong]` — no shelf-walking needed on this path at
    /// all, unlike `.web`.
    private static func searchMusic(_ query: String) async throws -> [SearchCandidate] {
        let songs = try await musicClient.search(query)
        return songs.map(candidate(from:))
    }

    /// `YouTubeMusicSong` has no channel/byline field at all (YTM's
    /// search UI doesn't surface one the way a video search result
    /// does), so `channel` falls back to the artist name as the closest
    /// available proxy — same approximation the old hand-rolled
    /// `.music` parsing used (`channel: artist`). This means
    /// `Match.scoreCandidate`'s "- Topic"/VEVO channel-name detection
    /// can't fire for a YTM-sourced candidate; it never could with the
    /// old parsing either, so this isn't a regression, just a
    /// pre-existing limitation worth knowing about if channel scoring
    /// ever looks off specifically for `.music` results.
    private static func candidate(from song: YouTubeMusicSong) -> SearchCandidate {
        let author = song.artistsDisplay.isEmpty ? "Unknown Artist" : song.artistsDisplay
        return SearchCandidate(
            id: "youtube:\(song.videoId)",
            origin: .youtube,
            title: song.title,
            author: author,
            rawTitle: song.title,
            channel: song.artistsDisplay.isEmpty ? nil : song.artistsDisplay,
            url: "https://www.youtube.com/watch?v=\(song.videoId)",
            youtubeID: song.videoId,
            durationMS: song.duration.map { $0 * 1000 },
            // `YouTubeMusicSong.album` is real data the SDK already
            // parses out of YTM's search response (unlike a plain `.web`
            // video search result, which has no structured album field
            // at all) — previously dropped here even though
            // `SearchCandidate.albumName` existed to carry exactly this.
            thumbnailURLString: song.thumbnailURL?.absoluteString,
            albumName: song.album
        )
    }

    // MARK: - Shared helpers

    /// `video.viewCount` is already a display string by the time it
    /// reaches us (`YouTubeSDK` prefers the full `viewCountText` — a
    /// real number like "1,234,567 views" — over the abbreviated
    /// `shortViewCountText`, same preference order the old hand-rolled
    /// parsing used), so stripping non-digits and parsing still works
    /// the same way it did before. **Caveat**: if the SDK ever has to
    /// fall back to the abbreviated form (no full count available),
    /// digit-stripping "12M views" yields `12`, not 12,000,000 — under-
    /// counting by orders of magnitude. `Match.relativeViewScores` only
    /// uses this for a *relative* log-scaled comparison within one
    /// candidate set, so an occasional lowball on one candidate is a
    /// minor accuracy loss, not a scoring correctness bug — but worth
    /// fixing properly (parse the K/M/B suffix) if it turns out to fire
    /// often in practice. Unparseable/missing text (e.g. "No views")
    /// yields `nil`, matching the old pipeline treating a missing view
    /// count as unknown rather than zero.
    private static func parseViewCount(_ text: String) -> Double? {
        let digits = text.filter(\.isNumber)
        return digits.isEmpty ? nil : Double(digits)
    }
}

/// Spotify Web API client-credentials search/lookup — a direct port of
/// `server/services/spotify.js`. Holds its own cached access token
/// (Spotify's client-credentials tokens are bearer tokens with no
/// per-user scope, safe to cache in memory for their ~1hr lifetime).
/// Constructed by the app with credentials from Settings (§8); `Search`
/// takes this as an optional parameter rather than owning credentials
/// itself.
public actor SpotifyClient {
    public struct Credentials: Sendable {
        public let clientID: String
        public let clientSecret: String
        public init(clientID: String, clientSecret: String) {
            self.clientID = clientID
            self.clientSecret = clientSecret
        }
    }

    private let credentials: Credentials
    private var cachedToken: String?
    private var tokenExpiry: Date = .distantPast

    public init(credentials: Credentials) {
        self.credentials = credentials
    }

    private static let tokenURL = URL(string: "https://accounts.spotify.com/api/token")!
    private static let apiBase = "https://api.spotify.com/v1"

    // MARK: - Search / expand

    public func search(_ query: String) async throws -> [SearchCandidate] {
        let json = try await apiJSON("/search", params: ["q": query, "type": "track", "limit": "10"])
        let items = ((json["tracks"] as? [String: Any])?["items"] as? [[String: Any]]) ?? []
        return items.compactMap { Self.mapTrack($0) }
    }

    /// Expands a parsed Spotify URL (`Search.parseSpotifyURL`) into its
    /// tracks — the counterpart of `spotify.js`'s `resolveSpotifyRef`.
    public func resolveRef(type: String, id: String) async throws -> [SearchCandidate] {
        switch type {
        case "track":
            let track = try await apiJSON("/tracks/\(id)")
            return [Self.mapTrack(track)].compactMap { $0 }
        case "album":
            let album = try await apiJSON("/albums/\(id)")
            let items = ((album["tracks"] as? [String: Any])?["items"] as? [[String: Any]]) ?? []
            return items.compactMap { Self.mapTrack($0, albumOverride: album) }
        case "playlist":
            let rows = try await playlistTracks(id)
            return rows.compactMap { row -> SearchCandidate? in
                guard let track = row["track"] as? [String: Any] else { return nil }
                return Self.mapTrack(track)
            }
        case "artist":
            let top = try await apiJSON("/artists/\(id)/top-tracks", params: ["market": "US"])
            let items = (top["tracks"] as? [[String: Any]]) ?? []
            return items.compactMap { Self.mapTrack($0) }
        default:
            throw SearchError.unsupported("Unsupported Spotify link type: \(type)")
        }
    }

    // MARK: - Private

    private func playlistTracks(_ id: String) async throws -> [[String: Any]] {
        var items: [[String: Any]] = []
        var path = "/playlists/\(id)/tracks"
        var params: [String: String] = ["limit": "100"]
        // Spotify paginates via a full `next` URL rather than an opaque
        // cursor — re-derive the path/params from it each page, same as
        // `spotify.js`'s `getPlaylistTracks`.
        while true {
            let page = try await apiJSON(path, params: params)
            items.append(contentsOf: (page["items"] as? [[String: Any]]) ?? [])
            guard let next = page["next"] as? String, let comps = URLComponents(string: next) else { break }
            path = comps.path.replacingOccurrences(of: "/v1", with: "")
            params = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        }
        return items
    }

    private func token() async throws -> String {
        if let cachedToken, Date() < tokenExpiry.addingTimeInterval(-15) {
            return cachedToken
        }
        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        let basic = Data("\(credentials.clientID):\(credentials.clientSecret)".utf8).base64EncodedString()
        request.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("grant_type=client_credentials".utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SearchError.httpError((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
        cachedToken = decoded.accessToken
        tokenExpiry = Date().addingTimeInterval(decoded.expiresIn)
        return decoded.accessToken
    }

    private struct TokenResponse: Decodable {
        let accessToken: String
        let expiresIn: Double
        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case expiresIn = "expires_in"
        }
    }

    private func apiJSON(_ path: String, params: [String: String] = [:]) async throws -> [String: Any] {
        guard var components = URLComponents(string: Self.apiBase + path) else {
            throw SearchError.unsupported("Malformed Spotify API path: \(path)")
        }
        if !params.isEmpty {
            components.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else {
            throw SearchError.unsupported("Malformed Spotify API path: \(path)")
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SearchError.httpError((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private static func mapTrack(_ track: [String: Any], albumOverride: [String: Any]? = nil) -> SearchCandidate? {
        guard let id = track["id"] as? String, let name = track["name"] as? String else { return nil }
        let album = albumOverride ?? (track["album"] as? [String: Any]) ?? [:]
        let artistDicts = (track["artists"] as? [[String: Any]]) ?? []
        // `artistRefs` keeps every contributing artist (id + name) as its
        // own structured list — `author` below is still the flattened,
        // comma-joined display string every other part of this pipeline
        // (search matching, row/detail UI) already expects, but it's no
        // longer the *only* record of who's on the track: the full list
        // survives in `artists`/`libraryAuthorMeta` all the way through
        // to what actually gets written to `library.json`.
        let artistRefs = artistDicts.compactMap { dict -> ArtistRef? in
            guard let artistName = dict["name"] as? String else { return nil }
            return ArtistRef(id: dict["id"] as? String, name: artistName)
        }
        let author = artistRefs.map(\.name).joined(separator: ", ")
        let cover = bestImage((album["images"] as? [[String: Any]]) ?? [])
        let isrc = (track["external_ids"] as? [String: Any])?["isrc"] as? String
        let url = ((track["external_urls"] as? [String: Any])?["spotify"] as? String)
            ?? "https://open.spotify.com/track/\(id)"
        // `album` here is Spotify's own embedded (simplified) Album
        // object for a plain track lookup, or the full Album object when
        // `albumOverride` was supplied (`resolveRef`'s `"album"` case,
        // which already fetched `/albums/{id}` in full) — either way,
        // it's real Spotify data worth keeping in full rather than
        // reducing to just a name, so it can group/display correctly
        // once downloaded (`MediaItem.albumID`/`.albumName` read this
        // back out of `library.json`'s `album_meta`).
        let albumMeta = album.isEmpty ? [:] : JSONValue.object(from: album)

        return SearchCandidate(
            id: "spotify:track:\(id)",
            origin: .spotify,
            title: name,
            author: author.isEmpty ? "Unknown Artist" : author,
            rawTitle: name,
            url: url,
            spotifyID: id,
            isrc: isrc,
            durationMS: (track["duration_ms"] as? NSNumber)?.doubleValue,
            thumbnailURLString: cover,
            albumName: album["name"] as? String,
            artists: artistRefs,
            albumMeta: albumMeta
        )
    }

    private static func bestImage(_ images: [[String: Any]]) -> String? {
        images.max { ($0["width"] as? Int ?? 0) < ($1["width"] as? Int ?? 0) }?["url"] as? String
    }
}
