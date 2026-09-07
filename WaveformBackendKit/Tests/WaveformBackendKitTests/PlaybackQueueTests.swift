import XCTest
@testable import WaveformBackendKit

@MainActor
final class PlaybackQueueTests: XCTestCase {
    func makeEntry(_ title: String) -> QueueEntry {
        let info = MediaInfoDocument(
            itemTitle: title,
            itemAuthor: "Artist",
            source: MediaSource(origin: "ytdlp"),
            packedAt: "2026-01-01T00:00:00.000Z",
            mode: "audio",
            audioMedia: MediaFile(codec: "opus", container: "opus")
        )
        let item = MediaItem(
            info: info,
            audioFileURL: URL(fileURLWithPath: "/tmp/fake-library/Audio/\(title).opus")
        )
        return QueueEntry(playable: .library(item), kind: .audio)
    }

    /// A `.remote` counterpart to `makeEntry`, for the mixed remote/
    /// library queue cases below — `source` defaults to a YouTube id
    /// derived from `title` so tests can build a matching downloaded
    /// `MediaItem` for `replaceRemote` without wiring up real network
    /// types.
    func makeRemoteEntry(
        _ title: String,
        youtubeID: String? = nil,
        kind: TrackKind = .audio,
        availableKinds: Set<TrackKind> = [.audio]
    ) -> QueueEntry {
        let ref = RemoteRef(
            id: "yt:\(youtubeID ?? title)",
            title: title,
            author: "Artist",
            duration: 180,
            source: MediaSource(origin: "youtube", youtubeID: youtubeID ?? title),
            availableKinds: availableKinds
        )
        return QueueEntry(playable: .remote(ref), kind: kind)
    }

    /// A downloaded `MediaItem` that `matchesSameTrack` a remote entry
    /// built by `makeRemoteEntry(_:youtubeID:)` with the same id — what
    /// `LibraryStore.addOrUpdate` would hand `DownloadManager` back.
    func makeDownloadedItem(
        _ title: String,
        youtubeID: String? = nil,
        hasAudio: Bool = true,
        hasVideo: Bool = false
    ) -> MediaItem {
        let info = MediaInfoDocument(
            itemTitle: title,
            itemAuthor: "Artist",
            source: MediaSource(origin: "youtube", youtubeID: youtubeID ?? title),
            packedAt: "2026-01-01T00:00:00.000Z",
            mode: hasVideo ? (hasAudio ? "both" : "video") : "audio",
            audioMedia: hasAudio ? MediaFile(codec: "opus", container: "opus") : nil,
            videoMedia: hasVideo ? MediaFile(codec: "av1", container: "webm") : nil
        )
        return MediaItem(
            info: info,
            audioFileURL: hasAudio ? URL(fileURLWithPath: "/tmp/fake-library/Audio/\(title).opus") : nil,
            videoFileURL: hasVideo ? URL(fileURLWithPath: "/tmp/fake-library/Video/\(title).webm") : nil
        )
    }

    func testAppendSetsCurrentIndexOnFirstItem() {
        let queue = PlaybackQueue()
        XCTAssertNil(queue.currentIndex)
        queue.append(makeEntry("A"))
        XCTAssertEqual(queue.currentIndex, 0)
    }

    func testAdvanceStopsAtEndWithRepeatOff() {
        let queue = PlaybackQueue()
        queue.append(contentsOf: [makeEntry("A"), makeEntry("B")])
        XCTAssertEqual(queue.current?.playable.title, "A")

        XCTAssertEqual(queue.advance()?.playable.title, "B")
        XCTAssertNil(queue.advance())
        XCTAssertNil(queue.currentIndex)
    }

    func testRepeatAllWrapsAround() {
        let queue = PlaybackQueue()
        queue.repeatMode = .all
        queue.append(contentsOf: [makeEntry("A"), makeEntry("B")])

        _ = queue.advance() // B
        XCTAssertEqual(queue.advance()?.playable.title, "A")
    }

    func testRepeatOneStaysOnCurrentTrack() {
        let queue = PlaybackQueue()
        queue.repeatMode = .one
        queue.append(contentsOf: [makeEntry("A"), makeEntry("B")])

        XCTAssertEqual(queue.advance()?.playable.title, "A")
        XCTAssertEqual(queue.advance()?.playable.title, "A")
    }

    func testRemoveCurrentAdvancesSelectionSafely() {
        let queue = PlaybackQueue()
        queue.append(contentsOf: [makeEntry("A"), makeEntry("B"), makeEntry("C")])
        queue.jump(to: 1) // B

        queue.remove(at: 1)
        XCTAssertEqual(queue.current?.playable.title, "C")
    }

    func testShuffleKeepsCurrentTrackFirstInOrder() {
        let queue = PlaybackQueue()
        queue.append(contentsOf: (0..<20).map { makeEntry("Track \($0)") })
        queue.jump(to: 10)
        let currentTitle = queue.current?.playable.title

        queue.toggleShuffle()
        // Toggling shuffle shouldn't change what's currently playing.
        XCTAssertEqual(queue.current?.playable.title, currentTitle)
    }

    func testPeekNextMatchesWhatAdvanceWouldDo() {
        let queue = PlaybackQueue()
        queue.append(contentsOf: [makeEntry("A"), makeEntry("B"), makeEntry("C")])

        let peeked = queue.peekNext()
        XCTAssertEqual(peeked?.playable.title, "B")
        // peek must not have side effects
        XCTAssertEqual(queue.current?.playable.title, "A")

        let advanced = queue.advance()
        XCTAssertEqual(advanced?.playable.title, peeked?.playable.title)
    }

    func testPeekNextReturnsNilAtEndWithRepeatOff() {
        let queue = PlaybackQueue()
        queue.append(contentsOf: [makeEntry("A"), makeEntry("B")])
        queue.jump(to: 1)
        XCTAssertNil(queue.peekNext())
    }

    func testPeekNextWrapsWithRepeatAll() {
        let queue = PlaybackQueue()
        queue.repeatMode = .all
        queue.append(contentsOf: [makeEntry("A"), makeEntry("B")])
        queue.jump(to: 1)
        XCTAssertEqual(queue.peekNext()?.playable.title, "A")
    }

    func testPeekNextReturnsCurrentWithRepeatOne() {
        let queue = PlaybackQueue()
        queue.repeatMode = .one
        queue.append(contentsOf: [makeEntry("A"), makeEntry("B")])
        XCTAssertEqual(queue.peekNext()?.playable.title, "A")
    }

    func testPeekNextReflectsShuffleOrder() {
        let queue = PlaybackQueue()
        queue.append(contentsOf: (0..<10).map { makeEntry("Track \($0)") })
        queue.toggleShuffle()

        // Whatever peekNext says should be exactly what advance() lands on.
        let peeked = queue.peekNext()
        let advanced = queue.advance()
        XCTAssertEqual(peeked?.playable.title, advanced?.playable.title)
    }

    // MARK: - Mixed remote/library queues (§4)

    func testMixedQueueTracksAreDistinguishableByPlayable() {
        let queue = PlaybackQueue()
        queue.append(contentsOf: [makeEntry("Local"), makeRemoteEntry("Streamed")])

        XCTAssertTrue(queue.entries[0].playable.isDownloaded)
        XCTAssertFalse(queue.entries[1].playable.isDownloaded)
        XCTAssertNotNil(queue.entries[1].playable.remoteRef)
        XCTAssertNil(queue.entries[0].playable.remoteRef)
    }

    func testReplaceRemoteSwapsMatchingEntryToLibrary() {
        let queue = PlaybackQueue()
        let remoteEntry = makeRemoteEntry("Song", youtubeID: "abc123")
        queue.append(contentsOf: [makeEntry("Other"), remoteEntry])

        let downloaded = makeDownloadedItem("Song", youtubeID: "abc123")
        let didReplace = queue.replaceRemote(matching: downloaded.info.source, with: downloaded)

        XCTAssertTrue(didReplace)
        // Same slot, same stable id, same kind — just a different Playable.
        XCTAssertEqual(queue.entries[1].id, remoteEntry.id)
        XCTAssertEqual(queue.entries[1].kind, remoteEntry.kind)
        XCTAssertTrue(queue.entries[1].playable.isDownloaded)
        XCTAssertEqual(queue.entries[1].playable.libraryItem?.title, "Song")
        // Untouched entry stays exactly as it was.
        XCTAssertEqual(queue.entries[0].playable.title, "Other")
    }

    func testReplaceRemoteLeavesCurrentIndexUnchanged() {
        let queue = PlaybackQueue()
        queue.append(contentsOf: [makeRemoteEntry("A", youtubeID: "a"), makeRemoteEntry("B", youtubeID: "b")])
        queue.jump(to: 1)

        _ = queue.replaceRemote(matching: MediaSource(origin: "youtube", youtubeID: "a"), with: makeDownloadedItem("A", youtubeID: "a"))

        // Position is untouched even though an earlier slot's data changed —
        // this is an in-place data update, not a reorder.
        XCTAssertEqual(queue.currentIndex, 1)
        XCTAssertEqual(queue.current?.playable.title, "B")
    }

    func testReplaceRemoteIgnoresNonMatchingSource() {
        let queue = PlaybackQueue()
        let remoteEntry = makeRemoteEntry("Song", youtubeID: "abc123")
        queue.append(remoteEntry)

        let unrelated = makeDownloadedItem("Different Song", youtubeID: "xyz789")
        let didReplace = queue.replaceRemote(matching: unrelated.info.source, with: unrelated)

        XCTAssertFalse(didReplace)
        XCTAssertEqual(queue.entries[0].id, remoteEntry.id)
        XCTAssertFalse(queue.entries[0].playable.isDownloaded)
    }

    func testReplaceRemoteSkipsSlotWhoseKindWasntDownloaded() {
        let queue = PlaybackQueue()
        // A video slot for a track where only audio ended up downloaded
        // (e.g. a "both" search result where only the audio Download
        // button was tapped) shouldn't be swapped to a library item that
        // has nothing to play for that slot's kind.
        let remoteVideoEntry = makeRemoteEntry("Song", youtubeID: "abc123", kind: .video, availableKinds: [.audio, .video])
        queue.append(remoteVideoEntry)

        let audioOnly = makeDownloadedItem("Song", youtubeID: "abc123", hasAudio: true, hasVideo: false)
        let didReplace = queue.replaceRemote(matching: audioOnly.info.source, with: audioOnly)

        XCTAssertFalse(didReplace)
        XCTAssertFalse(queue.entries[0].playable.isDownloaded)
    }

    func testReplaceRemoteSwapsAllMatchingSlotsAcrossTheQueue() {
        let queue = PlaybackQueue()
        // The same remote track queued twice (e.g. appended, then added
        // again from a playlist) — a download should resolve both.
        queue.append(contentsOf: [
            makeRemoteEntry("Song", youtubeID: "abc123"),
            makeEntry("Between"),
            makeRemoteEntry("Song", youtubeID: "abc123"),
        ])

        let downloaded = makeDownloadedItem("Song", youtubeID: "abc123")
        let didReplace = queue.replaceRemote(matching: downloaded.info.source, with: downloaded)

        XCTAssertTrue(didReplace)
        XCTAssertTrue(queue.entries[0].playable.isDownloaded)
        XCTAssertTrue(queue.entries[2].playable.isDownloaded)
        XCTAssertEqual(queue.entries[1].playable.title, "Between")
    }
}