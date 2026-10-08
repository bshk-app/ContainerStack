import ContainerStackCore
import Foundation

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
    private var arrivals: [String: [CheckedContinuation<Void, Never>]] = [:]

    /// `answers` maps a path, without its query, to the JSON body of a 200 response.
    init(answers: [String: String], holding held: Set<String> = []) {
        self.answers = answers
        self.held = held
    }

    func send(request: Data) async throws -> Data {
        let path = Self.path(of: request)
        requested.insert(path)
        for waiter in arrivals.removeValue(forKey: path) ?? [] { waiter.resume() }
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

    func waitUntilRequested(_ path: String) async {
        guard !requested.contains(path) else { return }
        await withCheckedContinuation { arrivals[path, default: []].append($0) }
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
