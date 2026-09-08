import ContainerStackCore
import Foundation

@MainActor
extension RuntimeViewModel {
    func runtimeLogURL() throws -> URL {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Logs/ContainerStack")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let logURL = directory.appending(path: "runtime.log")
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        return logURL
    }

    func userFacingError(_ error: Error) -> String {
        guard let socketError = error as? UnixSocketError else {
            return String(describing: error)
        }

        switch socketError {
        case .pathTooLong:
            return "Docker socket path is too long: \(socketPath)"
        case .timedOut:
            return "Timed out connecting to Docker socket: \(socketPath)"
        case .systemCallFailed(let code):
            return
                "Docker socket error \(code): \(Darwin.strerror(code).map { String(cString: $0) } ?? "unknown error")"
        }
    }
}
