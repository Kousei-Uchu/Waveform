import XCTest
@testable import WaveformBackendKit

final class MatchScoringTests: XCTestCase {

    private func makeCandidate(
        title: String,
        author: String,
        rawTitle: String? = nil,
        channel: String? = nil,
        durationMS: Double? = 200_000,
        viewCount: Double? = nil,
        origin: SearchOrigin = .youtube
    ) -> SearchCandidate {
        SearchCandidate(
            id: "youtube:\(UUID().uuidString)",
            origin: origin,
            title: title,
            author: author,
            rawTitle: rawTitle ?? title,
            channel: channel,
            url: "https://www.youtube.com/watch?v=abc",
            youtubeID: origin == .youtube ? "abc" : nil,
            durationMS: durationMS,
            viewCount: viewCount
        )
    }

    // MARK: - scoreCandidate

    func testScoreCandidateHighForNearExactMatch() {
        let target = MatchTarget(title: "One More Time", author: "Daft Punk", durationMS: 200_000, intent: .audio)
        let candidate = makeCandidate(
            title: "One More Time",
            author: "Daft Punk",
            rawTitle: "Daft Punk - One More Time (Official Audio)",
            channel: "Daft PunkVEVO",
            durationMS: 200_000
        )
        let scored = Match.scoreCandidate(target: target, candidate: candidate, relativeViews: 1.0)
        XCTAssertGreaterThan(scored.total, 0.75)
        XCTAssertEqual(scored.parts.title, 1, accuracy: 0.0001)
        XCTAssertEqual(scored.parts.duration, 1, accuracy: 0.0001)
    }

    func testScoreCandidateLowForUnrelatedContent() {
        let target = MatchTarget(title: "One More Time", author: "Daft Punk", durationMS: 200_000, intent: .audio)
        let candidate = makeCandidate(
            title: "Completely Different Song",
            author: "Some Other Band",
            durationMS: 900_000
        )
        let scored = Match.scoreCandidate(target: target, candidate: candidate, relativeViews: 0.25)
        XCTAssertLessThan(scored.total, 0.35)
    }

    func testScoreCandidatePenalizesCoverForVideoIntent() {
        let target = MatchTarget(title: "One More Time", author: "Daft Punk", durationMS: 200_000, intent: .video)
        let officialVideo = makeCandidate(
            title: "One More Time",
            author: "Daft Punk",
            rawTitle: "Daft Punk - One More Time (Official Music Video)",
            channel: "Daft PunkVEVO"
        )
        let cover = makeCandidate(
            title: "One More Time",
            author: "Daft Punk",
            rawTitle: "One More Time (Cover) by Some Random Channel",
            channel: "Some Random Channel"
        )
        let officialScore = Match.scoreCandidate(target: target, candidate: officialVideo, relativeViews: 0.5)
        let coverScore = Match.scoreCandidate(target: target, candidate: cover, relativeViews: 0.5)
        XCTAssertGreaterThan(officialScore.parts.keywords ?? 0, coverScore.parts.keywords ?? 0)
        XCTAssertGreaterThan(officialScore.total, coverScore.total)
    }

    func testScoreCandidateTopicChannelScoresHigherForAudioThanVideoIntent() {
        let candidate = makeCandidate(
            title: "One More Time",
            author: "Daft Punk",
            channel: "Daft Punk - Topic"
        )
        let audioTarget = MatchTarget(title: "One More Time", author: "Daft Punk", durationMS: 200_000, intent: .audio)
        let videoTarget = MatchTarget(title: "One More Time", author: "Daft Punk", durationMS: 200_000, intent: .video)
        let audioScore = Match.scoreCandidate(target: audioTarget, candidate: candidate)
        let videoScore = Match.scoreCandidate(target: videoTarget, candidate: candidate)
        // A "- Topic" auto-upload is a *good* audio source but a *bad*
        // video source (matcher.js: 0.9 vs 0.2 on the channel part).
        XCTAssertEqual(audioScore.parts.channel, 0.9)
        XCTAssertEqual(videoScore.parts.channel, 0.2)
    }

    func testScoreCandidateWaveformPullsAnImperfectMatchUpward() {
        let target = MatchTarget(title: "One More Time", author: "Daft Punk", durationMS: 200_000, intent: .audio)
        // Deliberately imperfect (different title) so the base score is
        // comfortably below 1 and a perfect waveform correlation has
        // room to pull the total upward.
        let candidate = makeCandidate(title: "One More Time (Live)", author: "Daft Punk", durationMS: 200_000)

        let withoutWaveform = Match.scoreCandidate(target: target, candidate: candidate, waveform: nil, relativeViews: 0.5)
        let withPerfectWaveform = Match.scoreCandidate(target: target, candidate: candidate, waveform: 1.0, relativeViews: 0.5)

        XCTAssertLessThan(withoutWaveform.total, 1)
        XCTAssertGreaterThan(withPerfectWaveform.total, withoutWaveform.total)
        XCTAssertEqual(withPerfectWaveform.parts.waveform, 1.0)
        XCTAssertNil(withoutWaveform.parts.waveform)
    }

    // MARK: - rankCandidates

    func testRankCandidatesSortsBestFirst() {
        let target = MatchTarget(title: "One More Time", author: "Daft Punk", durationMS: 200_000, intent: .audio)
        let goodMatch = makeCandidate(title: "One More Time", author: "Daft Punk", durationMS: 200_000)
        let badMatch = makeCandidate(title: "Totally Unrelated", author: "Nobody", durationMS: 900_000)

        let ranked = Match.rankCandidates(target: target, candidates: [badMatch, goodMatch])
        XCTAssertEqual(ranked.first?.candidate.id, goodMatch.id)
    }

    func testRankCandidatesHigherViewCountScoresHigherAllElseEqual() {
        let target = MatchTarget(title: "One More Time", author: "Daft Punk", durationMS: 200_000, intent: .audio)
        let lowViews = makeCandidate(title: "One More Time", author: "Daft Punk", durationMS: 200_000, viewCount: 100)
        let highViews = makeCandidate(title: "One More Time", author: "Daft Punk", durationMS: 200_000, viewCount: 100_000_000)

        let ranked = Match.rankCandidates(target: target, candidates: [lowViews, highViews])
        XCTAssertEqual(ranked.first?.candidate.id, highViews.id)
    }

    func testRankCandidatesAllEqualViewsWhenNoneReportViewCount() {
        // matcher.js: "if none of the candidates have a usable view
        // count, every candidate gets 0.25 rather than arbitrarily
        // favoring one" — verify by checking both candidates' `views`
        // part match.
        let target = MatchTarget(title: "Song", author: "Artist", durationMS: 200_000, intent: .audio)
        let a = makeCandidate(title: "Song", author: "Artist", durationMS: 200_000, viewCount: nil)
        let b = makeCandidate(title: "Song", author: "Artist", durationMS: 200_000, viewCount: nil)

        let ranked = Match.rankCandidates(target: target, candidates: [a, b])
        XCTAssertEqual(ranked[0].parts.views, 0.25)
        XCTAssertEqual(ranked[1].parts.views, 0.25)
    }

    // MARK: - qualifies

    func testQualifiesTrueForConfidentMatch() {
        let scored = ScoredCandidate(
            candidate: makeCandidate(title: "Song", author: "Artist"),
            total: 0.8,
            parts: MatchScoreParts(keywords: 0.9)
        )
        XCTAssertTrue(Match.qualifies(scored))
    }

    func testQualifiesFalseWhenTotalBelowFloor() {
        let scored = ScoredCandidate(
            candidate: makeCandidate(title: "Song", author: "Artist"),
            total: 0.4,
            parts: MatchScoreParts(keywords: 0.9)
        )
        XCTAssertFalse(Match.qualifies(scored))
    }

    func testQualifiesFalseWhenKeywordSignalBelowFloorEvenWithHighTotal() {
        // The keyword floor exists specifically to catch a fan
        // edit/cover/reaction that otherwise scores well on title/artist
        // text alone — a high total shouldn't be enough on its own.
        let scored = ScoredCandidate(
            candidate: makeCandidate(title: "Song", author: "Artist"),
            total: 0.9,
            parts: MatchScoreParts(keywords: 0.1)
        )
        XCTAssertFalse(Match.qualifies(scored))
    }

    // MARK: - pickAudioSource (network-free path only)

    func testPickAudioSourceTrustsProvidedYouTubeCandidateDirectly() async {
        let raw = makeCandidate(title: "One More Time", author: "Daft Punk", origin: .youtube)
        let target = MatchTarget(title: "One More Time", author: "Daft Punk", durationMS: 200_000, intent: .audio)

        let pick = await Match.pickAudioSource(for: raw, target: target)

        XCTAssertTrue(pick.forced)
        XCTAssertEqual(pick.strategy, "provided_youtube_id")
        XCTAssertEqual(pick.candidate.id, raw.id)
        XCTAssertTrue(pick.ranked.isEmpty)
    }
}
