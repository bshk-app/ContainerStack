import ContainerStackCore
import Darwin
import Foundation
import Synchronization

/// How the helper ends on SIGTERM: its bounded children first, then itself, by that same signal.
enum Termination {
    private static let requested = Atomic<Bool>(false)
    private static let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())

    /// The app ends this helper with SIGTERM, which by default left the helper's
    /// `container system start` running, free to overlap the app's next `system stop` (#102).
    /// A signal source rather than a handler, because the main thread sits in a blocking wait;
    /// and it waits on nothing itself, since socktainer's wait never ends by design.
    static func endChildrenFirst() {
        let registered = DispatchSemaphore(value: 0)
        source.setRegistrationHandler { registered.signal() }
        source.setEventHandler {
            requested.store(true, ordering: .sequentiallyConsistent)
            ProcessRunner.terminateBoundedChildren()
            endIfRequested()
        }
        source.resume()
        // Ignored only once the source listens: an ignored SIGTERM before that is lost, while one
        // under the default action still ends the helper, which has started no children yet.
        registered.wait()
        signal(SIGTERM, SIG_IGN)
    }

    /// Once SIGTERM has arrived, ends the helper by it, as the default action would have. Ending
    /// the children wakes the main thread with their deaths, and reporting those as a failure
    /// would exit with status 1 first, so every exit comes through here (#56 owns that status).
    static func endIfRequested() {
        guard requested.load(ordering: .sequentiallyConsistent) else { return }
        signal(SIGTERM, SIG_DFL)
        kill(getpid(), SIGTERM)
        while true { pause() }
    }
}
