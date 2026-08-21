import Foundation
import Testing
@testable import ContainerStackCore

/// The user's motivating example file, used verbatim as a fidelity fixture.
private let composeExample = """
version: "3.9"
services:
  webserver:
    image: lipanski/docker-static-website:latest
    restart: always
    ports:
      - "3000:3000"
    volumes:
      - /some/local/path:/home/static
      - ./httpd.conf:/home/static/httpd.conf:ro
"""

@Suite("ComposeFileEditor ports")
struct ComposeFileEditorPortTests {
    // MARK: adding ports

    @Test func addsPortToExistingBlock() throws {
        let result = try ComposeFileEditor.addPort(
            ComposePortMapping(hostPort: 8080, containerPort: 80),
            toService: "webserver",
            in: composeExample
        )
        let expected = """
version: "3.9"
services:
  webserver:
    image: lipanski/docker-static-website:latest
    restart: always
    ports:
      - "3000:3000"
      - "8080:80"
    volumes:
      - /some/local/path:/home/static
      - ./httpd.conf:/home/static/httpd.conf:ro
"""
        #expect(result == expected)
    }

    @Test func addsPortToServiceWithoutPortsKey() throws {
        let input = """
services:
  web:
    image: nginx
    restart: always
"""
        let result = try ComposeFileEditor.addPort(
            ComposePortMapping(hostPort: 80, containerPort: 80),
            toService: "web",
            in: input
        )
        let expected = """
services:
  web:
    image: nginx
    restart: always
    ports:
      - "80:80"
"""
        #expect(result == expected)
    }

    @Test func addsPortToFlowSequence() throws {
        let input = """
services:
  web:
    image: nginx
    ports: ["3000:3000"]
"""
        let result = try ComposeFileEditor.addPort(
            ComposePortMapping(hostPort: 8080, containerPort: 80),
            toService: "web",
            in: input
        )
        let expected = """
services:
  web:
    image: nginx
    ports: ["3000:3000", "8080:80"]
"""
        #expect(result == expected)
    }

    @Test func addingExistingPortIsNoOp() throws {
        let result = try ComposeFileEditor.addPort(
            ComposePortMapping(hostPort: 3000, containerPort: 3000),
            toService: "webserver",
            in: composeExample
        )
        #expect(result == composeExample)
    }

    @Test func addingPortUnaffectedByExplicitTcp() throws {
        // A file entry without a protocol matches one carrying an explicit tcp, since tcp is the
        // default. Adding again is therefore a no-op rather than a duplicate.
        let input = """
services:
  web:
    ports:
      - "3000:3000"
"""
        let result = try ComposeFileEditor.addPort(
            ComposePortMapping(hostPort: 3000, containerPort: 3000, transport: "tcp"),
            toService: "web",
            in: input
        )
        #expect(result == input)
    }

    // MARK: removing ports

    @Test func removingOnlyPortDropsKey() throws {
        let input = """
services:
  web:
    image: nginx
    ports:
      - "80:80"
"""
        let result = try ComposeFileEditor.removePort(
            ComposePortMapping(hostPort: 80, containerPort: 80),
            fromService: "web",
            in: input
        )
        let expected = """
services:
  web:
    image: nginx
"""
        #expect(result == expected)
    }

    @Test func removingAbsentPortThrowsEntryNotFound() {
        #expect(throws: ComposeFileEditor.EditError.entryNotFound("80:80")) {
            try ComposeFileEditor.removePort(
                ComposePortMapping(hostPort: 80, containerPort: 80),
                fromService: "webserver",
                in: composeExample
            )
        }
    }

    @Test func removesPortMatchingByContainerPortForRange() throws {
        // config reports a range's published port as a span string, collapsing hostPort to nil;
        // removal must still find the entry by container port + transport.
        let input = """
services:
  web:
    image: nginx
    ports:
      - "3000:3000"
      - "8090-8092:90"
"""
        let result = try ComposeFileEditor.removePort(
            ComposePortMapping.parse("8090-8092:90")!,
            fromService: "web",
            in: input
        )
        let expected = """
services:
  web:
    image: nginx
    ports:
      - "3000:3000"
"""
        #expect(result == expected)
    }

    @Test func removesConfigStyleTcpPort() throws {
        // A port derived from `compose config` carries protocol: "tcp"; the file entry omits it.
        let input = """
services:
  web:
    image: nginx
    ports:
      - "3000:3000"
"""
        let result = try ComposeFileEditor.removePort(
            ComposePortMapping(hostPort: 3000, containerPort: 3000, transport: "tcp"),
            fromService: "web",
            in: input
        )
        let expected = """
services:
  web:
    image: nginx
"""
        #expect(result == expected)
    }
}

@Suite("ComposeFileEditor volumes and fidelity")
struct ComposeFileEditorVolumeTests {

    // MARK: volumes

    @Test func addsVolumeToServiceWithoutKey() throws {
        let input = """
services:
  web:
    image: nginx
"""
        let result = try ComposeFileEditor.addVolume(
            ComposeVolumeMount(source: "/host", target: "/data", isReadOnly: false),
            toService: "web",
            in: input
        )
        let expected = """
services:
  web:
    image: nginx
    volumes:
      - /host:/data
"""
        #expect(result == expected)
    }

    @Test func quotesVolumeWithSpaceInPath() throws {
        let input = """
services:
  web:
    image: nginx
"""
        let result = try ComposeFileEditor.addVolume(
            ComposeVolumeMount(source: "/my logs", target: "/var/logs", isReadOnly: false),
            toService: "web",
            in: input
        )
        let expected = """
services:
  web:
    image: nginx
    volumes:
      - "/my logs:/var/logs"
"""
        #expect(result == expected)
    }

    @Test func removesVolumeFromExample() throws {
        let result = try ComposeFileEditor.removeVolume(
            ComposeVolumeMount(source: "./httpd.conf", target: "/home/static/httpd.conf", isReadOnly: true),
            fromService: "webserver",
            in: composeExample
        )
        let expected = """
version: "3.9"
services:
  webserver:
    image: lipanski/docker-static-website:latest
    restart: always
    ports:
      - "3000:3000"
    volumes:
      - /some/local/path:/home/static
"""
        #expect(result == expected)
    }

    @Test func removesVolumeByTargetWhenSourceDiffers() throws {
        // config resolves bind sources to absolute paths, so a config-derived mount carries an
        // absolute source that never textually matches the file's relative entry. Docker allows
        // one mount per container path, so matching by target removes the right line.
        let input = """
services:
  web:
    image: nginx
    volumes:
      - ./static:/home/static
"""
        let result = try ComposeFileEditor.removeVolume(
            ComposeVolumeMount(source: "/tmp/stack-probe/static", target: "/home/static", isReadOnly: false),
            fromService: "web",
            in: input
        )
        let expected = """
services:
  web:
    image: nginx
"""
        #expect(result == expected)
    }

    @Test func removingAbsentVolumeThrowsEntryNotFound() {
        #expect(throws: ComposeFileEditor.EditError.entryNotFound("/none:/missing")) {
            try ComposeFileEditor.removeVolume(
                ComposeVolumeMount(source: "/none", target: "/missing", isReadOnly: false),
                fromService: "webserver",
                in: composeExample
            )
        }
    }

    // MARK: structural fidelity & errors

    @Test func unknownServiceThrowsServiceNotFound() {
        #expect(throws: ComposeFileEditor.EditError.serviceNotFound("ghost")) {
            try ComposeFileEditor.addPort(
                ComposePortMapping(hostPort: 80, containerPort: 80),
                toService: "ghost",
                in: composeExample
            )
        }
    }

    @Test func missingServicesMappingThrowsMalformed() {
        let input = """
version: "3.9"
networks:
  default: {}
"""
        #expect(throws: ComposeFileEditor.EditError.self) {
            try ComposeFileEditor.addPort(
                ComposePortMapping(hostPort: 80, containerPort: 80),
                toService: "web",
                in: input
            )
        }
    }

    @Test func longSyntaxSequenceThrowsMalformed() {
        let input = """
services:
  web:
    image: nginx
    ports:
      - target: 80
        published: 8080
"""
        #expect(throws: ComposeFileEditor.EditError.self) {
            try ComposeFileEditor.addPort(
                ComposePortMapping(hostPort: 80, containerPort: 80),
                toService: "web",
                in: input
            )
        }
    }

    @Test func preservesCommentsAndVersionHeader() throws {
        let input = """
version: "3.9"
services:
  web: # the web server
    image: nginx
    ports:
      - "80:80"
"""
        let result = try ComposeFileEditor.addPort(
            ComposePortMapping(hostPort: 443, containerPort: 443),
            toService: "web",
            in: input
        )
        let expected = """
version: "3.9"
services:
  web: # the web server
    image: nginx
    ports:
      - "80:80"
      - "443:443"
"""
        #expect(result == expected)
    }

    @Test func editsFourSpaceIndentedDocument() throws {
        let input = """
services:
    web:
        image: nginx
        ports:
            - "80:80"
"""
        let result = try ComposeFileEditor.addPort(
            ComposePortMapping(hostPort: 443, containerPort: 443),
            toService: "web",
            in: input
        )
        let expected = """
services:
    web:
        image: nginx
        ports:
            - "80:80"
            - "443:443"
"""
        #expect(result == expected)
    }

    @Test func preservesTrailingNewline() throws {
        let input = """
services:
  web:
    image: nginx
    ports:
      - "80:80"
""" + "\n"
        let result = try ComposeFileEditor.addPort(
            ComposePortMapping(hostPort: 443, containerPort: 443),
            toService: "web",
            in: input
        )
        #expect(result.hasSuffix("\n"))
        #expect(result.hasSuffix("\"443:443\"\n"))
    }
}
