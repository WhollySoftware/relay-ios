import Foundation

/// Gateway WebSocket with the behaviour every client needs: exponential backoff with jitter,
/// `{"event":"ping"}` heartbeats (presence TTL is 70s), token refresh on a 4401 close, identity-
/// checked callbacks so a superseded task can't clobber the live connection, and a
/// `reconnected` signal so state can be re-synced — the server does NOT replay events missed
/// while disconnected.
@MainActor
final class RelaySocket {
    enum Signal { case connected, reconnected, disconnected(code: Int), event(RelayEvent), state(ConnectionSnapshot) }

    private let config: RelayConfig
    private let tokens: TokenSource
    private let handler: @MainActor (Signal) -> Void
    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var wantOpen = false
    private var everConnected = false
    private(set) var snapshot: ConnectionSnapshot = .idle
    private var openContinuations: [CheckedContinuation<Void, Error>] = []

    init(config: RelayConfig, tokens: TokenSource, handler: @escaping @MainActor (Signal) -> Void) {
        self.config = config
        self.tokens = tokens
        self.handler = handler
        self.session = config.session
    }

    var isOpen: Bool { snapshot.state == .connected }

    /// Opens the connection and keeps it open until `close()`. Resolves on the first successful connect.
    func connect() async throws {
        wantOpen = true
        if snapshot.state == .connected { return }
        if snapshot.state == .idle || snapshot.state == .closed { open() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            openContinuations.append(continuation)
        }
    }

    func close() {
        wantOpen = false
        cancelTimers()
        let current = task
        task = nil
        current?.cancel(with: .normalClosure, reason: nil)
        setState(ConnectionSnapshot(state: .closed, attempts: 0, lastError: nil))
        failWaiters(RelayError.closed)
    }

    /// Send a client → server frame. Returns false (dropped) when not connected.
    @discardableResult
    func send(_ frame: [String: Any]) -> Bool {
        guard let task, snapshot.state == .connected,
              JSONSerialization.isValidJSONObject(frame),
              let data = try? JSONSerialization.data(withJSONObject: frame),
              let text = String(data: data, encoding: .utf8) else { return false }
        task.send(.string(text)) { _ in }
        return true
    }

    // MARK: - Lifecycle

    private func open() {
        guard wantOpen else { return }
        setState(ConnectionSnapshot(state: everConnected ? .reconnecting : .connecting, attempts: snapshot.attempts, lastError: snapshot.lastError))
        Task { [weak self] in
            guard let self else { return }
            let token: String
            do { token = try await self.tokens.get() } catch {
                self.scheduleReconnect(error.localizedDescription); return
            }
            guard self.wantOpen else { return }
            var components = URLComponents(url: self.config.gatewayURL, resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "key", value: self.config.publicKey), URLQueryItem(name: "token", value: token)]
            var request = URLRequest(url: components.url!)
            // Same app-allowlist header as RelayAPI's REST calls (X-App-Bundle-Id) — the gateway
            // upgrade enforces it too, via a URLRequest since webSocketTask(with: URL) can't carry
            // custom headers.
            if let bundleId = Bundle.main.bundleIdentifier {
                request.setValue(bundleId, forHTTPHeaderField: "X-App-Bundle-Id")
            }
            let task = self.session.webSocketTask(with: request)
            self.task = task
            task.resume()
            self.awaitOpen(task)
        }
    }

    /// The connection counts as open only once the server's `connected` frame arrives — that is
    /// sent AFTER the gateway has subscribed this user's channels, so anything published from
    /// then on is guaranteed to reach us. Resolving on the raw transport open (or a ping
    /// round-trip, which the transport answers before the app-level setup) would let a message
    /// sent immediately after connect() slip through the gap.
    private func awaitOpen(_ task: URLSessionWebSocketTask) {
        startReceiving(task)
    }

    private func markOpen(_ task: URLSessionWebSocketTask) {
        guard self.task === task, snapshot.state != .connected else { return }
        let wasReconnect = everConnected
        everConnected = true
        setState(ConnectionSnapshot(state: .connected, attempts: 0, lastError: nil))
        startPing(task)
        resumeWaiters()
        handler(.connected)
        if wasReconnect { handler(.reconnected) }
    }

    private func startReceiving(_ task: URLSessionWebSocketTask) {
        receiveTask?.cancel()
        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let message = try await task.receive()
                    guard let self, self.task === task else { return }
                    let data: Data?
                    switch message {
                    case .data(let d): data = d
                    case .string(let s): data = s.data(using: .utf8)
                    @unknown default: data = nil
                    }
                    if let data, let event = RelayEvent.decode(data) {
                        if case .connected = event { self.markOpen(task) }
                        self.handler(.event(event))
                    }
                } catch {
                    guard let self, self.task === task else { return }
                    self.handleClose(task: task, code: task.closeCode.rawValue, reason: error.localizedDescription)
                    return
                }
            }
        }
    }

    private func handleClose(task: URLSessionWebSocketTask, code: Int, reason: String) {
        guard self.task === task else { return }
        self.task = nil
        cancelTimers()
        handler(.disconnected(code: code))
        guard wantOpen else { return }
        if code == 4401 || code == 4403 {
            // Token expired or was revoked — get a fresh one before trying again.
            Task { _ = try? await tokens.refresh() }
        }
        scheduleReconnect(code == 4429 ? "too many connections" : (reason.isEmpty ? "closed (\(code))" : reason))
    }

    private func scheduleReconnect(_ lastError: String) {
        guard wantOpen else { return }
        let attempts = snapshot.attempts + 1
        setState(ConnectionSnapshot(state: everConnected ? .reconnecting : .connecting, attempts: attempts, lastError: lastError))
        let base = min(config.maxBackoff, pow(2, Double(min(attempts - 1, 6))))
        let delay = base / 2 + Double.random(in: 0...(base / 2)) // jitter: 50–100% of base
        config.logger?("[relay] reconnecting in \(String(format: "%.1f", delay))s (\(lastError))")
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.reconnectTask = nil
            self.open()
        }
    }

    private func startPing(_ task: URLSessionWebSocketTask) {
        pingTask?.cancel()
        let interval = config.pingInterval
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled, let self, self.task === task else { return }
                self.send(["event": "ping"])
            }
        }
    }

    private func cancelTimers() {
        pingTask?.cancel(); pingTask = nil
        receiveTask?.cancel(); receiveTask = nil
        reconnectTask?.cancel(); reconnectTask = nil
    }

    private func setState(_ next: ConnectionSnapshot) {
        snapshot = next
        handler(.state(next))
    }

    private func resumeWaiters() {
        let waiters = openContinuations
        openContinuations = []
        waiters.forEach { $0.resume() }
    }

    private func failWaiters(_ error: Error) {
        let waiters = openContinuations
        openContinuations = []
        waiters.forEach { $0.resume(throwing: error) }
    }
}
