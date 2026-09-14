import Foundation
import Observation

/// The one object a host app holds. Create it once per signed-in user:
///
///     let relay = RelayClient(config: RelayConfig(baseURL: url, publicKey: "pk_…", tokenProvider: { try await myBackend.relayToken() }))
///     try await relay.connect()
///     try await relay.chat.loadConversations()
///
/// `relay.chat` is the observable store most UIs want; `relay.api` is the raw REST surface.
@MainActor
@Observable
public final class RelayClient {
    public let config: RelayConfig
    public let api: RelayAPI
    public let chat: ChatStore
    public private(set) var connection: ConnectionSnapshot = .idle
    public private(set) var me: RelayUser?
    /// Per-project module gating from `GET /users/me`, defaulting to all-enabled before the
    /// first successful `connect()`. Host apps building their own UI for actions the SDK doesn't
    /// own directly (e.g. a call button — see `CallCenter.start`) should check this before
    /// offering those actions.
    public private(set) var modules: RelayModules = RelayModules()

    private let tokens: TokenSource
    private var socket: RelaySocket!
    private var eventListeners: [UUID: @MainActor (RelayEvent) -> Void] = [:]

    public init(config: RelayConfig) {
        self.config = config
        let tokens = TokenSource(config.token)
        self.tokens = tokens
        let api = RelayAPI(config: config, tokens: tokens)
        self.api = api
        var sendFrame: (@MainActor ([String: Any]) -> Void)!
        let store = ChatStore(api: api, send: { frame in sendFrame(frame) })
        self.chat = store
        self.socket = RelaySocket(config: config, tokens: tokens) { [weak self] signal in
            self?.handle(signal)
        }
        sendFrame = { [weak self] frame in _ = self?.socket.send(frame) }
    }

    public var userId: UserId? { me?.userId ?? chat.userId }

    /// Opens the realtime connection and resolves once it is established. Idempotent.
    @discardableResult
    public func connect() async throws -> RelayUser {
        async let userTask = resolveMe()
        try await socket.connect()
        let (user, resolvedModules) = try await userTask
        me = user
        modules = resolvedModules
        chat.setMe(user)
        return user
    }

    private func resolveMe() async throws -> (RelayUser, RelayModules) {
        if let me { return (me, modules) }
        return try await api.meWithModules()
    }

    /// Closes the connection and clears local state. Safe to call on sign-out.
    public func disconnect() {
        socket.close()
        chat.reset()
        me = nil
        modules = RelayModules()
        let tokens = self.tokens
        Task { await tokens.clear() } // sign-out: never send the previous user's token again
    }

    /// Call from the app's background transition: closes the socket AND tells the server
    /// immediately (the close frame may never make it out once iOS suspends the process).
    /// Reconnect with `connect()` when returning to the foreground.
    public func goToBackground() async {
        socket.close()
        try? await api.goOffline()
    }

    /// Subscribe to raw gateway events. Returns a cancellation closure.
    @discardableResult
    public func onEvent(_ handler: @escaping @MainActor (RelayEvent) -> Void) -> () -> Void {
        let id = UUID()
        eventListeners[id] = handler
        return { [weak self] in Task { @MainActor in self?.eventListeners[id] = nil } }
    }

    /// Send a raw client→server frame on the gateway (used by RelayCall for signaling).
    public func sendFrame(_ frame: [String: Any]) { _ = socket.send(frame) }

    public func presence(of userId: UserId) -> PresenceInfo? {
        chat.presence[userId]
    }

    private func handle(_ signal: RelaySocket.Signal) {
        switch signal {
        case .state(let snapshot):
            connection = snapshot
        case .connected:
            chat.reannounceViewing()
        case .reconnected:
            Task { await chat.resync() }
        case .disconnected:
            break
        case .event(let event):
            if case .modulesUpdated(let newModules) = event {
                // Project-wide module gating update, pushed live to every connected client
                // (same delivery model as `presence`) whenever a super admin changes this
                // project's flags. `handle(_:)` runs on the MainActor (RelayClient is
                // @MainActor), so this mutation of the @Observable `modules` property is
                // already on the main thread — SwiftUI views reading it (e.g. the composer's
                // attach button, app-demo's call buttons) re-render automatically.
                modules = newModules
            }
            chat.apply(event)
            for listener in eventListeners.values { listener(event) }
        }
    }
}
