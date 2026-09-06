import Foundation

/// Every server → client gateway frame (protocol/events.md). Decoded from the `event`
/// discriminator; unknown events decode as `.unknown` so a newer service never breaks an older
/// SDK.
public enum RelayEvent: Sendable, Equatable {
    case connected(userId: UserId, serverTime: Date)
    case pong
    case chatMessage(conversationId: ConversationId, message: Message, clientId: String?)
    case chatMessageUpdated(conversationId: ConversationId, message: Message)
    case chatRead(conversationId: ConversationId, userId: UserId, lastReadAt: Date)
    case typing(conversationId: ConversationId, userId: UserId)
    case presence(userId: UserId, online: Bool, lastSeenAt: Date?)
    case conversationCreated(conversationId: ConversationId)
    case conversationUpdated(conversationId: ConversationId, name: String?, photoUrl: String?)
    case conversationDeleted(conversationId: ConversationId)
    case conversationCleared(conversationId: ConversationId)
    case membersAdded(conversationId: ConversationId, userIds: [UserId])
    case memberRemoved(conversationId: ConversationId, userId: UserId)
    case memberLeft(conversationId: ConversationId, userId: UserId)
    /// Any event RelayCore doesn't model itself (e.g. call_* frames handled by RelayCall) — the raw frame is kept so other modules can decode it.
    case unknown(event: String, payload: Data)

    public var name: String {
        switch self {
        case .connected: return "connected"
        case .pong: return "pong"
        case .chatMessage: return "chat_message"
        case .chatMessageUpdated: return "chat_message_updated"
        case .chatRead: return "chat_read"
        case .typing: return "typing"
        case .presence: return "presence"
        case .conversationCreated: return "conversation_created"
        case .conversationUpdated: return "conversation_updated"
        case .conversationDeleted: return "conversation_deleted"
        case .conversationCleared: return "conversation_cleared"
        case .membersAdded: return "members_added"
        case .memberRemoved: return "member_removed"
        case .memberLeft: return "member_left"
        case .unknown(let event, _): return event
        }
    }

    /// Flat decoding — one optional-everything struct, then a switch on `event`. Cheaper and
    /// more tolerant than a keyed enum decoder, and matches how the web core parses frames.
    private struct Raw: Decodable {
        let event: String
        let userId: UserId?
        let serverTime: Date?
        let conversationId: ConversationId?
        let message: Message?
        let clientId: String?
        let lastReadAt: Date?
        let online: Bool?
        let lastSeenAt: Date?
        let name: String?
        let photoUrl: String?
        let userIds: [UserId]?
    }

    public static func decode(_ data: Data) -> RelayEvent? {
        guard let raw = try? RelayJSON.decoder.decode(Raw.self, from: data) else { return nil }
        switch raw.event {
        case "connected":
            guard let userId = raw.userId else { return nil }
            return .connected(userId: userId, serverTime: raw.serverTime ?? Date())
        case "pong": return .pong
        case "chat_message":
            guard let c = raw.conversationId, let m = raw.message else { return nil }
            return .chatMessage(conversationId: c, message: m, clientId: raw.clientId)
        case "chat_message_updated":
            guard let c = raw.conversationId, let m = raw.message else { return nil }
            return .chatMessageUpdated(conversationId: c, message: m)
        case "chat_read":
            guard let c = raw.conversationId, let u = raw.userId, let t = raw.lastReadAt else { return nil }
            return .chatRead(conversationId: c, userId: u, lastReadAt: t)
        case "typing":
            guard let c = raw.conversationId, let u = raw.userId else { return nil }
            return .typing(conversationId: c, userId: u)
        case "presence":
            guard let u = raw.userId, let online = raw.online else { return nil }
            return .presence(userId: u, online: online, lastSeenAt: raw.lastSeenAt)
        case "conversation_created":
            guard let c = raw.conversationId else { return nil }
            return .conversationCreated(conversationId: c)
        case "conversation_updated":
            guard let c = raw.conversationId else { return nil }
            return .conversationUpdated(conversationId: c, name: raw.name, photoUrl: raw.photoUrl)
        case "conversation_deleted":
            guard let c = raw.conversationId else { return nil }
            return .conversationDeleted(conversationId: c)
        case "conversation_cleared":
            guard let c = raw.conversationId else { return nil }
            return .conversationCleared(conversationId: c)
        case "members_added":
            guard let c = raw.conversationId else { return nil }
            return .membersAdded(conversationId: c, userIds: raw.userIds ?? [])
        case "member_removed":
            guard let c = raw.conversationId, let u = raw.userId else { return nil }
            return .memberRemoved(conversationId: c, userId: u)
        case "member_left":
            guard let c = raw.conversationId, let u = raw.userId else { return nil }
            return .memberLeft(conversationId: c, userId: u)
        default:
            return .unknown(event: raw.event, payload: data)
        }
    }
}
