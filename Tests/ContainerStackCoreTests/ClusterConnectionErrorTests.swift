import Foundation
import Testing

@testable import ContainerStackCore

struct ClusterConnectionErrorTests {
    @Test(arguments: [Int(ECONNREFUSED), Int(ECONNRESET)])
    func identifiesConnectionErrors(code: Int) {
        let underlying = NSError(domain: NSPOSIXErrorDomain, code: code)
        let wrapped = NSError(
            domain: NSURLErrorDomain, code: URLError.networkConnectionLost.rawValue,
            userInfo: [NSUnderlyingErrorKey: underlying])
        #expect(ClusterAPIReady.classify(wrapped) == .connectionFailed)
    }

    @Test(arguments: [URLError.timedOut, .secureConnectionFailed, .serverCertificateUntrusted, .cancelled])
    func otherErrorsStayNotReady(code: URLError.Code) {
        #expect(ClusterAPIReady.classify(URLError(code) as NSError) == .notReady)
    }
}
