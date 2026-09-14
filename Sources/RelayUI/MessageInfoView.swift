import SwiftUI

/// WhatsApp-style "Message info": long-press a message YOU sent → who has read it (with when) vs.
/// who it's only been delivered to (with when). Unlike the conversation-wide "last read" watermark
/// (`ChatStore.readReceipts`), this is per-message-accurate for any message, not just the newest —
/// backed by `RelayAPI.getMessageReceipts`. Mirrors the web client's message-info panel.
struct MessageInfoView: View {
    @Environment(RelayClient.self) private var client
    @Environment(\.relayTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    let conversationId: ConversationId
    let message: Message

    @State private var receipts: RelayAPI.MessageReceiptsResponse?
    @State private var errorText: String?

    var body: some View {
        let conversation = client.chat.conversation(conversationId)
        NavigationStack {
            List {
                Section {
                    preview
                }

                if let errorText {
                    Section { Text(errorText).font(.footnote).foregroundStyle(theme.danger) }
                }

                if let receipts {
                    Section("Read by") {
                        if receipts.readBy.isEmpty {
                            Text("No one yet").foregroundStyle(theme.secondaryText)
                        } else {
                            ForEach(receipts.readBy, id: \.userId) { entry in
                                row(userId: entry.userId, conversation: conversation, timestamp: entry.readAt)
                            }
                        }
                    }
                    Section("Delivered to") {
                        if receipts.deliveredTo.isEmpty {
                            Text("No one yet").foregroundStyle(theme.secondaryText)
                        } else {
                            ForEach(receipts.deliveredTo, id: \.userId) { entry in
                                row(userId: entry.userId, conversation: conversation, timestamp: entry.deliveredAt)
                            }
                        }
                    }
                } else if errorText == nil {
                    Section {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                    }
                }
            }
            .navigationTitle("Message info")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .task { await load() }
        }
    }

    // MARK: - Preview

    @ViewBuilder
    private var preview: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let url = RelayFormat.safeAttachmentURL(message.imageUrl) {
                AsyncImage(url: url) { phase in
                    if let img = phase.image { img.resizable().scaledToFit() } else { ProgressView() }
                }
                .frame(maxHeight: 160)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            } else if let url = RelayFormat.safeAttachmentURL(message.fileThumbnailUrl) {
                AsyncImage(url: url) { phase in
                    if let img = phase.image { img.resizable().scaledToFit() } else { ProgressView() }
                }
                .frame(maxHeight: 160)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            if !message.body.isEmpty {
                Text(message.body)
            } else if message.imageUrl == nil {
                Text(message.fileName ?? message.audioUrl.map { _ in "Voice message" } ?? "Attachment")
                    .foregroundStyle(theme.secondaryText)
            }
            Text(RelayFormat.dateTime(message.createdAt)).font(.caption).foregroundStyle(theme.secondaryText)
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func row(userId: UserId, conversation: Conversation?, timestamp: String?) -> some View {
        let name = RelayFormat.displayName(for: userId, in: conversation, me: client.me)
        let avatarUrl = conversation?.peer?.userId == userId
            ? conversation?.peer?.avatarUrl
            : conversation?.members.first { $0.userId == userId }?.avatarUrl
        HStack(spacing: 12) {
            AvatarView(name: name, url: avatarUrl, colorKey: userId, size: 36)
            Text(name)
            Spacer()
            if let timestamp, let date = Self.parseISODate(timestamp) {
                Text(RelayFormat.dateTime(date)).font(.footnote).foregroundStyle(theme.secondaryText)
            }
        }
    }

    // MARK: - Loading

    private func load() async {
        do {
            receipts = try await client.chat.getMessageReceipts(conversationId, messageId: message.id)
        } catch {
            errorText = "Could not load message info."
        }
    }

    // The service emits RFC 3339 timestamps with fractional seconds ("2026-09-06T00:12:34.567Z"),
    // same shape as `RelayJSON` decodes elsewhere in the SDK — duplicated here in miniature since
    // that helper is internal to RelayCore.
    private static let isoWithFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
    private static func parseISODate(_ raw: String) -> Date? {
        isoWithFraction.date(from: raw) ?? isoPlain.date(from: raw)
    }
}
