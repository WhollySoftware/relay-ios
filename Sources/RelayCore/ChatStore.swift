import Foundation
import Observation

/// Reactive chat state — the Swift twin of packages/web/core/src/store.ts. `@Observable` so
/// SwiftUI views re-render on exactly the properties they read. All mutation happens on the main
/// actor; network calls hop off and back.
///
/// Owns the two things every chat client gets wrong on its own:
///  1. Optimistic sends de-duplicated against the WebSocket echo by clientId.
///  2. Re-sync after a reconnect — the server never replays missed events, so conversations are
///     reloaded and every open thread re-fetches its newest page and merges by id.
@MainActor
@Observable
public final class ChatStore {
    public struct Thread: Sendable, Equatable {
        public let conversationId: ConversationId
        public var messages: [Message] = [] // oldest → newest
        public var hasMore = false
        public var loaded = false
        public var loading = false
        public var error: String?
        public init(conversationId: ConversationId) { self.conversationId = conversationId }
    }

    public private(set) var me: RelayUser?
    /// Newest activity first.
    public private(set) var conversations: [Conversation] = []
    public private(set) var conversationsLoaded = false
    public private(set) var conversationsLoading = false
    public private(set) var threads: [ConversationId: Thread] = [:]
    /// userIds currently typing, per conversation (auto-expire after 4s).
    public private(set) var typing: [ConversationId: [UserId]] = [:]
    /// Other participants' read watermarks, per conversation.
    public private(set) var readReceipts: [ConversationId: [UserId: Date?]] = [:]
    public private(set) var presence: [UserId: PresenceInfo] = [:]
    public private(set) var viewingConversationId: ConversationId?

    public var totalUnread: Int { conversations.reduce(0) { $0 + $1.unreadCount } }
    public var userId: UserId? { me?.userId ?? meId }

    private let api: RelayAPI
    private let send: @MainActor ([String: Any]) -> Void
    private var meId: UserId?
    private var typingTimers: [String: Task<Void, Never>] = [:]
    private var lastTypingSent: [ConversationId: Date] = [:]
    private var pendingConversationFetch: [ConversationId: Task<Void, Never>] = [:]

    private static let typingTTL: TimeInterval = 4
    private static let typingThrottle: TimeInterval = 2.5
    private static let pageSize = 50

    init(api: RelayAPI, send: @escaping @MainActor ([String: Any]) -> Void) {
        self.api = api
        self.send = send
    }

    func setMe(_ user: RelayUser) {
        meId = user.userId
        me = user
    }

    // MARK: - Conversations

    @discardableResult
    public func loadConversations(includeEmpty: Bool = false) async throws -> [Conversation] {
        conversationsLoading = true
        defer { conversationsLoading = false }
        let fromServer = try await api.listConversations(includeEmpty: includeEmpty)
        // Keep conversations the user opened locally that are still empty (the server hides
        // those from the default list).
        let serverIds = Set(fromServer.map(\.id))
        let localEmpty = conversations.filter { !serverIds.contains($0.id) && $0.lastMessage == nil && !includeEmpty }
        conversations = Self.sorted(fromServer + localEmpty)
        mergePresence(from: conversations)
        conversationsLoaded = true
        return conversations
    }

    public func conversation(_ id: ConversationId) -> Conversation? {
        conversations.first { $0.id == id }
    }

    @discardableResult
    public func openConversation(with userId: UserId) async throws -> Conversation {
        let conversation = try await api.openConversation(with: userId)
        upsert(conversation)
        return conversation
    }

    @discardableResult
    public func createGroup(name: String, userIds: [UserId], photoUrl: String? = nil) async throws -> Conversation {
        let conversation = try await api.createGroup(name: name, userIds: userIds, photoUrl: photoUrl)
        upsert(conversation)
        return conversation
    }

    @discardableResult
    public func updateGroup(_ id: ConversationId, name: String? = nil, photoUrl: String?? = nil) async throws -> Conversation {
        let conversation = try await api.updateGroup(id, name: name, photoUrl: photoUrl)
        upsert(conversation)
        return conversation
    }

    public func addMembers(_ id: ConversationId, userIds: [UserId]) async throws {
        try await api.addMembers(id, userIds: userIds)
        await refreshConversation(id)
    }

    public func removeMember(_ id: ConversationId, userId: UserId) async throws {
        try await api.removeMember(id, userId: userId)
        await refreshConversation(id)
    }

    /// 1:1 → deletes for both. Group → leave. Either way it disappears locally.
    public func deleteConversation(_ id: ConversationId) async throws {
        _ = try await api.deleteConversation(id)
        remove(id)
    }

    public func clearHistory(_ id: ConversationId) async throws {
        try await api.clearHistory(id)
        clearThread(id)
    }

    public func refreshConversation(_ id: ConversationId) async {
        if let pending = pendingConversationFetch[id] { await pending.value; return }
        let task = Task { [api] in
            do {
                let conversation = try await api.getConversation(id)
                self.upsert(conversation)
            } catch let error as RelayError where error.status == 404 {
                // Removed, or deleted, while the event was in flight.
                self.remove(id)
            } catch {
                // Transient — the next event or reload will retry.
            }
        }
        pendingConversationFetch[id] = task
        await task.value
        pendingConversationFetch[id] = nil
    }

    private func upsert(_ conversation: Conversation) {
        conversations = Self.sorted(conversations.filter { $0.id != conversation.id } + [conversation])
        mergePresence(from: [conversation])
    }

    private func patch(_ id: ConversationId, _ change: (inout Conversation) -> Void) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        var updated = conversations
        change(&updated[index])
        conversations = Self.sorted(updated)
    }

    private func remove(_ id: ConversationId) {
        conversations.removeAll { $0.id == id }
        threads[id] = nil
        typing[id] = nil
        readReceipts[id] = nil
    }

    private static func sorted(_ list: [Conversation]) -> [Conversation] {
        list.sorted { a, b in
            let ta = a.lastMessageAt ?? a.createdAt
            let tb = b.lastMessageAt ?? b.createdAt
            if ta != tb { return ta > tb }
            return (Int(a.id) ?? 0) > (Int(b.id) ?? 0)
        }
    }

    private func mergePresence(from list: [Conversation]) {
        for c in list {
            if let peer = c.peer, let online = peer.isOnline { presence[peer.userId] = PresenceInfo(online: online, lastSeenAt: peer.lastSeenAt) }
            for m in c.members { presence[m.userId] = PresenceInfo(online: m.isOnline, lastSeenAt: presence[m.userId]?.lastSeenAt) }
        }
    }

    // MARK: - Threads / messages

    public func thread(_ id: ConversationId) -> Thread {
        threads[id] ?? Thread(conversationId: id)
    }

    private func setThread(_ id: ConversationId, _ change: (inout Thread) -> Void) {
        var t = thread(id)
        change(&t)
        threads[id] = t
    }

    /// Loads the newest page once; subsequent calls are no-ops unless `force`.
    @discardableResult
    public func loadMessages(_ id: ConversationId, force: Bool = false) async throws -> Thread {
        let current = thread(id)
        if (current.loaded && !force) || current.loading { return current }
        setThread(id) { $0.loading = true; $0.error = nil }
        do {
            async let pageTask = api.messages(in: id, limit: Self.pageSize)
            async let receiptsTask = api.readReceipts(id)
            let page = try await pageTask
            let receipts = (try? await receiptsTask) ?? []
            let pending = thread(id).messages.filter(\.isPending)
            setThread(id) {
                $0.messages = Self.merge(page.messages, pending)
                $0.hasMore = page.hasMore
                $0.loaded = true
                $0.loading = false
            }
            readReceipts[id] = Dictionary(uniqueKeysWithValues: receipts.map { ($0.userId, $0.lastReadAt) })
        } catch {
            setThread(id) { $0.loading = false; $0.error = error.localizedDescription }
            throw error
        }
        return thread(id)
    }

    /// Loads the page before the oldest loaded message.
    @discardableResult
    public func loadOlderMessages(_ id: ConversationId) async throws -> Thread {
        let current = thread(id)
        guard current.hasMore, !current.loading, let oldest = current.messages.first(where: { !$0.isPending }) else { return current }
        setThread(id) { $0.loading = true }
        do {
            let page = try await api.messages(in: id, before: oldest.id, limit: Self.pageSize)
            setThread(id) {
                $0.messages = Self.merge(page.messages + $0.messages, [])
                $0.hasMore = page.hasMore
                $0.loading = false
            }
        } catch {
            setThread(id) { $0.loading = false; $0.error = error.localizedDescription }
            throw error
        }
        return thread(id)
    }

    /// Merge by id (server) and clientId (optimistic); oldest → newest, pending last.
    static func merge(_ lists: [Message]...) -> [Message] {
        var byKey: [String: Message] = [:]
        var order: [String] = []
        for list in lists {
            for m in list {
                // A server copy of this clientId already landed (echo raced the optimistic insert).
                if m.isPending, let cid = m.clientId, byKey.values.contains(where: { $0.clientId == cid && !$0.isPending }) { continue }
                let key = (m.isPending && m.clientId != nil) ? "client:\(m.clientId!)" : m.id
                if let existing = byKey[key] {
                    var merged = existing
                    merged.body = m.body; merged.editedAt = m.editedAt; merged.deleted = m.deleted
                    merged.imageUrl = m.imageUrl; merged.audioUrl = m.audioUrl; merged.replyTo = m.replyTo
                    merged.status = m.status; merged.error = m.error; merged.clientId = m.clientId ?? existing.clientId
                    byKey[key] = merged
                } else {
                    byKey[key] = m
                    order.append(key)
                }
                if let clientId = m.clientId, !m.isPending, byKey["client:\(clientId)"] != nil {
                    byKey["client:\(clientId)"] = nil
                    order.removeAll { $0 == "client:\(clientId)" }
                }
            }
        }
        return order.compactMap { byKey[$0] }.sorted { a, b in
            if a.isPending != b.isPending { return !a.isPending }
            if a.isPending { return a.createdAt < b.createdAt }
            return (Int(a.id) ?? 0) < (Int(b.id) ?? 0)
        }
    }

    private func upsertMessage(_ id: ConversationId, _ message: Message) {
        let current = thread(id)
        guard current.loaded || !current.messages.isEmpty else { return } // not open — only the row updates
        setThread(id) { $0.messages = Self.merge($0.messages, [message]) }
    }

    @discardableResult
    public func sendMessage(_ id: ConversationId, _ input: SendMessageInput) async throws -> Message {
        var input = input
        let clientId = input.clientId ?? Self.generateClientId()
        input.clientId = clientId
        let replyTarget = input.replyToId.flatMap { rid in thread(id).messages.first { $0.id == rid } }
        let optimistic = Message(
            id: "pending:\(clientId)", conversationId: id, senderId: meId ?? "", body: input.body ?? "", createdAt: Date(),
            imageUrl: input.imageUrl, audioUrl: input.audioUrl, audioDurationSec: input.audioDurationSec,
            fileUrl: input.fileUrl, fileName: input.fileName, fileSizeBytes: input.fileSizeBytes,
            fileThumbnailUrl: input.fileThumbnailUrl, fileDurationSec: input.fileDurationSec,
            replyTo: replyTarget.map { ReplyPreview(id: $0.id, senderId: $0.senderId, body: $0.body, deleted: $0.deleted) },
            clientId: clientId, status: .sending
        )
        setThread(id) { $0.messages = Self.merge($0.messages, [optimistic]) }
        do {
            var message = try await api.sendMessage(in: id, input)
            message.clientId = clientId
            applyOwn(id, message)
            return message
        } catch {
            let description = error.localizedDescription
            setThread(id) {
                $0.messages = $0.messages.map { m in
                    guard m.clientId == clientId else { return m }
                    var failed = m; failed.status = .failed; failed.error = description; return failed
                }
            }
            throw error
        }
    }

    public func sendMessage(_ id: ConversationId, text: String) async throws -> Message {
        try await sendMessage(id, SendMessageInput(body: text))
    }

    /// Re-send a failed optimistic message.
    @discardableResult
    public func retryMessage(_ id: ConversationId, clientId: String) async throws -> Message {
        guard let failed = thread(id).messages.first(where: { $0.clientId == clientId && $0.status == .failed }) else {
            throw RelayError.decoding("No failed message with clientId \(clientId)")
        }
        setThread(id) { $0.messages.removeAll { $0.clientId == clientId } }
        return try await sendMessage(id, SendMessageInput(
            body: failed.body.isEmpty ? nil : failed.body, imageUrl: failed.imageUrl, audioUrl: failed.audioUrl,
            audioDurationSec: failed.audioDurationSec, fileUrl: failed.fileUrl, fileName: failed.fileName,
            fileSizeBytes: failed.fileSizeBytes, fileThumbnailUrl: failed.fileThumbnailUrl, fileDurationSec: failed.fileDurationSec,
            replyToId: failed.replyTo?.id, clientId: clientId))
    }

    public func discardMessage(_ id: ConversationId, clientId: String) {
        setThread(id) { $0.messages.removeAll { $0.clientId == clientId } }
    }

    @discardableResult
    public func editMessage(_ id: ConversationId, messageId: MessageId, body: String) async throws -> Message {
        let message = try await api.editMessage(in: id, messageId: messageId, body: body)
        applyUpdate(id, message)
        return message
    }

    @discardableResult
    public func deleteMessage(_ id: ConversationId, messageId: MessageId) async throws -> Message {
        let message = try await api.deleteMessage(in: id, messageId: messageId)
        applyUpdate(id, message)
        return message
    }

    public func markRead(_ id: ConversationId) async throws {
        if let c = conversation(id), c.unreadCount == 0 { return }
        patch(id) { $0.unreadCount = 0 }
        _ = try await api.markRead(id)
    }

    /// Throttled — safe to call on every keystroke.
    public func sendTyping(_ id: ConversationId) {
        let now = Date()
        if let last = lastTypingSent[id], now.timeIntervalSince(last) < Self.typingThrottle { return }
        lastTypingSent[id] = now
        send(["event": "typing", "conversationId": id])
    }

    /// Which thread is on screen: incoming messages there are marked read automatically and
    /// (Phase 2 push) notifications for it are skipped. Pass nil when leaving.
    public func setViewing(_ id: ConversationId?) {
        viewingConversationId = id
        send(["event": "viewing", "conversationId": id ?? ""])
        if let id { Task { try? await markRead(id) } }
    }

    func reannounceViewing() {
        if let id = viewingConversationId { send(["event": "viewing", "conversationId": id]) }
    }

    private func applyOwn(_ id: ConversationId, _ message: Message) {
        var sent = message; sent.status = .sent
        upsertMessage(id, sent)
        bump(id, message, incrementUnread: false)
    }

    private func applyUpdate(_ id: ConversationId, _ message: Message) {
        setThread(id) { t in
            t.messages = t.messages.map { $0.id == message.id ? message : $0 }
        }
        patch(id) { c in
            if c.lastMessage?.id == message.id { c.lastMessage = Self.preview(of: message) }
        }
    }

    private func bump(_ id: ConversationId, _ message: Message, incrementUnread: Bool) {
        guard conversation(id) != nil else {
            Task { await refreshConversation(id) }
            return
        }
        patch(id) { c in
            c.lastMessage = Self.preview(of: message)
            c.lastMessageAt = message.createdAt
            if incrementUnread { c.unreadCount += 1 }
        }
    }

    private static func preview(of m: Message) -> MessagePreview {
        let kind = m.kind
        let body: String
        switch kind {
        case .deleted: body = ""
        case .image: body = "📷 Photo"
        case .audio: body = "🎤 Voice message"
        case .video: body = "🎬 Video"
        case .file: body = "📎 \(m.fileName ?? "File")"
        case .text: body = m.body
        }
        return MessagePreview(id: m.id, senderId: m.senderId, kind: kind, body: body, createdAt: m.createdAt)
    }

    private func clearThread(_ id: ConversationId) {
        setThread(id) { $0.messages = []; $0.hasMore = false; $0.loaded = true }
        patch(id) { $0.lastMessage = nil; $0.unreadCount = 0 }
    }

    static func generateClientId() -> String {
        "c_\(Int(Date().timeIntervalSince1970 * 1000))_\(UUID().uuidString.prefix(8))"
    }

    // MARK: - Realtime

    func apply(_ event: RelayEvent) {
        switch event {
        case .connected(let userId, _):
            meId = userId
        case .chatMessage(let conversationId, var message, let clientId):
            message.clientId = clientId
            if message.senderId == meId {
                applyOwn(conversationId, message)
            } else {
                upsertMessage(conversationId, message)
                let viewing = viewingConversationId == conversationId
                bump(conversationId, message, incrementUnread: !viewing)
                clearTyping(conversationId, message.senderId)
                if viewing { Task { _ = try? await api.markRead(conversationId) } }
            }
        case .chatMessageUpdated(let conversationId, let message):
            applyUpdate(conversationId, message)
        case .chatRead(let conversationId, let userId, let lastReadAt):
            if userId == meId {
                patch(conversationId) { $0.unreadCount = 0 } // read on another of my devices
            } else {
                var current = readReceipts[conversationId] ?? [:]
                current[userId] = lastReadAt
                readReceipts[conversationId] = current
            }
        case .typing(let conversationId, let userId):
            guard userId != meId else { return }
            var list = typing[conversationId] ?? []
            if !list.contains(userId) { list.append(userId); typing[conversationId] = list }
            let key = "\(conversationId):\(userId)"
            typingTimers[key]?.cancel()
            typingTimers[key] = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.typingTTL * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.clearTyping(conversationId, userId)
            }
        case .presence(let userId, let online, let lastSeenAt):
            presence[userId] = PresenceInfo(online: online, lastSeenAt: lastSeenAt)
            conversations = conversations.map { c in
                var c = c
                if c.peer?.userId == userId { c.peer?.isOnline = online; c.peer?.lastSeenAt = lastSeenAt }
                if let i = c.members.firstIndex(where: { $0.userId == userId }) { c.members[i].isOnline = online }
                return c
            }
        case .conversationCreated(let conversationId):
            Task { await refreshConversation(conversationId) }
        case .conversationUpdated(let conversationId, let name, let photoUrl):
            patch(conversationId) { $0.name = name; $0.photoUrl = photoUrl }
        case .conversationDeleted(let conversationId):
            remove(conversationId)
        case .conversationCleared(let conversationId):
            clearThread(conversationId)
        case .membersAdded(let conversationId, _), .memberRemoved(let conversationId, _), .memberLeft(let conversationId, _):
            Task { await refreshConversation(conversationId) }
        case .pong, .unknown:
            break
        }
    }

    private func clearTyping(_ id: ConversationId, _ userId: UserId) {
        let key = "\(id):\(userId)"
        typingTimers[key]?.cancel()
        typingTimers[key] = nil
        guard var list = typing[id], list.contains(userId) else { return }
        list.removeAll { $0 == userId }
        typing[id] = list
    }

    /// Reload everything the server may have changed while we were disconnected.
    func resync() async {
        if conversationsLoaded { _ = try? await loadConversations() }
        for thread in threads.values where thread.loaded {
            let id = thread.conversationId
            guard let page = try? await api.messages(in: id, limit: Self.pageSize) else { continue }
            let receipts = (try? await api.readReceipts(id)) ?? []
            setThread(id) { t in
                let overlaps = page.messages.contains { m in t.messages.contains { $0.id == m.id } }
                t.messages = Self.merge(t.messages, page.messages)
                t.hasMore = overlaps ? t.hasMore : page.hasMore
            }
            readReceipts[id] = Dictionary(uniqueKeysWithValues: receipts.map { ($0.userId, $0.lastReadAt) })
        }
    }

    /// Drop all local state (e.g. on sign-out).
    func reset() {
        typingTimers.values.forEach { $0.cancel() }
        typingTimers = [:]
        lastTypingSent = [:]
        viewingConversationId = nil
        meId = nil
        me = nil
        conversations = []
        conversationsLoaded = false
        conversationsLoading = false
        threads = [:]
        typing = [:]
        readReceipts = [:]
        presence = [:]
    }
}
