import Darwin
import Foundation
import Testing

@testable import ContainerStackCore

private struct TLSFixture: ~Copyable {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "cluster-tls-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory.appending(path: "www"), withIntermediateDirectories: true)
        try "subjectAltName=IP:127.0.0.1\nextendedKeyUsage=serverAuth\n"
            .write(to: directory.appending(path: "leaf.ext"), atomically: true, encoding: .utf8)
        for name in ["ca", "other-ca"] {
            try openssl([
                "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", path("\(name).key"), "-out",
                path("\(name).crt"), "-days", "30", "-subj", "/CN=\(name)", "-addext",
                "basicConstraints=critical,CA:TRUE", "-addext", "keyUsage=critical,keyCertSign",
            ])
        }
        try openssl([
            "req", "-newkey", "rsa:2048", "-nodes", "-keyout", path("leaf.key"), "-out", path("leaf.csr"), "-subj",
            "/CN=127.0.0.1",
        ])
        try openssl([
            "x509", "-req", "-in", path("leaf.csr"), "-CA", path("ca.crt"), "-CAkey", path("ca.key"), "-set_serial",
            "1", "-out", path("leaf.crt"), "-days", "30", "-extfile", path("leaf.ext"),
        ])
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    private func openssl(_ arguments: [String]) throws {
        let result = try ProcessRunner.run(
            executablePath: "/usr/bin/openssl", arguments: arguments, timeout: .seconds(60))
        guard result.status == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    func kubeconfig(context: String = "dev", caFile: String = "ca.crt") throws -> URL {
        let pem = try Data(contentsOf: directory.appending(path: caFile)).base64EncodedString()
        let url = directory.appending(path: "kubeconfig")
        try """
        apiVersion: v1
        clusters:
          - cluster:
              certificate-authority-data: \(pem)
              server: https://127.0.0.1:1
            name: \(context)
        contexts:
          - context:
              cluster: \(context)
              user: \(context)
            name: \(context)
        current-context: \(context)
        kind: Config
        users:
          - name: \(context)
            user:
              token: unused
        """.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func serve(_ response: String) throws -> TLSServer {
        try Data(response.utf8).write(to: directory.appending(path: "www/readyz"))
        let port = try freeReadinessPort()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = [
            "s_server", "-accept", "\(port)", "-cert", path("leaf.crt"), "-key", path("leaf.key"), "-HTTP", "-quiet",
        ]
        process.currentDirectoryURL = directory.appending(path: "www")
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        return TLSServer(process: process, port: port, exited: exited)
    }

    func path(_ name: String) -> String {
        directory.appending(path: name).path
    }
}

private struct TLSServer {
    let process: Process
    let port: Int
    let exited: DispatchSemaphore

    func stop() {
        process.terminate()
        _ = exited.wait(timeout: .now() + 5)
    }
}

func freeReadinessPort() throws -> Int {
    let socket = try loopbackReadinessSocket()
    defer { close(socket.descriptor) }
    return socket.port
}

func loopbackReadinessSocket() throws -> (descriptor: Int32, port: Int) {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw POSIXError(.EADDRNOTAVAIL) }
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let bound = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(descriptor, $0, length) == 0 && listen(descriptor, 4) == 0
                && getsockname(descriptor, $0, &length) == 0
        }
    }
    guard bound else {
        close(descriptor)
        throw POSIXError(.EADDRNOTAVAIL)
    }
    return (descriptor, Int(UInt16(bigEndian: address.sin_port)))
}

private func waitUntilListening(_ port: Int) async throws {
    for _ in 0..<100 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        close(descriptor)
        if connected { return }
        try await Task.sleep(for: .milliseconds(50))
    }
    throw POSIXError(.ETIMEDOUT)
}

struct ClusterAPIReadyTests {
    private func ready(_ response: String, caFile: String = "ca.crt") async throws -> Bool {
        let fixture = try TLSFixture()
        let server = try fixture.serve(response)
        defer { server.stop() }
        try await waitUntilListening(server.port)
        return await ClusterAPIReady.isReady(
            endpoint: URL(string: "https://127.0.0.1:\(server.port)"), context: "dev",
            kubeconfig: try fixture.kubeconfig(caFile: caFile), timeout: .seconds(30))
    }

    @Test("ok from a server with the cluster CA is API ready")
    func okIsReady() async throws {
        #expect(try await ready("HTTP/1.0 200 OK\r\nContent-Length: 2\r\n\r\nok"))
    }

    @Test("a 500 is API not ready")
    func serverErrorIsNotReady() async throws {
        #expect(try await !ready("HTTP/1.0 500 Internal Server Error\r\nContent-Length: 2\r\n\r\nok"))
    }

    @Test("a body other than ok is API not ready")
    func otherBodyIsNotReady() async throws {
        #expect(try await !ready("HTTP/1.0 200 OK\r\nContent-Length: 6\r\n\r\nfailed"))
    }

    @Test("a redirect to an ok page is API not ready")
    func redirectIsNotReady() async throws {
        let fixture = try TLSFixture()
        try Data("HTTP/1.0 200 OK\r\nContent-Length: 2\r\n\r\nok".utf8).write(
            to: fixture.directory.appending(path: "www/healthz"))
        let server = try fixture.serve(
            "HTTP/1.0 302 Found\r\nLocation: /healthz\r\nContent-Length: 0\r\n\r\n")
        defer { server.stop() }
        try await waitUntilListening(server.port)

        let ready = await ClusterAPIReady.isReady(
            endpoint: URL(string: "https://127.0.0.1:\(server.port)"), context: "dev",
            kubeconfig: try fixture.kubeconfig())

        #expect(!ready)
    }

    @Test("a server with another CA is API not ready")
    func otherCAIsNotReady() async throws {
        #expect(try await !ready("HTTP/1.0 200 OK\r\nContent-Length: 2\r\n\r\nok", caFile: "other-ca.crt"))
    }

    @Test("a server that does not answer is API not ready within the limit")
    func timeoutIsNotReady() async throws {
        let fixture = try TLSFixture()
        let silent = try loopbackReadinessSocket()
        defer { close(silent.descriptor) }
        let started = ContinuousClock.now

        let ready = await ClusterAPIReady.isReady(
            endpoint: URL(string: "https://127.0.0.1:\(silent.port)"), context: "dev",
            kubeconfig: try fixture.kubeconfig(), timeout: .milliseconds(500))

        #expect(!ready)
        #expect(started.duration(to: .now) < .seconds(3))
    }

    @Test("no context in the file is API not ready")
    func noContextIsNotReady() async throws {
        let fixture = try TLSFixture()
        let server = try fixture.serve("HTTP/1.0 200 OK\r\nContent-Length: 2\r\n\r\nok")
        defer { server.stop() }
        try await waitUntilListening(server.port)

        let ready = await ClusterAPIReady.isReady(
            endpoint: URL(string: "https://127.0.0.1:\(server.port)"), context: "prod",
            kubeconfig: try fixture.kubeconfig(context: "dev"))

        #expect(!ready)
    }

    @Test("no endpoint is API not ready")
    func noEndpointIsNotReady() async throws {
        let fixture = try TLSFixture()
        #expect(await !ClusterAPIReady.isReady(endpoint: nil, context: "dev", kubeconfig: try fixture.kubeconfig()))
    }
}

struct KubeconfigCATests {
    private let pluginShape = """
        apiVersion: v1
        clusters:
          - cluster:
              certificate-authority-data: Q0EtQQ==
              server: https://127.0.0.1:6445
            name: alpha
          - cluster:
              certificate-authority-data: "Q0EtQg=="
              server: https://127.0.0.1:6446
            name: beta
        contexts:
          - context:
              cluster: alpha
              user: alpha
            name: alpha
          - context:
              cluster: beta
              user: beta
            name: beta-context
        current-context: alpha
        kind: Config
        users:
          - name: alpha
            user:
              exec:
                env:
                  - name: beta
                    value: x
        """

    private let kubectlShape = """
        apiVersion: v1
        clusters:
        - cluster:
            certificate-authority-data: Q0EtQQ==
            extensions:
            - name: alpha
              extension: {}
          name: alpha
        contexts:
        - context:
            cluster: alpha
          name: alpha
        kind: Config
        """

    @Test("the CA comes from the cluster that the named context uses")
    func caOfTheContextCluster() {
        #expect(KubeconfigCA.data(context: "alpha", in: pluginShape) == "Q0EtQQ==")
        #expect(KubeconfigCA.data(context: "beta-context", in: pluginShape) == "Q0EtQg==")
    }

    @Test("a list that is not indented under its key is read too")
    func kubectlShapeIsRead() {
        #expect(KubeconfigCA.data(context: "alpha", in: kubectlShape) == "Q0EtQQ==")
    }

    @Test("no context of that name gives no CA")
    func missingContextGivesNothing() {
        #expect(KubeconfigCA.data(context: "beta", in: pluginShape) == nil)
        #expect(KubeconfigCA.data(context: "alpha", in: "apiVersion: v1\nkind: Config\n") == nil)
    }
}
