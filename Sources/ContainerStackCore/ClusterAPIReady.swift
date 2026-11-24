import Foundation
import Security

public enum ClusterAPIReady {
    public enum Result: Equatable, Sendable {
        case ready, notReady, connectionFailed
    }

    public static let localNetworkHint =
        "Likely cause: the runtime has no Local Network permission. Allow container-runtime-linux "
        + "in System Settings > Privacy & Security > Local Network."

    static func classify(_ error: NSError) -> Result {
        if error.domain == NSPOSIXErrorDomain {
            return [Int(ECONNREFUSED), Int(ECONNRESET)].contains(error.code) ? .connectionFailed : .notReady
        }
        if error.userInfo["_kCFStreamErrorDomainKey"] as? Int == 1,
            let code = error.userInfo["_kCFStreamErrorCodeKey"] as? Int,
            [Int(ECONNREFUSED), Int(ECONNRESET)].contains(code)
        {
            return .connectionFailed
        }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            return classify(underlying)
        }
        return .notReady
    }

    public static func isReady(
        endpoint: URL?,
        context: String,
        kubeconfig: URL,
        timeout: Duration = .seconds(3)
    ) async -> Bool {
        await check(endpoint: endpoint, context: context, kubeconfig: kubeconfig, timeout: timeout) == .ready
    }

    public static func check(
        endpoint: URL?,
        context: String,
        kubeconfig: URL,
        timeout: Duration = .seconds(3)
    ) async -> Result {
        guard let endpoint,
            let text = try? String(contentsOf: kubeconfig, encoding: .utf8),
            let encoded = KubeconfigCA.data(context: context, in: text),
            let anchor = KubeconfigCA.certificate(base64: encoded)
        else { return .notReady }

        let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = seconds
        configuration.timeoutIntervalForResource = seconds
        configuration.urlCache = nil
        let session = URLSession(
            configuration: configuration, delegate: AnchorTrust(anchor: anchor), delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: endpoint.appending(path: "readyz"), timeoutInterval: seconds)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (body, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return .notReady }
            return String(decoding: body, as: UTF8.self) == "ok" ? .ready : .notReady
        } catch {
            return classify(error as NSError)
        }
    }
}

private final class AnchorTrust: NSObject, URLSessionTaskDelegate, Sendable {
    private let anchor: SecCertificate

    init(anchor: SecCertificate) {
        self.anchor = anchor
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
            let trust = challenge.protectionSpace.serverTrust
        else { return (.performDefaultHandling, nil) }
        SecTrustSetAnchorCertificates(trust, [anchor] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        guard SecTrustEvaluateWithError(trust, nil) else { return (.cancelAuthenticationChallenge, nil) }
        return (.useCredential, URLCredential(trust: trust))
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}

enum KubeconfigCA {
    static func data(context name: String, in text: String) -> String? {
        guard let context = entries(of: "contexts", in: text).first(where: { $0["name"] == name }),
            let clusterName = context["context.cluster"],
            let cluster = entries(of: "clusters", in: text).first(where: { $0["name"] == clusterName })
        else { return nil }
        return cluster["cluster.certificate-authority-data"]
    }

    static func certificate(base64: String) -> SecCertificate? {
        guard let decoded = Data(base64Encoded: base64) else { return nil }
        let pem = String(decoding: decoded, as: UTF8.self)
        guard let begin = pem.range(of: "-----BEGIN CERTIFICATE-----"),
            let end = pem.range(of: "-----END CERTIFICATE-----", range: begin.upperBound..<pem.endIndex),
            let der = Data(
                base64Encoded: String(pem[begin.upperBound..<end.lowerBound]), options: .ignoreUnknownCharacters)
        else { return SecCertificateCreateWithData(nil, decoded as CFData) }
        return SecCertificateCreateWithData(nil, der as CFData)
    }

    static func entries(of section: String, in text: String) -> [[String: String]] {
        var items: [[String: String]] = []
        var inSection = false
        var itemColumn: Int?
        var parent: String?
        var childColumn: Int?
        for line in text.split(whereSeparator: \.isNewline) {
            let indent = line.prefix { $0 == " " }.count
            var content = line.dropFirst(indent)
            if content.isEmpty || content.hasPrefix("#") { continue }
            if indent == 0, !content.hasPrefix("-") {
                inSection = content.hasPrefix("\(section):")
                itemColumn = nil
                continue
            }
            guard inSection else { continue }
            var column = indent
            if content.hasPrefix("- ") {
                guard itemColumn == nil || itemColumn == indent + 2 else { continue }
                items.append([:])
                itemColumn = indent + 2
                parent = nil
                content = content.dropFirst(2)
                column += 2
            }
            guard let itemColumn, !items.isEmpty, let colon = content.firstIndex(of: ":") else { continue }
            let key = String(content[..<colon])
            let value = Self.scalar(content[content.index(after: colon)...])
            if column == itemColumn {
                parent = value.isEmpty ? key : nil
                childColumn = nil
                if !value.isEmpty { items[items.count - 1][key] = value }
            } else if let parent, column > itemColumn, column == (childColumn ?? column) {
                childColumn = column
                items[items.count - 1]["\(parent).\(key)"] = value
            }
        }
        return items
    }

    private static func scalar(_ raw: Substring) -> String {
        let value = raw.trimmingCharacters(in: .whitespaces)
        for quote in ["\"", "'"] where value.count >= 2 && value.hasPrefix(quote) && value.hasSuffix(quote) {
            return String(value.dropFirst().dropLast())
        }
        return value
    }
}
