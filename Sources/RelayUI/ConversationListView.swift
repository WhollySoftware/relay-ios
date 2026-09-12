import SwiftUI

/// The conversation list. Loads on appear, pull-to-refresh, live updates via the store.
/// Selecting a row calls `onSelect` (or pushes `MessageThreadView` when used inside `RelayChatView`).
public struct ConversationListView: View {
    @Environment(RelayClient.self) private var client
    @Environment(\.relayTheme) private var theme
    var includeEmpty = true
    var onSelect: ((Conversation) -> Void)?
    @State private var error: String?

    public init(includeEmpty: Bool = true, onSelect: ((Conversation) -> Void)? = nil) {
        self.includeEmpty = includeEmpty
        self.onSelect = onSelect
    }

    public var body: some View {
        let chat = client.chat
        List {
            if let error {
                Text(error).foregroundStyle(theme.danger).font(.footnote)
            }
            if chat.conversationsLoaded && chat.conversations.isEmpty {
                Text("No conversations yet").foregroundStyle(theme.secondaryText).frame(maxWidth: .infinity).listRowSeparator(.hidden)
            }
            ForEach(chat.conversations) { conversation in
                if let onSelect {
                    Button { onSelect(conversation) } label: { ConversationRow(conversation: conversation) }
                        .buttonStyle(.plain)
                } else {
                    NavigationLink(value: conversation.id) { ConversationRow(conversation: conversation) }
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if !chat.conversationsLoaded && chat.conversationsLoading { ProgressView() }
        }
        .task { await load() }
        .refreshable { await load() }
        .relayTypography(theme)
    }

    private func load() async {
        do { try await client.chat.loadConversations(includeEmpty: includeEmpty); error = nil }
        catch { self.error = error.localizedDescription }
    }
}

public struct ConversationRow: View {
    @Environment(RelayClient.self) private var client
    @Environment(\.relayTheme) private var theme
    let conversation: Conversation

    public init(conversation: Conversation) { self.conversation = conversation }

    public var body: some View {
        let typing = client.chat.typing[conversation.id] ?? []
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                AvatarView(name: conversation.title, url: conversation.isGroup ? conversation.photoUrl : conversation.peer?.avatarUrl,
                           colorKey: conversation.isGroup ? "g:\(conversation.id)" : conversation.peer?.userId, size: theme.avatarSize)
                if !conversation.isGroup { PresenceDot(online: conversation.peer?.isOnline) }
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(conversation.title).font(.body.weight(conversation.unreadCount > 0 ? .bold : .semibold)).lineLimit(1)
                    Spacer()
                    if let at = conversation.lastMessageAt {
                        Text(RelayFormat.relative(at)).font(.caption).foregroundStyle(theme.secondaryText)
                    }
                }
                HStack {
                    Text(preview(typing: typing))
                        .font(.subheadline)
                        .foregroundStyle(typing.isEmpty ? (conversation.unreadCount > 0 ? .primary : theme.secondaryText) : theme.accent)
                        .italic(!typing.isEmpty)
                        .lineLimit(1)
                    Spacer()
                    if conversation.unreadCount > 0 {
                        Text(conversation.unreadCount > 99 ? "99+" : "\(conversation.unreadCount)")
                            .font(.caption2.bold()).foregroundStyle(.white)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Capsule().fill(theme.accent))
                            .accessibilityLabel("\(conversation.unreadCount) unread")
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func preview(typing: [UserId]) -> String {
        if !typing.isEmpty { return "typing…" }
        guard let last = conversation.lastMessage else { return "" }
        let me = client.userId
        let prefix: String
        if last.senderId == me { prefix = "You: " }
        else if conversation.isGroup { prefix = RelayFormat.displayName(for: last.senderId, in: conversation, me: client.me) + ": " }
        else { prefix = "" }
        return prefix + (last.kind == .deleted ? "Message deleted" : last.body)
    }
}
