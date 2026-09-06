import Foundation

/// A user token minted by the host app's own backend (POST /users/token with the secret key).
/// Tokens live 15 minutes, so pass a provider closure — Relay calls it again whenever the
/// service says the current one is no longer valid. A plain string works for quick experiments.
public enum RelayToken: Sendable {
    case `static`(String)
    case provider(@Sendable () async throws -> String)
}

/// Caches the current token and de-duplicates refreshes so a burst of 401s (list + thread +
/// receipts all failing at once) triggers exactly one call to the provider.
actor TokenSource {
    private let token: RelayToken
    private var current: String?
    private var inflight: Task<String, Error>?

    init(_ token: RelayToken) {
        self.token = token
        if case .static(let value) = token { current = value }
    }

    func get() async throws -> String {
        if let current { return current }
        return try await refresh()
    }

    func refresh() async throws -> String {
        if let inflight { return try await inflight.value }
        let task = Task<String, Error> {
            let value: String
            switch token {
            case .static(let s): value = s
            case .provider(let provide): value = try await provide()
            }
            guard !value.isEmpty else { throw RelayError.noToken }
            return value
        }
        inflight = task
        defer { inflight = nil }
        let value = try await task.value
        current = value
        return value
    }

    func set(_ value: String) { current = value }
    func peek() -> String? { current }
}
