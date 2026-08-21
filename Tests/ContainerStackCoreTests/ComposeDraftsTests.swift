import Foundation
import Testing

@testable import ContainerStackCore

@Suite("ComposePortDraft")
struct ComposePortDraftTests {
    @Test("A host and container port produce the mapping the file will carry")
    func hostAndContainerPort() {
        let draft = ComposePortDraft(host: "3100", container: "3000")
        #expect(draft.isValid)
        #expect(draft.mapping?.raw == "3100:3000")
    }

    @Test("An empty host port means Compose picks one")
    func containerPortOnly() {
        let draft = ComposePortDraft(container: "3000")
        #expect(draft.isValid)
        #expect(draft.mapping?.hostPort == nil)
        #expect(draft.mapping?.raw == "3000")
    }

    @Test("Surrounding whitespace is not a validation error")
    func whitespaceIsTrimmed() {
        #expect(ComposePortDraft(host: " 3100 ", container: " 3000 ").mapping?.raw == "3100:3000")
    }

    @Test("A missing container port cannot be submitted")
    func containerPortIsRequired() {
        #expect(ComposePortDraft(host: "3100").isValid == false)
        #expect(ComposePortDraft().isValid == false)
    }

    @Test("Ports outside 1-65535 are refused on both sides")
    func portRangeIsEnforced() {
        #expect(ComposePortDraft(container: "0").isValid == false)
        #expect(ComposePortDraft(container: "65536").isValid == false)
        #expect(ComposePortDraft(host: "0", container: "3000").isValid == false)
        #expect(ComposePortDraft(host: "65536", container: "3000").isValid == false)
        #expect(ComposePortDraft(container: "1").isValid)
        #expect(ComposePortDraft(container: "65535").isValid)
    }

    @Test("Non-numeric input is refused rather than coerced")
    func nonNumericIsRefused() {
        #expect(ComposePortDraft(container: "80/tcp").isValid == false)
        #expect(ComposePortDraft(container: "eighty").isValid == false)
        #expect(ComposePortDraft(host: "3100abc", container: "3000").isValid == false)
    }

    @Test("A bind address is carried through with the host port")
    func bindAddressIsCarried() {
        let draft = ComposePortDraft(host: "8080", container: "80", bindAddress: "127.0.0.1")
        #expect(draft.mapping?.raw == "127.0.0.1:8080:80")
    }

    @Test("A bind address without a host port is refused, because the short syntax cannot spell it")
    func bindAddressWithoutHostPortIsRefused() {
        #expect(ComposePortDraft(container: "80", bindAddress: "127.0.0.1").isValid == false)
    }

    @Test("udp is spelled out in the entry; tcp is left implicit as Compose writes it")
    func transportIsNormalized() {
        #expect(ComposePortDraft(host: "3100", container: "3000", transport: "udp").mapping?.raw == "3100:3000/udp")
        #expect(ComposePortDraft(host: "3100", container: "3000", transport: "tcp").mapping?.raw == "3100:3000")
        #expect(ComposePortDraft(host: "3100", container: "3000", transport: "UDP").mapping?.raw == "3100:3000/udp")
    }
}

@Suite("ComposeVolumeDraft")
struct ComposeVolumeDraftTests {
    @Test("A bind mount needs a source and an absolute target")
    func bindMount() {
        let draft = ComposeVolumeDraft(source: "./static", target: "/home/static")
        #expect(draft.isValid)
        #expect(draft.mount?.raw == "./static:/home/static")
    }

    @Test("Read-only is spelled with the :ro suffix Compose expects")
    func readOnlySuffix() {
        let draft = ComposeVolumeDraft(source: "./httpd.conf", target: "/home/static/httpd.conf", isReadOnly: true)
        #expect(draft.mount?.raw == "./httpd.conf:/home/static/httpd.conf:ro")
    }

    @Test("A named volume is a plain source")
    func namedVolume() {
        let draft = ComposeVolumeDraft(source: "pgdata", target: "/var/lib/postgresql/data")
        #expect(draft.mount?.isBindMount == false)
        #expect(draft.mount?.raw == "pgdata:/var/lib/postgresql/data")
    }

    @Test("Either field missing cannot be submitted")
    func bothFieldsRequired() {
        #expect(ComposeVolumeDraft(source: "./static").isValid == false)
        #expect(ComposeVolumeDraft(target: "/home/static").isValid == false)
        #expect(ComposeVolumeDraft(source: "   ", target: "/home/static").isValid == false)
    }

    @Test("A relative target is refused where the user can still see the field")
    func relativeTargetIsRefused() {
        #expect(ComposeVolumeDraft(source: "./static", target: "home/static").isValid == false)
    }

    @Test("A chosen path inside the project directory is stored relative to it")
    func chosenPathIsRelativized() {
        let project = URL(fileURLWithPath: "/Users/me/stacks/demo")
        #expect(
            ComposeVolumeDraft.relativeSource(
                for: URL(fileURLWithPath: "/Users/me/stacks/demo/static"),
                projectDirectory: project
            ) == "./static"
        )
        #expect(
            ComposeVolumeDraft.relativeSource(
                for: URL(fileURLWithPath: "/Users/me/stacks/demo/conf/httpd.conf"),
                projectDirectory: project
            ) == "./conf/httpd.conf"
        )
        #expect(
            ComposeVolumeDraft.relativeSource(for: project, projectDirectory: project) == "."
        )
    }

    @Test("A path outside the project directory stays absolute")
    func outsidePathStaysAbsolute() {
        #expect(
            ComposeVolumeDraft.relativeSource(
                for: URL(fileURLWithPath: "/var/data/blobs"),
                projectDirectory: URL(fileURLWithPath: "/Users/me/stacks/demo")
            ) == "/var/data/blobs"
        )
        // A sibling directory whose name merely starts with the project's must not be mistaken
        // for a child.
        #expect(
            ComposeVolumeDraft.relativeSource(
                for: URL(fileURLWithPath: "/Users/me/stacks/demo-backup/static"),
                projectDirectory: URL(fileURLWithPath: "/Users/me/stacks/demo")
            ) == "/Users/me/stacks/demo-backup/static"
        )
    }
}
