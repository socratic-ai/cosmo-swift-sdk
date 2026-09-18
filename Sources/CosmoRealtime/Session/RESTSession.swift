import Foundation
import OpenAPIURLSession

/// Refuses HTTP redirects, and — when `acceptsAnyCertificate` — accepts the
/// server's certificate.
///
/// Redirects are refused on every REST call because each carries the client's
/// credential: URLSession would otherwise follow a 30x silently, re-sending
/// that credential wherever it points, including a plain-http downgrade the
/// base-URL check cannot see. The un-followed response reaches the caller as
/// its own 30x.
///
/// The certificate half is enabled only when ``VerifyTLS/resolve(forHost:)``
/// is `false`: under the default ``VerifyTLS/auto`` that is loopback only, so
/// remote hosts keep standard verification; ``VerifyTLS/disabled`` opts every
/// host out.
private final class RESTSessionDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate,
    @unchecked Sendable
{
    private let acceptsAnyCertificate: Bool

    init(acceptsAnyCertificate: Bool) {
        self.acceptsAnyCertificate = acceptsAnyCertificate
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard
            acceptsAnyCertificate,
            challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
            let trust = challenge.protectionSpace.serverTrust
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// A URLSession for the REST session-start / mint calls. Refuses redirects.
/// When `verifyTLS` resolves to "do not verify" for `host` (default: loopback
/// only), the session also accepts a self-signed certificate; otherwise it
/// uses standard verification.
func makeRESTSession(
    configuration: URLSessionConfiguration,
    verifyTLS: VerifyTLS,
    host: String?
) -> URLSession {
    URLSession(
        configuration: configuration,
        delegate: RESTSessionDelegate(
            acceptsAnyCertificate: !verifyTLS.resolve(forHost: host ?? "")
        ),
        delegateQueue: nil
    )
}

/// The URLSession-backed OpenAPI transport for the session-surface REST
/// calls, with the client's timeout and loopback-TLS policy applied.
/// Shared by the session transport, the prepare path, and the mint client
/// so their request plumbing can't drift.
///
/// Takes the three fields it needs rather than a client, because
/// ``RealtimeClient`` builds its own transport during initialization.
func makeRESTTransport(
    requestTimeout: TimeInterval,
    verifyTLS: VerifyTLS,
    host: String?
) -> URLSessionTransport {
    let configuration = URLSessionConfiguration.default
    configuration.timeoutIntervalForRequest = requestTimeout
    configuration.timeoutIntervalForResource = requestTimeout
    return URLSessionTransport(
        configuration: .init(session: makeRESTSession(
            configuration: configuration,
            verifyTLS: verifyTLS,
            host: host
        ))
    )
}

/// The transport for a client's own REST plumbing.
func makeRESTTransport(client: RealtimeClient) -> URLSessionTransport {
    makeRESTTransport(
        requestTimeout: client.requestTimeout,
        verifyTLS: client.verifyTLS,
        host: client.baseURL.host
    )
}
