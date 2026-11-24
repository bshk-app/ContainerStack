import Darwin
import Dispatch
import Foundation
import Testing

@testable import ContainerStackCore

struct ClusterConnectionErrorTests {
    @Test func classifiesRealHTTPSConnectionReset() async throws {
        let listener = try loopbackReadinessSocket()
        let source = DispatchSource.makeReadSource(
            fileDescriptor: listener.descriptor, queue: .global(qos: .userInitiated))
        source.setEventHandler {
            let connection = accept(listener.descriptor, nil, nil)
            guard connection >= 0 else { return }
            var reset = linger(l_onoff: 1, l_linger: 0)
            setsockopt(connection, SOL_SOCKET, SO_LINGER, &reset, socklen_t(MemoryLayout<linger>.size))
            close(connection)
        }
        source.setCancelHandler { close(listener.descriptor) }
        source.resume()
        defer { source.cancel() }

        let error = try await connectionError(port: listener.port)
        #expect(ClusterAPIReady.classify(error) == .connectionFailed, "\(error) \(error.userInfo)")
    }

    @Test func classifiesRealHTTPSConnectionRefusal() async throws {
        let error = try await connectionError(port: freeReadinessPort())
        #expect(ClusterAPIReady.classify(error) == .connectionFailed, "\(error) \(error.userInfo)")
    }

    @Test(arguments: [URLError.timedOut, .secureConnectionFailed, .serverCertificateUntrusted, .cancelled])
    func otherErrorsStayNotReady(code: URLError.Code) {
        #expect(ClusterAPIReady.classify(URLError(code) as NSError) == .notReady)
    }

    private func connectionError(port: Int) async throws -> NSError {
        let endpoint = try #require(URL(string: "https://127.0.0.1:\(port)/readyz"))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        do {
            _ = try await session.data(from: endpoint)
        } catch {
            return error as NSError
        }
        Issue.record("Expected the HTTPS request to fail")
        throw URLError(.unknown)
    }
}
