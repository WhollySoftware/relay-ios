import SwiftUI

/// Text box + send button. Return sends; the store throttles typing indicators. Doubles as the
/// inline editor when `editing` is set.
public struct MessageComposerView: View {
    @Environment(RelayClient.self) private var client
    @Environment(\.relayTheme) private var theme
    let conversationId: ConversationId
    @Binding var replyTo: Message?
    @Binding var editing: Message?
    @State private var text = ""
    @State private var busy = false
    @State private var error: String?
    @FocusState private var focused: Bool

    public init(conversationId: ConversationId, replyTo: Binding<Message?> = .constant(nil), editing: Binding<Message?> = .constant(nil)) {
        self.conversationId = conversationId
        self._replyTo = replyTo
        self._editing = editing
    }

    public var body: some View {
        VStack(spacing: 6) {
            if let editing {
                banner(title: "Editing", body: editing.body) { self.editing = nil; text = "" }
            } else if let replyTo {
                banner(title: "Replying to \(RelayFormat.displayName(for: replyTo.senderId, in: client.chat.conversation(conversationId), me: client.me))",
                       body: replyTo.deleted ? "Message deleted" : (replyTo.body.isEmpty ? "Attachment" : replyTo.body)) { self.replyTo = nil }
            }
            if let error { Text(error).font(.caption).foregroundStyle(theme.danger) }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message…", text: $text, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 18).fill(Color.gray.opacity(0.14)))
                    .focused($focused)
                    .onChange(of: text) { _, value in
                        if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, editing == nil { client.chat.sendTyping(conversationId) }
                    }
                    .onSubmit { Task { await send() } }
                Button { Task { await send() } } label: {
                    Image(systemName: editing == nil ? "arrow.up.circle.fill" : "checkmark.circle.fill").font(.system(size: 30))
                }
                .buttonStyle(.plain)
                .foregroundStyle(canSend ? theme.accent : theme.secondaryText)
                .disabled(!canSend || busy)
                .accessibilityLabel(editing == nil ? "Send" : "Save")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .onChange(of: editing?.id) { _, _ in
            if let editing { text = editing.body; focused = true }
        }
    }

    private var canSend: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func banner(title: String, body: String, cancel: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption.bold()).foregroundStyle(theme.accent)
                Text(body).font(.caption).lineLimit(1).foregroundStyle(theme.secondaryText)
            }
            Spacer()
            Button { cancel() } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(theme.secondaryText)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.12)))
    }

    private func send() async {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, !busy else { return }
        busy = true
        defer { busy = false }
        error = nil
        let draft = text
        text = ""
        do {
            if let editing {
                _ = try await client.chat.editMessage(conversationId, messageId: editing.id, body: body)
                self.editing = nil
            } else {
                _ = try await client.chat.sendMessage(conversationId, SendMessageInput(body: body, replyToId: replyTo?.id))
                replyTo = nil
            }
        } catch {
            // The optimistic bubble already shows Retry/Discard; keep the box empty to avoid a
            // double send, but say why.
            self.error = error.localizedDescription
            if editing != nil { text = draft }
        }
    }
}
