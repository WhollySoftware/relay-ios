import Foundation

/// Typed, stateless wrapper over every Relay REST endpoint (protocol/openapi.yaml). Use it
/// directly for full control; `ChatStore` builds the reactive layer on top of it.
public final class RelayAPI: Sendable {
    private let config: RelayConfig
    private let tokens: TokenSource

    init(config: RelayConfig, tokens: TokenSource) {
        self.config = config
        self.tokens = tokens
    }

    // MARK: - Transport

    private struct Empty: Decodable {}
    private struct ErrorBody: Decodable { let error: String?; let message: String? }

    /// Generic transport — public so sibling modules (RelayCall) can add endpoints in extensions.
    public func request<Response: Decodable>(_ method: String, _ path: String, query: [String: String?] = [:],
                                      body: (some Encodable)? = Optional<String>.none, retryOn401: Bool = true) async throws -> Response {
        var components = URLComponents(url: config.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        let items = query.compactMap { key, value in value.map { URLQueryItem(name: key, value: $0) } }
        if !items.isEmpty { components.queryItems = items }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue(config.publicKey, forHTTPHeaderField: "X-Relay-Key")
        request.setValue("Bearer \(try await tokens.get())", forHTTPHeaderField: "Authorization")
        // Lets the service enforce an optional per-project app allowlist (PATCH
        // /projects/me/settings' iosBundleIds) — a public key copied into an unregistered app is
        // then rejected. Always sent; the service only checks it when that allowlist is non-empty.
        if let bundleId = Bundle.main.bundleIdentifier {
            request.setValue(bundleId, forHTTPHeaderField: "X-App-Bundle-Id")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try RelayJSON.encoder.encode(body)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await config.session.data(for: request)
        } catch {
            throw RelayError.network(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 && retryOn401 {
            // Tokens live 15 minutes — refresh once and retry.
            _ = try await tokens.refresh()
            return try await self.request(method, path, query: query, body: body, retryOn401: false)
        }
        guard (200..<300).contains(status) else {
            let parsed = try? RelayJSON.decoder.decode(ErrorBody.self, from: data)
            throw RelayError.server(status: status, code: parsed?.error ?? "http_error",
                                    message: parsed?.message ?? "Request failed with status \(status)")
        }
        if Response.self == Empty.self || data.isEmpty { return try RelayJSON.decoder.decode(Response.self, from: "{}".data(using: .utf8)!) }
        do {
            return try RelayJSON.decoder.decode(Response.self, from: data)
        } catch {
            throw RelayError.decoding(String(describing: error))
        }
    }

    // MARK: - Users

    private struct UserEnvelope: Decodable { let user: RelayUser }
    private struct UsersEnvelope: Decodable { let users: [RelayUser] }

    public func me() async throws -> RelayUser {
        let env: UserEnvelope = try await request("GET", "/users/me")
        return env.user
    }

    /// Resolve names/avatars/presence for up to 100 of your own user ids.
    public func users(_ ids: [UserId]) async throws -> [RelayUser] {
        guard !ids.isEmpty else { return [] }
        let env: UsersEnvelope = try await request("GET", "/users", query: ["ids": ids.joined(separator: ",")])
        return env.users
    }

    // MARK: - Conversations

    private struct ConversationEnvelope: Decodable { let conversation: Conversation }
    private struct ConversationsEnvelope: Decodable { let conversations: [Conversation] }
    private struct OpenBody: Encodable { let userId: UserId }
    private struct GroupBody: Encodable { let name: String; let userIds: [UserId]; let photoUrl: String? }
    private struct UpdateGroupBody: Encodable { let name: String?; let photoUrl: String? }
    private struct MembersBody: Encodable { let userIds: [UserId] }
    public struct ParticipantsResponse: Decodable, Sendable { public let creatorId: UserId?; public let participants: [Participant] }
    public struct DeleteResult: Decodable, Sendable { public let ok: Bool; public let deleted: Bool?; public let left: Bool? }
    public struct OkResult: Decodable, Sendable { public let ok: Bool }

    public func listConversations(includeEmpty: Bool = false) async throws -> [Conversation] {
        let env: ConversationsEnvelope = try await request("GET", "/conversations", query: ["includeEmpty": includeEmpty ? "true" : nil])
        return env.conversations
    }

    public func getConversation(_ id: ConversationId) async throws -> Conversation {
        (try await request("GET", "/conversations/\(id)") as ConversationEnvelope).conversation
    }

    /// Open (or reuse) the 1:1 conversation with another user.
    public func openConversation(with userId: UserId) async throws -> Conversation {
        (try await request("POST", "/conversations", body: OpenBody(userId: userId)) as ConversationEnvelope).conversation
    }

    public func createGroup(name: String, userIds: [UserId], photoUrl: String? = nil) async throws -> Conversation {
        (try await request("POST", "/conversations/group", body: GroupBody(name: name, userIds: userIds, photoUrl: photoUrl)) as ConversationEnvelope).conversation
    }

    public func updateGroup(_ id: ConversationId, name: String? = nil, photoUrl: String?? = nil) async throws -> Conversation {
        let body = UpdateGroupBody(name: name, photoUrl: photoUrl.flatMap { $0 } ?? (photoUrl != nil ? "" : nil))
        return (try await request("PATCH", "/conversations/\(id)", body: body) as ConversationEnvelope).conversation
    }

    /// 1:1 → deletes for both sides. Group → leaves.
    public func deleteConversation(_ id: ConversationId) async throws -> DeleteResult {
        try await request("DELETE", "/conversations/\(id)")
    }

    public func participants(of id: ConversationId) async throws -> ParticipantsResponse {
        try await request("GET", "/conversations/\(id)/participants")
    }

    public func addMembers(_ id: ConversationId, userIds: [UserId]) async throws {
        let _: OkResult = try await request("POST", "/conversations/\(id)/participants", body: MembersBody(userIds: userIds))
    }

    public func removeMember(_ id: ConversationId, userId: UserId) async throws {
        let encoded = userId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? userId
        let _: OkResult = try await request("DELETE", "/conversations/\(id)/participants/\(encoded)")
    }

    public func clearHistory(_ id: ConversationId) async throws {
        let _: OkResult = try await request("POST", "/conversations/\(id)/clear")
    }

    public struct MuteResult: Decodable, Sendable { public let ok: Bool; public let muted: Bool }
    private struct MuteBody: Encodable { let muted: Bool }

    /// Mute/unmute notifications for the CURRENT user only — a personal preference, invisible to
    /// other members.
    public func muteConversation(_ id: ConversationId, muted: Bool) async throws -> MuteResult {
        try await request("PATCH", "/conversations/\(id)/mute", body: MuteBody(muted: muted))
    }

    // MARK: - Messages

    private struct MessageEnvelope: Decodable { let message: Message; let clientId: String? }
    private struct SendBody: Encodable {
        let body: String?; let imageUrl: String?; let audioUrl: String?; let audioDurationSec: Int?
        let fileUrl: String?; let fileName: String?; let fileSizeBytes: Int?; let fileThumbnailUrl: String?; let fileDurationSec: Int?
        let replyToId: String?; let clientId: String?
    }
    private struct EditBody: Encodable { let body: String }
    public struct ReadResult: Decodable, Sendable { public let ok: Bool; public let lastReadAt: Date }
    private struct ReceiptsEnvelope: Decodable { let receipts: [ReadReceipt] }

    public func messages(in id: ConversationId, before: MessageId? = nil, limit: Int = 50) async throws -> MessagesPage {
        try await request("GET", "/conversations/\(id)/messages", query: ["before": before, "limit": String(limit)])
    }

    /// Messages with an image/audio/file attachment only (excludes deleted messages) — backs the
    /// "Media, links & docs" gallery without paging through the whole text history.
    public func getMedia(_ id: ConversationId, before: MessageId? = nil, limit: Int = 60) async throws -> MessagesPage {
        try await request("GET", "/conversations/\(id)/messages", query: ["kind": "media", "before": before, "limit": String(limit)])
    }

    public func sendMessage(in id: ConversationId, _ input: SendMessageInput) async throws -> Message {
        let body = SendBody(body: input.body, imageUrl: input.imageUrl, audioUrl: input.audioUrl,
                            audioDurationSec: input.audioDurationSec, fileUrl: input.fileUrl, fileName: input.fileName,
                            fileSizeBytes: input.fileSizeBytes, fileThumbnailUrl: input.fileThumbnailUrl, fileDurationSec: input.fileDurationSec,
                            replyToId: input.replyToId, clientId: input.clientId)
        let env: MessageEnvelope = try await request("POST", "/conversations/\(id)/messages", body: body)
        var message = env.message
        message.clientId = env.clientId
        return message
    }

    public func editMessage(in id: ConversationId, messageId: MessageId, body: String) async throws -> Message {
        (try await request("PATCH", "/conversations/\(id)/messages/\(messageId)", body: EditBody(body: body)) as MessageEnvelope).message
    }

    public func deleteMessage(in id: ConversationId, messageId: MessageId) async throws -> Message {
        (try await request("DELETE", "/conversations/\(id)/messages/\(messageId)") as MessageEnvelope).message
    }

    public func markRead(_ id: ConversationId) async throws -> ReadResult {
        try await request("POST", "/conversations/\(id)/read")
    }

    public func readReceipts(_ id: ConversationId) async throws -> [ReadReceipt] {
        (try await request("GET", "/conversations/\(id)/read-receipts") as ReceiptsEnvelope).receipts
    }

    public struct MessageReceiptEntry: Codable, Sendable { public let userId: String; public let readAt: String?; public let deliveredAt: String? }
    public struct MessageReceiptsResponse: Codable, Sendable { public let readBy: [MessageReceiptEntry]; public let deliveredTo: [MessageReceiptEntry] }

    /// Per-message read/delivery breakdown for a message YOU sent — unlike `readReceipts`, which
    /// only exposes each participant's conversation-wide "last read" watermark, this answers who
    /// has read *this specific* message vs. only received it, for the "Message info" screen.
    public func getMessageReceipts(_ id: ConversationId, messageId: MessageId) async throws -> MessageReceiptsResponse {
        try await request("GET", "/conversations/\(id)/messages/\(messageId)/receipts")
    }

    private struct LinkPreviewEnvelope: Decodable { let preview: LinkPreview? }

    /// OG metadata for a URL found in a message body, for a WhatsApp-style preview card. Server-
    /// cached, so calling this repeatedly for the same URL across viewers is cheap. Returns nil
    /// when the page has nothing usable (or is unreachable / not HTML / a private address).
    public func linkPreview(url: String) async throws -> LinkPreview? {
        (try await request("GET", "/link-preview", query: ["url": url]) as LinkPreviewEnvelope).preview
    }

    // MARK: - Presence

    /// Tell peers you're going offline right now — call from the app's background transition
    /// alongside `RelayClient.disconnect()`, since the socket's close frame may never reach the
    /// server once iOS suspends the process.
    public func goOffline() async throws {
        let _: OkResult = try await request("POST", "/presence/offline")
    }

    // MARK: - Push devices

    /// Register this device's push token so a closed app still rings (`apnsVoip`, the PushKit
    /// token) and gets chat alerts (`apns`, the regular APNs token, or `fcm` for Firebase apps).
    /// Idempotent; call on every launch. A token that belonged to another user moves to this one.
    public func registerDevice(token: String, type: DeviceTokenType) async throws {
        struct Body: Encodable { let token: String; let tokenType: String }
        let _: Empty = try await request("POST", "/devices", body: Body(token: token, tokenType: type.rawValue))
    }

    /// Call on sign-out so a shared device stops ringing for the previous account.
    public func unregisterDevice(token: String) async throws {
        struct Body: Encodable { let token: String }
        let _: Empty = try await request("DELETE", "/devices", body: Body(token: token))
    }
}

public enum DeviceTokenType: String, Sendable {
    case fcm
    case apns
    case apnsVoip = "apns_voip"
}
