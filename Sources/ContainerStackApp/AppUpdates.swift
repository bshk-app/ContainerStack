import ContainerStackCore
import Sparkle
import SwiftUI

/// The app's single Sparkle updater.
///
/// `SPUStandardUpdaterController` starts the updater in its initializer and has
/// to outlive every check, so exactly one instance lives for the whole process.
@MainActor
final class AppUpdates {
    private let controller: SPUStandardUpdaterController
    private let feed: UpdateFeed?

    init(bundle: Bundle = .main) {
        feed = UpdateFeed.resolve(
            feedURL: bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
            publicKey: bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        )

        // Starting the updater without a feed is a fatal Sparkle error, not a
        // no-op: it puts an "Update Error!" alert in front of anyone running a
        // development build. Construct the controller either way so the menu
        // item exists, but leave it stopped until the bundle can be updated.
        controller = SPUStandardUpdaterController(
            startingUpdater: feed != nil,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    /// False for development builds, which the menu shows as disabled rather
    /// than offering a check that cannot work.
    var canCheckForUpdates: Bool { feed != nil }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        controller.updater.checkForUpdates()
    }
}
