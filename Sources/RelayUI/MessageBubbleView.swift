import SwiftUI

/// One message bubble — text, image, audio (as a link), deleted placeholder, quoted reply,
/// edited mark, optimistic states, and a context menu for reply/edit/delete.
public struct MessageBubbleView: View {
    @Environment(\.relayTheme) private var theme
    let message: Message
    let isOwn: Bool
    var senderName: String?
    var continued = false
    var status: String?
    var onReply: ((Message) -> Void)?
    var onEdit: ((Message) -> Void)?
    var onDelete: ((Message) -> Void)?
    var onRetry: ((Message) -> Void)?
    var onDiscard: ((Message) -> Void)?

    public init(message: Message, isOwn: Bool, senderName: String? = nil, continued: Bool = false, status: String? = nil,
                onReply: ((Message) -> Void)? = nil, onEdit: ((Message) -> Void)? = nil, onDelete: ((Message) -> Void)? = nil,
                onRetry: ((Message) -> Void)? = nil, onDiscard: ((Message) -> Void)? = nil) {
        self.message = message; self.isOwn = isOwn; self.senderName = senderName; self.continued = continued; self.status = status
        self.onReply = onReply; self.onEdit = onEdit; self.onDelete = onDelete; self.onRetry = onRetry; self.onDiscard = onDiscard
    }

    public var body: some View {
        HStack {
            if isOwn { Spacer(minLength: 48) }
            VStack(alignment: isOwn ? .trailing : .leading, spacing: 2) {
                if let senderName, !isOwn, !continued {
                    Text(senderName).font(.caption).foregroundStyle(theme.secondaryText).padding(.leading, 6)
                }
                bubble
                    .contextMenu {
                        if !message.deleted && !message.isPending {
                            if let onReply { Button { onReply(message) } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") } }
                            if isOwn, let onEdit, message.imageUrl == nil, message.audioUrl == nil { Button { onEdit(message) } label: { Label("Edit", systemImage: "pencil") } }
                            if isOwn, let onDelete { Button(role: .destructive) { onDelete(message) } label: { Label("Delete", systemImage: "trash") } }
                        }
                    }
                if message.status == .failed {
                    HStack(spacing: 8) {
                        Text("Not sent").font(.caption).foregroundStyle(theme.danger)
                        if let onRetry { Button("Retry") { onRetry(message) }.font(.caption) }
                        if let onDiscard { Button("Discard") { onDiscard(message) }.font(.caption) }
                    }
                }
                if let status { Text(status).font(.caption2).foregroundStyle(theme.secondaryText).padding(.trailing, 4) }
            }
            if !isOwn { Spacer(minLength: 48) }
        }
        .padding(.top, continued ? 0 : 6)
        .opacity(message.status == .sending ? 0.7 : 1)
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let reply = message.replyTo {
                VStack(alignment: .leading, spacing: 1) {
                    Text(reply.senderId).font(.caption2.bold())
                    Text(reply.deleted ? "Message deleted" : (reply.body.isEmpty ? "Attachment" : reply.body)).font(.caption2).lineLimit(2)
                }
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(isOwn ? 0.2 : 0.5)))
            }
            if message.deleted {
                Text("This message was deleted").italic().opacity(0.7)
            } else {
                if let image = message.imageUrl, let url = URL(string: image) {
                    AsyncImage(url: url) { phase in
                        if let img = phase.image { img.resizable().scaledToFit() } else { ProgressView() }
                    }
                    .frame(maxWidth: 240, maxHeight: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                if let audio = message.audioUrl, let url = URL(string: audio) {
                    Link(destination: url) {
                        Label(message.audioDurationSec.map { "Voice message · \($0 / 60):\(String(format: "%02d", $0 % 60))" } ?? "Voice message", systemImage: "waveform")
                    }
                }
                if !message.body.isEmpty { Text(message.body) }
            }
            HStack(spacing: 4) {
                if message.editedAt != nil && !message.deleted { Text("edited").font(.caption2) }
                Text(RelayFormat.time(message.createdAt)).font(.caption2)
                if message.status == .sending { Image(systemName: "clock").font(.caption2) }
            }
            .opacity(0.7)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .foregroundStyle(isOwn ? theme.bubbleMineText : theme.bubbleTheirsText)
        .background(RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous).fill(isOwn ? theme.bubbleMine : theme.bubbleTheirs))
        .overlay {
            if message.status == .failed { RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous).stroke(theme.danger, lineWidth: 1) }
        }
        .frame(maxWidth: 300, alignment: isOwn ? .trailing : .leading)
    }
}
