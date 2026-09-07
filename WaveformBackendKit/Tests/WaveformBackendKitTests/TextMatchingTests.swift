import XCTest
@testable import WaveformBackendKit

final class TextMatchingTests: XCTestCase {

    // MARK: - normalizeText

    func testNormalizeTextLowercasesAndStripsDiacritics() {
        XCTAssertEqual(TextMatching.normalizeText("Café Münchën"), "cafe munchen")
    }

    func testNormalizeTextStripsApostrophesWithoutLeavingASpace() {
        XCTAssertEqual(TextMatching.normalizeText("Don't Stop"), "dont stop")
    }

    func testNormalizeTextCollapsesPunctuationToSingleSpaces() {
        XCTAssertEqual(TextMatching.normalizeText("Song (Live) [Remaster]!!"), "song live remaster")
    }

    // MARK: - stripTitleNoise

    func testStripTitleNoiseRemovesOfficialVideoTag() {
        XCTAssertEqual(TextMatching.stripTitleNoise("Song Title (Official Music Video)"), "Song Title")
    }

    func testStripTitleNoiseRemovesLyricVideoAndTrailingDash() {
        XCTAssertEqual(TextMatching.stripTitleNoise("Song Title - Lyric Video"), "Song Title")
    }

    func testStripTitleNoiseFallsBackToOriginalWhenStrippingWouldEmptyIt() {
        // The whole title is noise words — stripping would leave nothing,
        // so the (trimmed) original is returned instead of an empty string.
        XCTAssertEqual(TextMatching.stripTitleNoise("Official Audio"), "Official Audio")
    }

    func testStripTitleNoiseIsCaseInsensitive() {
        XCTAssertEqual(TextMatching.stripTitleNoise("Song [OFFICIAL VIDEO]"), "Song")
    }

    // MARK: - cleanArtistName

    func testCleanArtistNameStripsTopicSuffix() {
        XCTAssertEqual(TextMatching.cleanArtistName("Some Artist - Topic", channel: nil, title: nil), "Some Artist")
    }

    func testCleanArtistNameStripsVevoSuffix() {
        XCTAssertEqual(TextMatching.cleanArtistName("someartistVEVO", channel: nil, title: nil), "someartist")
    }

    func testCleanArtistNameFallsBackToTitleDerivedNameWhenArtistIsBareTopic() {
        let result = TextMatching.cleanArtistName("Topic", channel: "Topic", title: "Real Artist - Some Song")
        XCTAssertEqual(result, "Real Artist")
    }

    func testCleanArtistNameFallsBackToUnknownArtistWhenNothingUsable() {
        XCTAssertEqual(TextMatching.cleanArtistName(nil, channel: nil, title: nil), "Unknown Artist")
    }

    // MARK: - parseArtistTitle

    func testParseArtistTitleSplitsOnSpacedDash() {
        let result = TextMatching.parseArtistTitle("Daft Punk - One More Time", channel: "Daft PunkVEVO")
        XCTAssertEqual(result.author, "Daft Punk")
        XCTAssertEqual(result.title, "One More Time")
    }

    func testParseArtistTitleDoesNotSplitOnHyphenatedWord() {
        // No spaces around the dash in "co-writer" — must not be treated
        // as an "Artist - Title" separator.
        let result = TextMatching.parseArtistTitle("Well-Known Song", channel: "Some Channel")
        XCTAssertEqual(result.title, "Well-Known Song")
    }

    func testParseArtistTitleFallsBackToChannelWhenFirstSegmentIsTopic() {
        let result = TextMatching.parseArtistTitle("Topic - Weird Title", channel: "Real Channel")
        XCTAssertEqual(result.author, "Real Channel")
    }

    func testParseArtistTitleWithNoDashUsesChannel() {
        let result = TextMatching.parseArtistTitle("Just A Title (Official Audio)", channel: "The Channel")
        XCTAssertEqual(result.author, "The Channel")
        XCTAssertEqual(result.title, "Just A Title")
    }

    // MARK: - diceCoefficient

    func testDiceCoefficientIdenticalStringsScoreOne() {
        XCTAssertEqual(TextMatching.diceCoefficient("Hello World", "hello world"), 1)
    }

    func testDiceCoefficientEmptyStringsScoreZero() {
        XCTAssertEqual(TextMatching.diceCoefficient("", "anything"), 0)
        XCTAssertEqual(TextMatching.diceCoefficient("anything", ""), 0)
    }

    func testDiceCoefficientCompletelyDifferentStringsScoreLow() {
        let score = TextMatching.diceCoefficient("abcdef", "zzzzzz")
        XCTAssertEqual(score, 0, accuracy: 0.0001)
    }

    func testDiceCoefficientPartialOverlapIsBetweenZeroAndOne() {
        let score = TextMatching.diceCoefficient("night changes", "night change")
        XCTAssertGreaterThan(score, 0.8)
        XCTAssertLessThan(score, 1.0)
    }

    // MARK: - durationScore

    func testDurationScoreExactMatchIsOne() {
        XCTAssertEqual(TextMatching.durationScore(expectedSec: 200, actualSec: 200), 1)
    }

    func testDurationScoreWithinTwoSecondsIsOne() {
        XCTAssertEqual(TextMatching.durationScore(expectedSec: 200, actualSec: 201.5), 1)
    }

    func testDurationScoreUnknownDurationsScoreNeutral() {
        XCTAssertEqual(TextMatching.durationScore(expectedSec: nil, actualSec: 200), 0.35)
        XCTAssertEqual(TextMatching.durationScore(expectedSec: 200, actualSec: nil), 0.35)
    }

    func testDurationScoreDecaysLinearlyWithinWindow() {
        // window defaults to 120; a 60s delta should land at 0.5.
        let score = TextMatching.durationScore(expectedSec: 200, actualSec: 260)
        XCTAssertEqual(score, 0.5, accuracy: 0.01)
    }

    func testDurationScoreAtOrBeyondWindowIsZero() {
        XCTAssertEqual(TextMatching.durationScore(expectedSec: 200, actualSec: 320), 0)
        XCTAssertEqual(TextMatching.durationScore(expectedSec: 200, actualSec: 500), 0)
    }

    // MARK: - parseClockDuration

    func testParseClockDurationMinutesSeconds() {
        XCTAssertEqual(TextMatching.parseClockDuration("3:42"), 222)
    }

    func testParseClockDurationHoursMinutesSeconds() {
        XCTAssertEqual(TextMatching.parseClockDuration("1:02:03"), 3723)
    }

    func testParseClockDurationBareNumberIsSeconds() {
        XCTAssertEqual(TextMatching.parseClockDuration("245"), 245)
    }

    func testParseClockDurationInvalidReturnsNil() {
        XCTAssertNil(TextMatching.parseClockDuration("not a duration"))
        XCTAssertNil(TextMatching.parseClockDuration(nil))
        XCTAssertNil(TextMatching.parseClockDuration(""))
    }
}
