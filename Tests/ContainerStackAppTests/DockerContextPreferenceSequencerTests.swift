import Foundation
import Observation
import Synchronization
import Testing

@testable import ContainerStackApp

struct DockerContextPreferenceSequencerTests {
    @Test
    func appliesTheLatestPreferenceAfterAnInflightMutation() {
        var sequencer = DockerContextPreferenceSequencer()

        #expect(sequencer.request(true) == true)
        #expect(sequencer.request(false) == nil)
        #expect(sequencer.completed(true) == false)
        #expect(sequencer.completed(false) == nil)
    }

    @Test
    func rejectsARefreshCompletedAfterANewerRefreshStarted() {
        var sequencer = DockerContextRefreshSequencer()

        let staleGeneration = sequencer.begin()
        let currentGeneration = sequencer.begin()

        #expect(!sequencer.isCurrent(staleGeneration))
        #expect(sequencer.isCurrent(currentGeneration))
    }

    @MainActor
    @Test
    func takeoverPreferencePersistsAndNotifiesObservers() throws {
        let suiteName = "DockerContextTakeoverPreferenceTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preference = DockerContextTakeoverPreference(defaults: defaults, key: "takeover")
        #expect(preference.isEnabled == false)

        let didChange = Mutex(false)
        withObservationTracking {
            _ = preference.isEnabled
        } onChange: {
            didChange.withLock { $0 = true }
        }

        preference.setEnabled(true)

        #expect(didChange.withLock { $0 })
        #expect(defaults.object(forKey: "takeover") as? Bool == true)
    }

    @MainActor
    @Test
    func upgradePreservesAnAlreadyActiveContainerStackContext() throws {
        let suiteName = "DockerContextTakeoverMigrationTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preference = DockerContextTakeoverPreference(defaults: defaults, key: "takeover")

        #expect(!preference.isConfigured)
        preference.preserveActiveContextIfUnconfigured("orbstack")
        #expect(!preference.isEnabled)
        #expect(defaults.object(forKey: "takeover") == nil)

        preference.preserveActiveContextIfUnconfigured("containerstack")
        #expect(preference.isEnabled)
        #expect(preference.isConfigured)
        #expect(defaults.object(forKey: "takeover") as? Bool == true)
    }
}
