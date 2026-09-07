import XCTest
@testable import WaveformBackendKit

@MainActor
final class PlaybackSettingsStoreTests: XCTestCase {
    func makeIsolatedDefaults() -> UserDefaults {
        let suiteName = "vaultdeckkit.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    func testDefaultsAreOffWhenNothingStored() {
        let store = PlaybackSettingsStore(userDefaults: makeIsolatedDefaults())
        XCTAssertFalse(store.normalizeVolume)
        XCTAssertEqual(store.crossfadeDuration, 0)
    }

    func testChangesPersistAcrossInstances() {
        let defaults = makeIsolatedDefaults()

        let first = PlaybackSettingsStore(userDefaults: defaults)
        first.normalizeVolume = true
        first.crossfadeDuration = 6

        let second = PlaybackSettingsStore(userDefaults: defaults)
        XCTAssertTrue(second.normalizeVolume)
        XCTAssertEqual(second.crossfadeDuration, 6)
    }

    func testCrossfadeCanBeTurnedBackOff() {
        let defaults = makeIsolatedDefaults()
        let store = PlaybackSettingsStore(userDefaults: defaults)
        store.crossfadeDuration = 10
        store.crossfadeDuration = 0

        let reloaded = PlaybackSettingsStore(userDefaults: defaults)
        XCTAssertEqual(reloaded.crossfadeDuration, 0)
    }
}
