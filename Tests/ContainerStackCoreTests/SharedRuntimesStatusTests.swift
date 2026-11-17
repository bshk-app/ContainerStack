import Foundation
import Testing

@testable import ContainerStackCore

struct SharedRuntimesStatusTests {
    @Test func infoStatusAndLabels() throws {
        func info(_ labels: [String], _ warnings: [String] = []) throws -> DockerInfo {
            try JSONDecoder().decode(
                DockerInfo.self, from: JSONSerialization.data(withJSONObject: ["Labels": labels, "Warnings": warnings]))
        }
        #expect(try SharedRuntimesStatus.parse(info: info([])) == .notRunning)
        #expect(try SharedRuntimesStatus.parse(info: info(["containerstack.shared-runtimes=on"])) == .on)
        let transient = "the removal of shared containers of a previous run has not finished"
        for cause in [
            transient, "runtime-groups.json: unsupported version 2", "cleanup failed",
            "runtime-groups.json cannot be read: denied",
        ] {
            let decoded = try info(["containerstack.shared-runtimes=off"], ["shared runtimes are off: " + cause])
            #expect(SharedRuntimesStatus.parse(info: decoded) == (cause == transient ? .starting : .off(cause: cause)))
        }
        let container = try JSONDecoder().decode(
            DockerContainerSummary.self,
            from: Data(
                #"{"Id":"s","Labels":{"containerstack.session.group":"mcp","containerstack.session.container":"parent","containerstack.group.skipped":"mcp:option:User"}}"#
                    .utf8))
        #expect(container.isSession && !container.isSharedContainer)
        #expect(container.sessionContainerID == "parent")
        #expect(container.skippedGroup?.explanation == "The run sets User.")
    }

}
