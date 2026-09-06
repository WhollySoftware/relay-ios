import Foundation

public enum RelayError: Error, LocalizedError, Sendable, Equatable {
    /// The service answered with a non-2xx status. `code` is the machine-readable `error` field.
    case server(status: Int, code: String, message: String)
    case decoding(String)
    case network(String)
    case noToken
    case notConnected
    case closed

    public var errorDescription: String? {
        switch self {
        case .server(_, _, let message): return message
        case .decoding(let detail): return "Couldn't read the server's response (\(detail))."
        case .network(let detail): return "Couldn't reach Relay (\(detail))."
        case .noToken: return "No user token available — the token provider returned nothing."
        case .notConnected: return "Not connected."
        case .closed: return "The client was closed."
        }
    }

    public var status: Int? {
        if case .server(let status, _, _) = self { return status }
        return nil
    }

    public var isAuth: Bool { status == 401 }
}
