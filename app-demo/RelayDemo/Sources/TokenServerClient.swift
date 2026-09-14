import Foundation

/// Talks to the SAME token server the web demo uses (`sample-apps/web-demo/token-server.mjs`,
/// started with `npm run demo --workspace=sample-apps/web-demo`, listening on
/// http://localhost:4101). We deliberately do NOT stand up a second backend here — the whole
/// point of the demo is "one small server your team writes, every client SDK talks to it the
/// same way." An iOS Simulator can reach the Mac's `localhost` directly, so no host-machine IP
/// juggling is needed; a physical device would need the Mac's LAN IP instead.
///
/// There is deliberately no in-app fallback that mints tokens with the secret key: the `sk_` key
/// must never ship inside a client binary, so the reference for "the backend part" is only ever
/// `sample-apps/web-demo/token-server.mjs`.
enum TokenServerError: LocalizedError {
    case unreachable(String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .unreachable(let detail):
            return "Couldn't reach the token server at http://localhost:4101 (\(detail)). Start it with `npm run demo --workspace=sample-apps/web-demo` from the repo root, or see README.md for the local-minting fallback."
        case .badResponse:
            return "Token server returned an unexpected response."
        }
    }
}

struct RelayPublicConfig: Decodable {
    let relayUrl: String
    let publicKey: String
}

struct MintedToken: Decodable {
    let userToken: String
    let expiresAt: String?
}

enum TokenServerClient {
    static let baseURL = URL(string: "http://localhost:4101")!

    /// GET /api/config — public info (service URL + publishable key). Safe to call before sign-in.
    static func fetchConfig() async throws -> RelayPublicConfig {
        let (data, response) = try await URLSession.shared.data(from: baseURL.appendingPathComponent("api/config"))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw TokenServerError.badResponse }
        return try JSONDecoder().decode(RelayPublicConfig.self, from: data)
    }

    /// POST /api/token { userId, displayName } — mints a short-lived (15 min) Relay user token.
    /// This is the ONLY network call in the whole app that touches "your backend"; everything
    /// else (chat, calling) goes straight from RelayClient to the Relay service.
    static func mintToken(userId: String, displayName: String) async throws -> MintedToken {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/token"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONEncoder().encode(["userId": userId, "displayName": displayName])
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw TokenServerError.badResponse }
            guard http.statusCode == 200 else {
                let message = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
                throw TokenServerError.unreachable(message ?? "HTTP \(http.statusCode)")
            }
            return try JSONDecoder().decode(MintedToken.self, from: data)
        } catch let error as TokenServerError {
            throw error
        } catch {
            throw TokenServerError.unreachable(error.localizedDescription)
        }
    }
}
