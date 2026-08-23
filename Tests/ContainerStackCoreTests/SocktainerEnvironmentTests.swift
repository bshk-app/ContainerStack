import Foundation
import Testing

@testable import ContainerStackCore

/// The bridge logs every served request at INFO into the helper's own `runtime.log`, which
/// nothing rotates. Measured against the app's 3s poll: ~11 MB a day, a 20 MB file of 203,910
/// lines. It has no log-level flag, but it honours Vapor's `LOG_LEVEL`.
@Suite("The bridge is launched with its request log quieted")
struct SocktainerEnvironmentTests {

    @Test("LOG_LEVEL is set when the parent does not set it")
    func setsLogLevelWhenAbsent() {
        let environment = RuntimeProcessConfiguration.socktainerEnvironment(
            from: ["PATH": "/usr/bin"]
        )

        #expect(environment["LOG_LEVEL"] == "notice")
    }

    /// Turning request logging back on has to stay possible, so an explicit level wins.
    @Test("an explicit LOG_LEVEL is left alone")
    func respectsAnExplicitLogLevel() {
        let environment = RuntimeProcessConfiguration.socktainerEnvironment(
            from: ["LOG_LEVEL": "info"]
        )

        #expect(environment["LOG_LEVEL"] == "info")
    }

    /// An empty value is not a choice — it is what an unset variable looks like once it has
    /// been through a shell, and Vapor would reject it rather than fall back.
    @Test("an empty LOG_LEVEL is treated as unset")
    func treatsAnEmptyLogLevelAsUnset() {
        let environment = RuntimeProcessConfiguration.socktainerEnvironment(
            from: ["LOG_LEVEL": ""]
        )

        #expect(environment["LOG_LEVEL"] == "notice")
    }

    /// The bridge needs the rest of the parent environment: it resolves its app root from the
    /// home directory and its socket path from there too.
    @Test("the rest of the environment is passed through")
    func preservesTheRestOfTheEnvironment() {
        let environment = RuntimeProcessConfiguration.socktainerEnvironment(
            from: ["PATH": "/usr/bin", "HOME": "/Users/example"]
        )

        #expect(environment["PATH"] == "/usr/bin")
        #expect(environment["HOME"] == "/Users/example")
    }
}
