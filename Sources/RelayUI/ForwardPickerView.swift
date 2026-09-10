import SwiftUI

/// Simple conversation picker for "Forward" — every other conversation the user is already in.
/// No new-conversation flow here; forwarding to someone you haven't messaged yet is just opening
/// that chat and pasting, same as most chat apps' plain forward-to-existing-chat picker.
struct ForwardPickerView: View {
    @Environment(\.dismiss) private var dismiss
    let conversations: [Conversation]
    let onPick: (ConversationId) -> Void

    var body: some View {
        NavigationStack {
            List(conversations) { conversation in
                Button {
                    onPick(conversation.id)
                } label: {
                    HStack(spacing: 12) {
                        AvatarView(name: conversation.title, url: conversation.isGroup ? conversation.photoUrl : conversation.peer?.avatarUrl, size: 36)
                        Text(conversation.title).foregroundStyle(.primary)
                    }
                }
            }
            .overlay {
                if conversations.isEmpty {
                    ContentUnavailableViewCompat(title: "No other conversations yet.")
                }
            }
            .navigationTitle("Forward to…")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}

private struct ContentUnavailableViewCompat: View {
    let title: String
    var body: some View {
        Text(title).foregroundStyle(.secondary).padding()
    }
}
