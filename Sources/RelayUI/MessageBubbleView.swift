import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Sent / seen receipt for the last own message.
public enum MessageReceiptStatus: Equatable {
    case sent
    /// `by` is the reader count in a group thread, nil for a 1:1 chat.
    case seen(by: Int?)
}

/// One message bubble — text, image, audio (as a link), deleted placeholder, quoted reply,
/// edited mark, optimistic states, and a context menu for reply/edit/delete.
public struct MessageBubbleView: View {
    @Environment(\.relayTheme) private var theme
    let message: Message
    let isOwn: Bool
    var senderName: String?
    var continued = false
    var status: MessageReceiptStatus?
    var onReply: ((Message) -> Void)?
    var onEdit: ((Message) -> Void)?
    var onDelete: ((Message) -> Void)?
    var onRetry: ((Message) -> Void)?
    var onDiscard: ((Message) -> Void)?
    var onForward: ((Message) -> Void)?
    var onShowInfo: ((Message) -> Void)?

    public init(message: Message, isOwn: Bool, senderName: String? = nil, continued: Bool = false, status: MessageReceiptStatus? = nil,
                onReply: ((Message) -> Void)? = nil, onEdit: ((Message) -> Void)? = nil, onDelete: ((Message) -> Void)? = nil,
                onRetry: ((Message) -> Void)? = nil, onDiscard: ((Message) -> Void)? = nil, onForward: ((Message) -> Void)? = nil,
                onShowInfo: ((Message) -> Void)? = nil) {
        self.message = message; self.isOwn = isOwn; self.senderName = senderName; self.continued = continued; self.status = status
        self.onReply = onReply; self.onEdit = onEdit; self.onDelete = onDelete; self.onRetry = onRetry; self.onDiscard = onDiscard
        self.onForward = onForward; self.onShowInfo = onShowInfo
    }

    // Call summary lines are posted by the service as plain text ("📞 Video call · 0:30",
    // "📵 Video call cancelled", "📵 Missed call", "📵 Declined call") — a leading 📞 is a completed
    // call, 📵 is missed/declined/cancelled. Recognized here purely by that prefix so no protocol
    // change was needed to give them their own pill instead of a normal chat bubble.
    private var callInfo: (label: String, missed: Bool)? {
        if message.body.hasPrefix("📞 ") { return (String(message.body.dropFirst(2)), false) }
        if message.body.hasPrefix("📵 ") { return (String(message.body.dropFirst(2)), true) }
        return nil
    }

    /// What "Share" hands to the system share sheet — the message text, or the attachment's URL
    /// when there's no text (an image/file/audio message).
    private var shareText: String {
        if !message.body.isEmpty { return message.body }
        return message.imageUrl ?? message.fileUrl ?? message.audioUrl ?? ""
    }

    public var body: some View {
        if let callInfo {
            HStack {
                if isOwn { Spacer(minLength: 48) }
                callPill(label: callInfo.label, missed: callInfo.missed)
                if !isOwn { Spacer(minLength: 48) }
            }
            .padding(.top, continued ? 0 : 6)
        } else {
            normalBubble
        }
    }

    private var normalBubble: some View {
        HStack {
            if isOwn { Spacer(minLength: 48) }
            VStack(alignment: isOwn ? .trailing : .leading, spacing: 2) {
                if let senderName, !isOwn, !continued {
                    Text(senderName).font(.caption).foregroundStyle(theme.secondaryText).padding(.leading, 6)
                }
                bubble
                    .contextMenu {
                        if !message.deleted && !message.isPending {
                            if !message.body.isEmpty {
                                Button {
                                    #if os(iOS)
                                    UIPasteboard.general.string = message.body
                                    #else
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(message.body, forType: .string)
                                    #endif
                                } label: { Label("Copy", systemImage: "doc.on.doc") }
                            }
                            if let onReply { Button { onReply(message) } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") } }
                            if let onForward { Button { onForward(message) } label: { Label("Forward", systemImage: "arrowshape.turn.up.right") } }
                            if !shareText.isEmpty, let url = URL(string: shareText) {
                                ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
                            } else if !shareText.isEmpty {
                                ShareLink(item: shareText) { Label("Share", systemImage: "square.and.arrow.up") }
                            }
                            if isOwn, let onEdit, message.imageUrl == nil, message.audioUrl == nil, message.fileUrl == nil { Button { onEdit(message) } label: { Label("Edit", systemImage: "pencil") } }
                            if isOwn, let onShowInfo { Button { onShowInfo(message) } label: { Label("Message info", systemImage: "info.circle") } }
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
                if let status { receiptView(status) }
            }
            if !isOwn { Spacer(minLength: 48) }
        }
        .padding(.top, continued ? 0 : 6)
        .opacity(message.status == .sending ? 0.7 : 1)
    }

    // WhatsApp-style receipt: single check = sent, double check = seen (green) — this SDK has no
    // distinct "delivered" signal (only sent vs. read-receipt "seen"), so there's no gray
    // double-check tier here.
    private func receiptView(_ status: MessageReceiptStatus) -> some View {
        HStack(spacing: 4) {
            switch status {
            case .sent:
                Image(systemName: "checkmark").font(.caption2).foregroundStyle(theme.secondaryText)
            case .seen(let by):
                HStack(spacing: -5) {
                    Image(systemName: "checkmark")
                    Image(systemName: "checkmark")
                }
                .font(.caption2.bold())
                .foregroundStyle(Color(red: 0.30, green: 0.69, blue: 0.31))
                if let by { Text("by \(by)").font(.caption2).foregroundStyle(theme.secondaryText) }
            }
        }
        .padding(.trailing, 4)
    }

    private func callPill(label: String, missed: Bool) -> some View {
        let tint = missed ? Color(red: 0.898, green: 0.224, blue: 0.208) : Color(red: 0.30, green: 0.69, blue: 0.31)
        let isVideo = label.localizedCaseInsensitiveContains("video")
        return HStack(spacing: 10) {
            ZStack {
                Circle().fill(tint)
                Image(systemName: isVideo ? "video.fill" : "phone.fill").font(.caption).foregroundStyle(.white)
            }
            .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.subheadline.weight(.semibold))
                Text(RelayFormat.time(message.createdAt)).font(.caption2).foregroundStyle(theme.secondaryText)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: 300, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(tint.opacity(0.5), lineWidth: 1))
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
                if let file = message.fileUrl, let url = URL(string: file) {
                    let isVideo = (message.fileMime ?? "").hasPrefix("video/")
                    let isPdf = (message.fileMime ?? "") == "application/pdf" && message.fileThumbnailUrl != nil
                    Link(destination: url) {
                        if isVideo {
                            ZStack {
                                if let thumb = message.fileThumbnailUrl, let thumbUrl = URL(string: thumb) {
                                    AsyncImage(url: thumbUrl) { phase in
                                        if let img = phase.image { img.resizable().scaledToFill() } else { Color.black.opacity(0.3) }
                                    }
                                } else {
                                    Color.black.opacity(0.3)
                                }
                                Image(systemName: "play.circle.fill").font(.system(size: 32)).foregroundStyle(.white)
                                if let sec = message.fileDurationSec {
                                    VStack {
                                        Spacer()
                                        HStack {
                                            Spacer()
                                            Text("\(sec / 60):\(String(format: "%02d", sec % 60))").font(.caption2.bold()).foregroundStyle(.white)
                                                .padding(.horizontal, 6).padding(.vertical, 2)
                                                .background(Capsule().fill(.black.opacity(0.55)))
                                        }
                                    }.padding(6)
                                }
                            }
                            .frame(width: 220, height: 140).clipShape(RoundedRectangle(cornerRadius: 10))
                        } else if isPdf {
                            ZStack {
                                if let thumb = message.fileThumbnailUrl, let thumbUrl = URL(string: thumb) {
                                    AsyncImage(url: thumbUrl) { phase in
                                        if let img = phase.image { img.resizable().scaledToFill() } else { Color.black.opacity(0.3) }
                                    }
                                } else {
                                    Color.black.opacity(0.3)
                                }
                                Image(systemName: "doc.richtext.fill").font(.system(size: 32)).foregroundStyle(.white)
                                VStack {
                                    Spacer()
                                    HStack {
                                        Text(message.fileName ?? "PDF").font(.caption2.bold()).foregroundStyle(.white).lineLimit(1)
                                            .padding(.horizontal, 6).padding(.vertical, 2)
                                            .background(Capsule().fill(.black.opacity(0.55)))
                                        Spacer()
                                    }
                                }.padding(6)
                            }
                            .frame(width: 220, height: 140).clipShape(RoundedRectangle(cornerRadius: 10))
                        } else {
                            HStack(spacing: 8) {
                                Image(systemName: "paperclip")
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(message.fileName ?? "File").font(.caption).lineLimit(1)
                                    if let bytes = message.fileSizeBytes { Text(RelayFormat.fileSize(bytes)).font(.caption2).opacity(0.7) }
                                }
                            }
                        }
                    }
                }
                if !message.body.isEmpty { Text(message.body) }
                if !message.isPending, let previewUrl = RelayFormat.firstUrl(in: message.body) {
                    LinkPreviewCard(url: previewUrl, isOwn: isOwn)
                }
            }
            HStack(spacing: 4) {
                if message.editedAt != nil && !message.deleted { Text("edited").font(.caption2) }
                Text(RelayFormat.time(message.createdAt)).font(.caption2)
                if message.status == .sending { Image(systemName: "clock").font(.caption2) }
            }
            .opacity(0.7)
            // No .frame(maxWidth: .infinity) here — that used to force this row (and therefore
            // the whole bubble, since a VStack sizes to its widest child) to the full 300pt cap
            // even for a two-word message. Left un-stretched, the bubble now hugs its content.
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
