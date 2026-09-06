import Foundation

// Wire models — field-for-field the same as protocol/openapi.yaml and packages/web/core/src/types.ts.
// `userId` is ALWAYS the host app's own user id.

public typealias UserId = String
public typealias ConversationId = String
public typealias MessageId = String

public struct RelayUser: Codable, Sendable, Equatable, Identifiable {
    public var id: UserId { userId }
    public let userId: UserId
    public var displayName: String?
    public var avatarUrl: String?
    public var isOnline: Bool?
    public var lastSeenAt: Date?

    public init(userId: UserId, displayName: String? = nil, avatarUrl: String? = nil, isOnline: Bool? = nil, lastSeenAt: Date? = nil) {
        self.userId = userId; self.displayName = displayName; self.avatarUrl = avatarUrl; self.isOnline = isOnline; self.lastSeenAt = lastSeenAt
    }
}

public struct GroupMember: Codable, Sendable, Equatable, Identifiable {
    public var id: UserId { userId }
    public let userId: UserId
    public var displayName: String?
    public var avatarUrl: String?
    public var isOnline: Bool

    public init(userId: UserId, displayName: String? = nil, avatarUrl: String? = nil, isOnline: Bool = false) {
        self.userId = userId; self.displayName = displayName; self.avatarUrl = avatarUrl; self.isOnline = isOnline
    }
}

public enum MessageKind: String, Codable, Sendable { case text, image, audio, deleted }

public struct MessagePreview: Codable, Sendable, Equatable {
    public let id: MessageId
    public let senderId: UserId
    public let kind: MessageKind
    public let body: String
    public let createdAt: Date

    public init(id: MessageId, senderId: UserId, kind: MessageKind, body: String, createdAt: Date) {
        self.id = id; self.senderId = senderId; self.kind = kind; self.body = body; self.createdAt = createdAt
    }
}

public struct Conversation: Codable, Sendable, Equatable, Identifiable {
    public let id: ConversationId
    public let isGroup: Bool
    public var name: String?
    public var photoUrl: String?
    public var creatorId: UserId?
    /// The other person in a 1:1 conversation; nil for groups.
    public var peer: RelayUser?
    /// Up to 6 other members of a group (preview); empty for 1:1.
    public var members: [GroupMember]
    public var memberCount: Int
    public var lastMessage: MessagePreview?
    public var lastMessageAt: Date?
    public var unreadCount: Int
    public let createdAt: Date

    public init(id: ConversationId, isGroup: Bool, name: String? = nil, photoUrl: String? = nil, creatorId: UserId? = nil,
                peer: RelayUser? = nil, members: [GroupMember] = [], memberCount: Int, lastMessage: MessagePreview? = nil,
                lastMessageAt: Date? = nil, unreadCount: Int = 0, createdAt: Date) {
        self.id = id; self.isGroup = isGroup; self.name = name; self.photoUrl = photoUrl; self.creatorId = creatorId
        self.peer = peer; self.members = members; self.memberCount = memberCount; self.lastMessage = lastMessage
        self.lastMessageAt = lastMessageAt; self.unreadCount = unreadCount; self.createdAt = createdAt
    }

    /// Display title: the group name, or the peer's name/id.
    public var title: String {
        if isGroup { return name ?? "Group" }
        return peer?.displayName ?? peer?.userId ?? "Conversation"
    }
}

public struct ReplyPreview: Codable, Sendable, Equatable {
    public let id: MessageId
    public let senderId: UserId
    public let body: String
    public let deleted: Bool

    public init(id: MessageId, senderId: UserId, body: String, deleted: Bool) {
        self.id = id; self.senderId = senderId; self.body = body; self.deleted = deleted
    }
}

public enum MessageStatus: String, Codable, Sendable { case sending, sent, failed }

public struct Message: Codable, Sendable, Equatable, Identifiable {
    public let id: MessageId
    public let conversationId: ConversationId
    public let senderId: UserId
    public var body: String
    public let createdAt: Date
    public var editedAt: Date?
    public var deleted: Bool
    public var imageUrl: String?
    public var audioUrl: String?
    public var audioDurationSec: Int?
    public var replyTo: ReplyPreview?
    /// Client-generated id for optimistic sends; echoed by the server.
    public var clientId: String?
    /// Only set on locally-originated messages while in flight.
    public var status: MessageStatus?
    /// Set when status == .failed.
    public var error: String?

    public init(id: MessageId, conversationId: ConversationId, senderId: UserId, body: String, createdAt: Date,
                editedAt: Date? = nil, deleted: Bool = false, imageUrl: String? = nil, audioUrl: String? = nil,
                audioDurationSec: Int? = nil, replyTo: ReplyPreview? = nil, clientId: String? = nil,
                status: MessageStatus? = nil, error: String? = nil) {
        self.id = id; self.conversationId = conversationId; self.senderId = senderId; self.body = body
        self.createdAt = createdAt; self.editedAt = editedAt; self.deleted = deleted; self.imageUrl = imageUrl
        self.audioUrl = audioUrl; self.audioDurationSec = audioDurationSec; self.replyTo = replyTo
        self.clientId = clientId; self.status = status; self.error = error
    }

    public var isPending: Bool { status == .sending || status == .failed }
    public var kind: MessageKind {
        if deleted { return .deleted }
        if imageUrl != nil && body.isEmpty { return .image }
        if audioUrl != nil && body.isEmpty { return .audio }
        return .text
    }
}

public struct SendMessageInput: Sendable, Equatable {
    public var body: String?
    /// http(s) URL, or an image data URL under 2.5MB.
    public var imageUrl: String?
    /// http(s) URL, or an audio data URL under 6MB.
    public var audioUrl: String?
    public var audioDurationSec: Int?
    public var replyToId: MessageId?
    /// Supply your own to correlate; generated otherwise.
    public var clientId: String?

    public init(body: String? = nil, imageUrl: String? = nil, audioUrl: String? = nil, audioDurationSec: Int? = nil,
                replyToId: MessageId? = nil, clientId: String? = nil) {
        self.body = body; self.imageUrl = imageUrl; self.audioUrl = audioUrl; self.audioDurationSec = audioDurationSec
        self.replyToId = replyToId; self.clientId = clientId
    }
}

public struct Participant: Codable, Sendable, Equatable, Identifiable {
    public var id: UserId { userId }
    public let userId: UserId
    public var displayName: String?
    public var avatarUrl: String?
    public var isOnline: Bool
    public var lastSeenAt: Date?
    public let joinedAt: Date
}

public struct ReadReceipt: Codable, Sendable, Equatable {
    public let userId: UserId
    public let lastReadAt: Date?
    public init(userId: UserId, lastReadAt: Date?) { self.userId = userId; self.lastReadAt = lastReadAt }
}

public struct MessagesPage: Codable, Sendable {
    public let messages: [Message]
    public let hasMore: Bool
}

public struct PresenceInfo: Sendable, Equatable {
    public var online: Bool
    public var lastSeenAt: Date?
    public init(online: Bool, lastSeenAt: Date? = nil) { self.online = online; self.lastSeenAt = lastSeenAt }
}

public enum ConnectionState: String, Sendable { case idle, connecting, connected, reconnecting, closed }

public struct ConnectionSnapshot: Sendable, Equatable {
    public var state: ConnectionState
    /// Consecutive failed attempts (0 while connected).
    public var attempts: Int
    public var lastError: String?
    public static let idle = ConnectionSnapshot(state: .idle, attempts: 0, lastError: nil)
}

// MARK: - JSON coding shared by the API and the socket

enum RelayJSON {
    /// The service emits RFC 3339 timestamps with fractional seconds ("2026-09-06T00:12:34.567Z").
    // ISO8601DateFormatter is documented thread-safe; the annotation only silences the
    // strict-concurrency capture warning for the @Sendable decoding closure.
    nonisolated(unsafe) private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    nonisolated(unsafe) private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = RelayJSON.withFraction.date(from: raw) ?? RelayJSON.plain.date(from: raw) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unrecognised date: \(raw)")
        }
        return d
    }()

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}
