import Foundation

public struct RelayConfig: Sendable {
    /// e.g. https://relay.example.com — no trailing slash needed.
    public var baseURL: URL
    /// The project's public key (pk_...). Safe to embed in the app.
    public var publicKey: String
    public var token: RelayToken
    /// Override the WebSocket origin (defaults to baseURL with a ws(s) scheme).
    public var webSocketURL: URL?
    /// Heartbeat interval (default 25s — the service's presence TTL is 70s).
    public var pingInterval: TimeInterval = 25
    /// Cap on reconnect backoff (default 30s).
    public var maxBackoff: TimeInterval = 30
    /// Optional diagnostics sink.
    public var logger: (@Sendable (String) -> Void)?
    /// Opt-in verbose diagnostics. When `true` AND `logger` is set, the SDK emits connection
    /// lifecycle, REST call, gateway event, and call lifecycle lines through `logger` — see
    /// "Debugging" in the README. Defaults to `false`: unchanged behavior from before this flag
    /// existed (only the minimal reconnect message logs). Logs are redaction-first by design and
    /// never include tokens, TURN credentials, message content, attachment URLs, or user
    /// display names/avatars.
    public var debug: Bool = false
    /// URLSession to use for REST + WebSocket (tests inject one with a custom protocol).
    public var session: URLSession = .shared

    public init(baseURL: URL, publicKey: String, token: RelayToken, webSocketURL: URL? = nil) {
        self.baseURL = baseURL
        self.publicKey = publicKey
        self.token = token
        self.webSocketURL = webSocketURL
    }

    public init(baseURL: URL, publicKey: String, tokenProvider: @escaping @Sendable () async throws -> String) {
        self.init(baseURL: baseURL, publicKey: publicKey, token: .provider(tokenProvider))
    }

    var gatewayURL: URL {
        let base = webSocketURL ?? baseURL
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "https" ? "wss" : components.scheme == "http" ? "ws" : components.scheme
        components.path = base.path.hasSuffix("/") ? base.path + "ws/gateway" : base.path + "/ws/gateway"
        return components.url!
    }
}
