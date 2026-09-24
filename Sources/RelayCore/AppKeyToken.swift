import Foundation

/// Options for `RelayToken.appKey` — a static/backend-less app's own identity, taken at face
/// value instead of authenticated by a backend. See that factory's doc comment for the tradeoff.
public struct AppKeyTokenOptions: Sendable {
    public var baseURL: URL
    /// A restricted, client-embeddable credential (`ak_...`) minted from the admin panel or
    /// `POST /projects/me/keys/:publicKey/app-key` (server-to-server, with the project's secretKey).
    public var appKey: String
    /// Your app's own id for this user/device — whatever identity you have without a backend.
    public var externalId: String
    public var displayName: String?
    public var avatarURL: String?
    public var session: URLSession

    public init(baseURL: URL, appKey: String, externalId: String, displayName: String? = nil, avatarURL: String? = nil, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.appKey = appKey
        self.externalId = externalId
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.session = session
    }
}

private struct TokenMintResponse: Decodable {
    let userToken: String
}

extension RelayToken {
    /// A `.provider` that mints its own userToken directly from the client, using an appKey
    /// instead of a backend endpoint:
    ///
    ///     let relay = RelayClient(config: RelayConfig(
    ///         baseURL: url, publicKey: "pk_…",
    ///         token: .appKey(AppKeyTokenOptions(baseURL: url, appKey: "ak_…", externalId: myDeviceId))
    ///     ))
    ///
    /// Unlike a secretKey-backed backend endpoint, this is safe to ship inside a static app's
    /// bundle — an appKey can only ever mint a token, nothing else a secretKey can do. But it
    /// also means Relay takes the app's word for who `externalId` is instead of a backend having
    /// authenticated them first: anyone holding the appKey can mint a token for any externalId.
    /// Reach for a real backend + secretKey instead whenever the app has (or could have) one —
    /// see the Install section of this package's README.
    public static func appKey(_ options: AppKeyTokenOptions) -> RelayToken {
        .provider {
            var request = URLRequest(url: options.baseURL.appendingPathComponent("users/token"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.setValue("Bearer \(options.appKey)", forHTTPHeaderField: "authorization")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "externalId": options.externalId,
                "displayName": options.displayName as Any? ?? NSNull(),
                "avatarUrl": options.avatarURL as Any? ?? NSNull(),
            ])

            let (data, response) = try await options.session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw RelayError.network("No HTTP response minting a token with the app key")
            }
            guard (200..<300).contains(http.statusCode) else {
                let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                let code = body?["error"] as? String ?? "app_key_token_failed"
                let message = body?["message"] as? String ?? "Failed to mint a token with the app key (\(http.statusCode))"
                throw RelayError.server(status: http.statusCode, code: code, message: message)
            }
            return try JSONDecoder().decode(TokenMintResponse.self, from: data).userToken
        }
    }
}
