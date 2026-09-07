import Foundation

/// An ordered, observable playback queue. `MediaPlayerController` watches
/// `currentIndex` and loads whatever it points to; this type owns none of
/// the actual playback, just the ordering and navigation logic.
@MainActor
public final class PlaybackQueue: ObservableObject {
    @Published public private(set) var entries: [QueueEntry] = []
    @Published public var currentIndex: Int?
    @Published public var repeatMode: RepeatMode = .off
    @Published public private(set) var isShuffled: Bool = false

    /// Indices into `entries`, used for next/previous order while shuffled.
    private var playOrder: [Int] = []

    public init() {}

    public var current: QueueEntry? {
        guard let currentIndex, entries.indices.contains(currentIndex) else { return nil }
        return entries[currentIndex]
    }

    public func append(_ entry: QueueEntry) {
        entries.append(entry)
        rebuildPlayOrder()
        if currentIndex == nil { currentIndex = entries.count - 1 }
    }

    public func append(contentsOf newEntries: [QueueEntry]) {
        guard !newEntries.isEmpty else { return }
        let wasEmpty = entries.isEmpty
        entries.append(contentsOf: newEntries)
        rebuildPlayOrder()
        if wasEmpty { currentIndex = 0 }
    }

    public func insert(_ entry: QueueEntry, at index: Int) {
        let clamped = min(max(0, index), entries.count)
        entries.insert(entry, at: clamped)
        rebuildPlayOrder()
        if let ci = currentIndex, clamped <= ci {
            currentIndex = ci + 1
        }
    }

    public func remove(at index: Int) {
        guard entries.indices.contains(index) else { return }
        entries.remove(at: index)
        guard let ci = currentIndex else {
            rebuildPlayOrder()
            return
        }
        if index == ci {
            currentIndex = entries.isEmpty ? nil : min(ci, entries.count - 1)
        } else if index < ci {
            currentIndex = ci - 1
        }
        rebuildPlayOrder()
    }

    public func move(fromOffsets: IndexSet, toOffset: Int) {
        let currentEntry = current
        let moving = fromOffsets.map { entries[$0] }
        for index in fromOffsets.sorted(by: >) {
            entries.remove(at: index)
        }
        // adjust the insertion point for the items already removed ahead of it
        let removedBeforeTarget = fromOffsets.filter { $0 < toOffset }.count
        let insertionIndex = min(max(0, toOffset - removedBeforeTarget), entries.count)
        entries.insert(contentsOf: moving, at: insertionIndex)

        if let currentEntry {
            currentIndex = entries.firstIndex(of: currentEntry)
        }
        rebuildPlayOrder()
    }

    public func clear() {
        entries.removeAll()
        currentIndex = nil
        playOrder = []
    }

    public func jump(to index: Int) {
        guard entries.indices.contains(index) else { return }
        currentIndex = index
    }

    public func toggleShuffle() {
        isShuffled.toggle()
        rebuildPlayOrder()
    }

    /// What `advance()` would move to, without changing `currentIndex`.
    /// Used by crossfade to look ahead at the next track before it's
    /// actually time to switch.
    public func peekNext() -> QueueEntry? {
        guard !entries.isEmpty, let ci = currentIndex else { return nil }
        if repeatMode == .one { return current }
        let order = isShuffled ? playOrder : Array(entries.indices)
        guard let posInOrder = order.firstIndex(of: ci) else { return nil }
        let nextPos = posInOrder + 1
        if nextPos < order.count {
            return entries[order[nextPos]]
        } else if repeatMode == .all {
            return order.first.map { entries[$0] }
        }
        return nil
    }

    /// Advances to the next track per the current repeat/shuffle settings.
    /// Returns `nil` (and clears `currentIndex`) once the queue is
    /// exhausted with repeat off.
    @discardableResult
    public func advance() -> QueueEntry? {
        guard !entries.isEmpty else { return nil }
        guard let ci = currentIndex else {
            currentIndex = 0
            return current
        }
        if repeatMode == .one { return current }

        let order = isShuffled ? playOrder : Array(entries.indices)
        guard let posInOrder = order.firstIndex(of: ci) else {
            currentIndex = order.first
            return current
        }

        let nextPos = posInOrder + 1
        if nextPos < order.count {
            currentIndex = order[nextPos]
        } else if repeatMode == .all {
            if isShuffled { rebuildPlayOrder() }
            currentIndex = (isShuffled ? playOrder : order).first
        } else {
            currentIndex = nil
        }
        return current
    }

    /// Steps to the previous track. Callers typically restart the current
    /// track instead of calling this when several seconds have elapsed —
    /// that policy lives in `MediaPlayerController`, not here.
    @discardableResult
    public func rewind() -> QueueEntry? {
        guard !entries.isEmpty, let ci = currentIndex else { return nil }
        let order = isShuffled ? playOrder : Array(entries.indices)
        guard let posInOrder = order.firstIndex(of: ci) else { return current }

        let prevPos = posInOrder - 1
        if prevPos >= 0 {
            currentIndex = order[prevPos]
        } else if repeatMode == .all {
            currentIndex = order.last
        }
        return current
    }

    private func rebuildPlayOrder() {
        guard isShuffled else {
            playOrder = Array(entries.indices)
            return
        }
        var order = Array(entries.indices)
        order.shuffle()
        // Keep whatever's currently playing first so toggling shuffle
        // mid-playback doesn't yank the user away from it.
        if let ci = currentIndex, let pos = order.firstIndex(of: ci) {
            order.swapAt(0, pos)
        }
        playOrder = order
    }
    
    /// Replaces every remote queue entry backed by `source` with the supplied
    /// library item, preserving each entry's position and track kind.
    public func replaceRemote(matching source: MediaSource, with item: MediaItem) {
        for index in entries.indices {
            guard case .remote(let ref) = entries[index].playable,
                  ref.source == source else {
                continue
            }

            let entry = entries[index]

            entries[index] = QueueEntry(
                playable: .library(item),
                kind: entry.kind,
                id: entry.id
            )
        }

        rebuildPlayOrder()
    }
}
