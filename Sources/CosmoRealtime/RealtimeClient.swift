import CosmoRealtimeAPI
import Foundation
import OpenAPIRuntime
import OpenAPIURLSession

/// A client for the external realtime API: the credential and endpoints,
/// the agent factories, and the credential/usage REST reads. Mirrors the
/// Python ``RealtimeClient``. Construct once with the credential your
/// deployment calls for; reuse it across calls and sessions.
///
/// Which initializer you reach for is a deployment decision:
/// ``init(apiKey:baseURL:connectTimeout:requestTimeout:verifyTLS:transport:)`` for a
/// server-side workspace key, ``init(token:baseURL:connectTimeout:requestTimeout:verifyTLS:transport:)``
/// for a minted per-user JWT, ``init(tokenSource:baseURL:connectTimeout:requestTimeout:verifyTLS:transport:)``
/// to let the SDK fetch and refresh that JWT itself, and
/// ``init(connectTimeout:requestTimeout:verifyTLS:transport:)`` to resolve a key from
/// the environment or the `cosmo login` credentials file.
///
/// Sessions are opened through an agent: ``agent(instructions:model:voice:audio:tools:interruptionSensitivity:greeting:skills:mcp:hooks:)``
/// configures an inline persona, ``catalogAgent(_:inputs:voice:tools:mcp:hooks:)``
/// references a workspace catalog agent, and
/// ``RealtimeAgent/start(resumeSessionId:maxSessionSeconds:storeRecording:storeAudio:storeTranscript:storeVideo:micMuted:rpcHandlers:onStateChange:)``
/// opens one run.
public struct RealtimeClient: Sendable {
    /// How realtime audio and control frames reach the session server.
    public enum Transport: String, Sendable {
        /// The managed/default WebRTC room carrier.
        case webrtc
        /// Deprecated spelling for ``webrtc``.
        @available(*, deprecated, renamed: "webrtc")
        case livekit
        /// The single-socket carrier served by the OSS server.
        case websocket
    }

    let credential: Credential
    /// The Cosmo API origin this client talks to: the `baseURL` passed at
    /// construction, else `COSMO_BASE_URL`, else production. Fixed once the
    /// client is built, so one session talks to one backend and a stored
    /// credential cannot be sent somewhere it was not issued for.
    let baseURL: URL
    /// Timeout for the media-transport join (signaling + ICE).
    let connectTimeout: TimeInterval
    /// Timeout for the REST session-start request. Sized separately from
    /// ``connectTimeout`` because session provisioning is bounded by the
    /// backend's agent dispatch.
    let requestTimeout: TimeInterval
    /// TLS verification for the REST session-start call. ``.auto`` (default)
    /// skips verification only for loopback hosts so a self-signed local-dev
    /// backend works; remote hosts are always verified.
    let verifyTLS: VerifyTLS
    /// Fixed at client creation; every agent built from this client uses it.
    let sessionTransport: Transport
    let transport: any ClientTransport

    /// Convenience: a workspace api-key credential. Server-side only — it
    /// opens sessions AND mints end-user tokens. Never embed it in a
    /// distributed app; ship
    /// ``init(tokenSource:baseURL:connectTimeout:requestTimeout:verifyTLS:transport:)``
    /// against your own token endpoint instead.
    ///
    /// Pass `baseURL` explicitly when the credential itself names the backend
    /// that issued it: a stored or minted credential is only valid against
    /// that origin, and resolving from the environment would send its session
    /// start elsewhere.
    public init(
        apiKey: String,
        baseURL: URL? = nil,
        connectTimeout: TimeInterval = 30,
        requestTimeout: TimeInterval = 45,
        verifyTLS: VerifyTLS = .auto,
        transport: Transport = .webrtc
    ) {
        self.init(
            credential: .apiKey(apiKey),
            baseURL: baseURL,
            connectTimeout: connectTimeout,
            requestTimeout: requestTimeout,
            verifyTLS: verifyTLS,
            sessionTransport: transport
        )
    }

    /// Convenience: a minted per-user JWT — scoped to one external user, safe
    /// to embed in a device or browser. Opens sessions but cannot mint.
    /// A workspace API key (``cosmo_…``) passed here traps at construction:
    /// the backend would honor it as a bearer, which is exactly how a pasted
    /// key ends up shipped. Validate user-supplied values before passing.
    public init(
        token: String,
        baseURL: URL? = nil,
        connectTimeout: TimeInterval = 30,
        requestTimeout: TimeInterval = 45,
        verifyTLS: VerifyTLS = .auto,
        transport: Transport = .webrtc
    ) {
        if CredentialPlacement.isAPIKeyShaped(token) {
            fatalError(CredentialPlacement.apiKeyInTokenSlotMessage)
        }
        self.init(
            credential: .token(token),
            baseURL: baseURL,
            connectTimeout: connectTimeout,
            requestTimeout: requestTimeout,
            verifyTLS: verifyTLS,
            sessionTransport: transport
        )
    }

    /// Convenience: a ``TokenSource`` that fetches — and keeps fresh — a
    /// minted per-user JWT itself, so a distributed app never handles
    /// refresh. Opens sessions but cannot mint.
    public init(
        tokenSource: TokenSource,
        baseURL: URL? = nil,
        connectTimeout: TimeInterval = 30,
        requestTimeout: TimeInterval = 45,
        verifyTLS: VerifyTLS = .auto,
        transport: Transport = .webrtc
    ) {
        self.init(
            credential: .tokenSource(tokenSource),
            baseURL: baseURL,
            connectTimeout: connectTimeout,
            requestTimeout: requestTimeout,
            verifyTLS: verifyTLS,
            sessionTransport: transport
        )
    }

    /// Zero-argument construction: the SDK resolves an API key itself —
    /// `COSMO_API_KEY` from the environment, else the `cosmo login`
    /// credentials file (`COSMO_CREDENTIALS_FILE` or `~/.cosmo/credentials`,
    /// profile from `COSMO_PROFILE`). A file credential brings its own
    /// `base_url` along, since a stored key is only valid against the backend
    /// that issued it. Throws ``CredentialsError`` when nothing resolves, the
    /// file is unusable, or the stored key expired.
    public init(
        connectTimeout: TimeInterval = 30,
        requestTimeout: TimeInterval = 45,
        verifyTLS: VerifyTLS = .auto,
        transport: Transport = .webrtc
    ) throws {
        try self.init(
            environment: ProcessInfo.processInfo.environment,
            connectTimeout: connectTimeout,
            requestTimeout: requestTimeout,
            verifyTLS: verifyTLS,
            sessionTransport: transport
        )
    }

    /// The resolving init against a supplied environment; internal so tests
    /// can inject one without mutating the process environment.
    init(
        environment: [String: String],
        connectTimeout: TimeInterval = 30,
        requestTimeout: TimeInterval = 45,
        verifyTLS: VerifyTLS = .auto,
        sessionTransport: Transport = .webrtc
    ) throws {
        let resolved = try CredentialsFile.resolveFromRuntime(environment: environment)
        var fileBase: URL?
        if let base = resolved.baseURL {
            var raw = base
            while raw.hasSuffix("/") { raw.removeLast() }
            guard let url = URL(string: raw), url.scheme != nil else {
                throw CredentialsError(
                    code: .fileInvalid,
                    message: "The resolved base_url is not a URL: \(base). Run: cosmo login"
                )
            }
            fileBase = url
        }
        self.init(
            credential: .apiKey(resolved.apiKey),
            baseURL: fileBase,
            connectTimeout: connectTimeout,
            requestTimeout: requestTimeout,
            verifyTLS: verifyTLS,
            sessionTransport: sessionTransport
        )
    }

    /// The credential-taking init every public initializer funnels through.
    /// ``baseURL`` defaults to ``RealtimeBaseURL/resolve()`` — the environment
    /// override, else production.
    init(
        credential: Credential,
        baseURL: URL? = nil,
        connectTimeout: TimeInterval = 30,
        requestTimeout: TimeInterval = 45,
        verifyTLS: VerifyTLS = .auto,
        sessionTransport: Transport = .webrtc
    ) {
        let resolved = baseURL ?? RealtimeBaseURL.resolve()
        self.init(
            credential: credential,
            baseURL: resolved,
            connectTimeout: connectTimeout,
            requestTimeout: requestTimeout,
            verifyTLS: verifyTLS,
            sessionTransport: sessionTransport,
            transport: makeRESTTransport(
                requestTimeout: requestTimeout,
                verifyTLS: verifyTLS,
                host: resolved.host
            )
        )
    }

    /// The one initializer that assigns the stored properties; the transport
    /// is a parameter so tests can supply their own.
    init(
        credential: Credential,
        baseURL: URL,
        connectTimeout: TimeInterval,
        requestTimeout: TimeInterval,
        verifyTLS: VerifyTLS,
        sessionTransport: Transport = .webrtc,
        transport: any ClientTransport
    ) {
        self.credential = credential
        self.baseURL = baseURL
        self.connectTimeout = connectTimeout
        self.requestTimeout = requestTimeout
        self.verifyTLS = verifyTLS
        self.sessionTransport = sessionTransport
        self.transport = transport
    }

    /// An inline agent: the persona configured field by field, independent
    /// of any one run. Throws on duplicate skill names — when the agent is
    /// built, not mid-call.
    public func agent(
        instructions: String? = nil,
        model: RealtimeModel? = nil,
        voice: VoiceConfig? = nil,
        audio: AudioConfig? = nil,
        tools: [AgentTool] = [],
        interruptionSensitivity: InterruptionSensitivity? = nil,
        greeting: String? = nil,
        skills: [Skill]? = nil,
        mcp: [McpStdioServer]? = nil,
        hooks: [Hook]? = nil
    ) throws -> RealtimeAgent {
        RealtimeAgent(
            client: self,
            instructions: instructions,
            model: model,
            voice: voice,
            audio: audio,
            tools: tools,
            interruptionSensitivity: interruptionSensitivity,
            greeting: greeting,
            skills: try skills.map(resolveSkills),
            mcp: try mcp.map(resolveMcpServers),
            hooks: hooks
        )
    }

    /// A workspace catalog agent, referenced by machine handle (lowercase
    /// ``[a-z0-9-]``, e.g. ``"driver-pay"``). The stored config runs
    /// verbatim; only per-run ride-alongs may accompany the handle —
    /// ``inputs`` for template placeholders, client ``tools``, the
    /// ``voice``, MCP servers, and client hooks.
    public func catalogAgent(
        _ name: String,
        inputs: [String: String]? = nil,
        voice: VoiceConfig? = nil,
        tools: [AgentTool] = [],
        mcp: [McpStdioServer]? = nil,
        hooks: [Hook]? = nil
    ) throws -> RealtimeAgent {
        RealtimeAgent(
            client: self,
            name: name,
            inputs: inputs,
            voice: voice,
            tools: tools,
            mcp: try mcp.map(resolveMcpServers),
            hooks: hooks
        )
    }

    /// The generated client bound to this client's server and credential.
    func _apiClient() -> CosmoRealtimeAPI.Client {
        CosmoRealtimeAPI.Client(
            serverURL: baseURL,
            configuration: .init(dateTranscoder: RealtimeDateTranscoder()),
            transport: transport,
            middlewares: _apiMiddlewares(prepared: nil)
        )
    }

    /// A 200 whose body failed to decode against the schema: the generated
    /// client raises a ``ClientError`` carrying the 2xx response and a
    /// ``DecodingError``. Distinguishes that from a genuine transport failure
    /// (no decoding cause).
    static func _isSuccessBodyDecodeFailure(_ error: any Error) -> Bool {
        guard
            let clientError = error as? ClientError,
            let status = clientError.response?.status.code,
            (200..<300).contains(status)
        else { return false }
        return clientError.underlyingError is DecodingError
    }

    static func _collectBody(_ payload: OpenAPIRuntime.UndocumentedPayload) async -> String {
        guard let body = payload.body else { return "" }
        return (try? await String(collecting: body, upTo: 64 * 1024)) ?? ""
    }
}

extension RealtimeClient {
    /// The session credential. Exactly one form, chosen at construction —
    /// the enumeration Swift needs where Python and TypeScript type one
    /// parameter `str | TokenSource`.
    enum Credential: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
        /// Workspace-scoped key — server-side only. Opens sessions and
        /// can mint end-user tokens.
        case apiKey(String)
        /// A minted per-user JWT — scoped to one external user, safe to
        /// embed in a device or browser. Opens sessions but cannot mint.
        case token(String)
        /// A ``TokenSource`` that fetches — and keeps fresh — a minted
        /// per-user JWT itself. Opens sessions but cannot mint.
        case tokenSource(TokenSource)

        /// The bearer value sent on the ``Authorization`` header — for a
        /// ``tokenSource(_:)`` credential, the source's current JWT
        /// (fetched or refreshed as needed).
        func bearerToken() async throws -> String {
            switch self {
            case .apiKey(let v), .token(let v): return v
            case .tokenSource(let source): return try await source.jwt()
            }
        }

        static func == (lhs: Credential, rhs: Credential) -> Bool {
            switch (lhs, rhs) {
            case (.apiKey(let l), .apiKey(let r)): return l == r
            case (.token(let l), .token(let r)): return l == r
            case (.tokenSource(let l), .tokenSource(let r)): return l === r
            default: return false
            }
        }

        var description: String {
            switch self {
            case .apiKey: return "Credential.apiKey(•••)"
            case .token: return "Credential.token(•••)"
            case .tokenSource: return "Credential.tokenSource(•••)"
            }
        }
        var debugDescription: String { description }
    }

    /// Whether this client holds a workspace api key — the one credential
    /// form that can mint. Read by ``mintToken(_:ttlSeconds:)``,
    /// which refuses before the request goes out.
    var _hasApiKey: Bool {
        if case .apiKey = credential { return true }
        return false
    }

    /// The bearer value for this client's credential — awaited per request so
    /// a ``Credential/tokenSource(_:)`` can refresh.
    func bearerToken() async throws -> String {
        try await credential.bearerToken()
    }
}
