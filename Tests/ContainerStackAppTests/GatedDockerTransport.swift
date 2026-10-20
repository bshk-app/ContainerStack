import ContainerStackCore
import Foundation
import Testing

/// Answers Docker API requests by path, and holds the paths a test names until it releases them,
/// so the test can act while the app waits on that request. A path with no answer fails.
actor GatedDockerTransport: DockerAPITransport {
    struct Unanswered: Error {
        let path: String
    }

    private let answers: [String: String]
    private var held: Set<String>
    private var requested: Set<String> = []
    private var parked: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var arrivals: [(id: UUID, path: String, continuation: CheckedContinuation<Bool, Never>)] = []

    /// `answers` maps a path, without its query, to the JSON body of a 200 response.
    init(answers: [String: String], holding held: Set<String> = []) {
        self.answers = answers
        self.held = held
    }

    func send(request: Data) async throws -> Data {
        let path = Self.path(of: request)
        requested.insert(path)
        let ready = arrivals.filter { $0.path == path }
        arrivals.removeAll { $0.path == path }
        for arrival in ready { arrival.continuation.resume(returning: true) }
        if held.contains(path) {
            await withCheckedContinuation { parked[path, default: []].append($0) }
        }
        guard let body = answers[path] else { throw Unanswered(path: path) }
        let head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n"
        return Data((head + body).utf8)
    }

    func wasRequested(_ path: String) -> Bool {
        requested.contains(path)
    }

    /// Returns once `path` has been requested, or records an issue after `limit` rather than hang.
    func waitUntilRequested(_ path: String, within limit: Duration = .seconds(30)) async {
        guard !requested.contains(path) else { return }
        let id = UUID()
        Task {
            try? await Task.sleep(for: limit)
            expire(id)
        }
        let arrived = await withCheckedContinuation { arrivals.append((id, path, $0)) }
        if !arrived {
            Issue.record("\(path) was not requested within \(limit)")
        }
    }

    private func expire(_ id: UUID) {
        guard let index = arrivals.firstIndex(where: { $0.id == id }) else { return }
        arrivals.remove(at: index).continuation.resume(returning: false)
    }

    func release(_ path: String) {
        held.remove(path)
        for waiter in parked.removeValue(forKey: path) ?? [] { waiter.resume() }
    }

    private static func path(of request: Data) -> String {
        let fields = String(decoding: request, as: UTF8.self).split(separator: " ")
        guard fields.count > 1 else { return "<malformed>" }
        return String(fields[1].prefix { $0 != "?" })
    }
}
