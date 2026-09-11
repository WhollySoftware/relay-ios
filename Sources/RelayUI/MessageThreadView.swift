import SwiftUI

/// One conversation: scrolling messages (newest at the bottom), day separators, "load earlier",
/// typing indicator and the composer. Announces itself as "viewing" so incoming messages are
/// read automatically while it is on screen.
public struct MessageThreadView: View {
    @Environment(RelayClient.self) private var client
    @Environment(\.relayTheme) private var theme
    let conversationId: ConversationId
    @State private var replyTo: Message?
    @State private var editing: Message?
    @State private var forwarding: Message?
    @State private var showingGroupDetail = false

    /// Invoked when the group admin taps "Add people" in the group info screen; return the user
    /// ids to invite (or nil/empty to cancel). Omit to hide "Add people" — the host owns the
    /// picker UI since it needs access to e.g. a contacts list this package doesn't have.
    var onPickGroupMembers: (() async -> [UserId]?)?

    public init(conversationId: ConversationId, onPickGroupMembers: (() async -> [UserId]?)? = nil) {
        self.conversationId = conversationId
        self.onPickGroupMembers = onPickGroupMembers
    }

    public var body: some View {
        let chat = client.chat
        let thread = chat.thread(conversationId)
        let conversation = chat.conversation(conversationId)
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        if thread.hasMore {
                            Button(thread.loading ? "Loading…" : "Load earlier messages") {
                                Task { try? await chat.loadOlderMessages(conversationId) }
                            }
                            .font(.footnote).disabled(thread.loading).padding(.vertical, 6)
                        }
                        if let error = thread.error {
                            Text(error).font(.footnote).foregroundStyle(theme.danger)
                        }
                        if thread.loaded && thread.messages.isEmpty {
                            Text("Say hello 👋").foregroundStyle(theme.secondaryText).padding(.top, 40)
                        }
                        ForEach(Array(thread.messages.enumerated()), id: \.element.id) { index, message in
                            let previous = index > 0 ? thread.messages[index - 1] : nil
                            if previous == nil || !Calendar.current.isDate(previous!.createdAt, inSameDayAs: message.createdAt) {
                                DaySeparator(date: message.createdAt)
                            }
                            MessageBubbleView(
                                message: message,
                                isOwn: message.senderId == client.userId,
                                senderName: conversation?.isGroup == true ? RelayFormat.displayName(for: message.senderId, in: conversation, me: client.me) : nil,
                                continued: previous.map { $0.senderId == message.senderId && message.createdAt.timeIntervalSince($0.createdAt) < 300 } ?? false,
                                status: status(for: message, at: index, in: thread, conversation: conversation),
                                onReply: { replyTo = $0 },
                                onEdit: { editing = $0 },
                                onDelete: { m in Task { try? await chat.deleteMessage(conversationId, messageId: m.id) } },
                                onRetry: { m in if let cid = m.clientId { Task { try? await chat.retryMessage(conversationId, clientId: cid) } } },
                                onDiscard: { m in if let cid = m.clientId { chat.discardMessage(conversationId, clientId: cid) } },
                                onForward: { forwarding = $0 }
                            )
                            .id(message.id)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                }
                .onChange(of: thread.messages.last?.id) { _, _ in
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onChange(of: thread.loaded) { _, loaded in
                    if loaded { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                #if os(iOS)
                .scrollDismissesKeyboard(.interactively)
                #endif
            }
            TypingIndicatorView(names: (chat.typing[conversationId] ?? []).map { RelayFormat.displayName(for: $0, in: conversation, me: client.me) })
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .frame(height: 22)
            MessageComposerView(conversationId: conversationId, replyTo: $replyTo, editing: $editing)
        }
        .navigationTitle(conversation?.title ?? "")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 8) {
                    if let conversation {
                        ZStack(alignment: .bottomTrailing) {
                            AvatarView(name: conversation.title, url: conversation.isGroup ? conversation.photoUrl : conversation.peer?.avatarUrl,
                                       colorKey: conversation.isGroup ? "g:\(conversation.id)" : conversation.peer?.userId, size: 36)
                            if !conversation.isGroup { PresenceDot(online: conversation.peer?.isOnline) }
                        }
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        if conversation?.isGroup == true {
                            Button {
                                showingGroupDetail = true
                            } label: {
                                Text(conversation?.title ?? "").font(.headline).lineLimit(1)
                            }
                            .buttonStyle(.plain)
                        } else {
                            Text(conversation?.title ?? "").font(.headline).lineLimit(1)
                        }
                        Text(subtitle(conversation)).font(.caption2).foregroundStyle(theme.secondaryText)
                    }
                }
            }
        }
        .task(id: conversationId) {
            chat.setViewing(conversationId)
            try? await chat.loadMessages(conversationId)
        }
        .onDisappear {
            if chat.viewingConversationId == conversationId { chat.setViewing(nil) }
        }
        .sheet(isPresented: $showingGroupDetail) {
            GroupDetailView(conversationId: conversationId, onPickAdd: onPickGroupMembers)
        }
        .sheet(item: $forwarding) { message in
            ForwardPickerView(conversations: chat.conversations.filter { $0.id != conversationId }) { targetId in
                forwarding = nil
                Task {
                    try? await chat.sendMessage(targetId, SendMessageInput(
                        body: message.body.isEmpty ? nil : message.body, imageUrl: message.imageUrl, audioUrl: message.audioUrl,
                        audioDurationSec: message.audioDurationSec, fileUrl: message.fileUrl, fileName: message.fileName,
                        fileThumbnailUrl: message.fileThumbnailUrl, fileDurationSec: message.fileDurationSec
                    ))
                }
            }
        }
    }

    private func subtitle(_ c: Conversation?) -> String {
        guard let c else { return "" }
        if c.isGroup { return "\(c.memberCount) members" }
        return RelayFormat.lastSeen(online: c.peer?.isOnline, lastSeenAt: c.peer?.lastSeenAt)
    }

    /// Sent / seen receipt for the last own message — rendered as checkmark ticks, not text.
    private func status(for m: Message, at index: Int, in thread: ChatStore.Thread, conversation: Conversation?) -> MessageReceiptStatus? {
        guard m.senderId == client.userId, m.status != .sending, m.status != .failed else { return nil }
        let isLastOwn = !thread.messages[(index + 1)...].contains { $0.senderId == client.userId }
        guard isLastOwn else { return nil }
        let receipts = client.chat.readReceipts[conversationId] ?? [:]
        let readers = receipts.filter { key, value in key != client.userId && (value ?? .distantPast) >= m.createdAt }.count
        if readers == 0 { return .sent }
        return .seen(by: conversation?.isGroup == true ? readers : nil)
    }
}

struct DaySeparator: View {
    @Environment(\.relayTheme) private var theme
    let date: Date
    var body: some View {
        Text(RelayFormat.day(date))
            .font(.caption2).foregroundStyle(theme.secondaryText)
            .padding(.horizontal, 10).padding(.vertical, 3)
            .background(Capsule().fill(Color.gray.opacity(0.15)))
            .padding(.vertical, 8)
    }
}
