import SwiftUI
import RelayCore
import RelayUI
import RelayCall

/// The signed-in app: a tab bar with Chats (our own composition of `ConversationListView` +
/// `MessageThreadView`, so we can add a call button to the thread's toolbar — `RelayChatView`
/// itself is a fine drop-in, but it doesn't expose that hook, and the SDK is not ours to modify)
/// and an About tab that doubles as the "how this works" reference.
struct ChatRootView: View {
    let session: AppSession
    @State private var path: [ConversationId] = []
    @State private var showNewChat = false
    @State private var newChatUserId = ""
    @State private var newChatError: String?

    var body: some View {
        TabView {
            NavigationStack(path: $path) {
                ConversationListView()
                    .navigationDestination(for: ConversationId.self) { id in
                        ThreadWithCallingView(conversationId: id, calls: session.calls)
                    }
                    .navigationTitle("Chats")
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) {
                            Button { showNewChat = true } label: { Image(systemName: "square.and.pencil") }
                        }
                    }
                    .alert("New chat", isPresented: $showNewChat) {
                        TextField("User id (e.g. bob)", text: $newChatUserId)
                        Button("Open") { Task { await openNewChat() } }
                        Button("Cancel", role: .cancel) { newChatUserId = "" }
                    }
            }
            .environment(session.relay)
            .tabItem { Label("Chats", systemImage: "bubble.left.and.bubble.right") }

            AboutView(session: session)
                .tabItem { Label("About", systemImage: "info.circle") }
        }
    }

    private func openNewChat() async {
        let userId = newChatUserId.trimmingCharacters(in: .whitespaces)
        newChatUserId = ""
        guard !userId.isEmpty else { return }
        do {
            let conversation = try await session.relay.chat.openConversation(with: userId)
            path.append(conversation.id)
        } catch {
            newChatError = error.localizedDescription
        }
    }
}

/// Wraps `MessageThreadView` (public SwiftUI from RelayUI) with a toolbar call button — the
/// integration point most host apps actually want: "call the person I'm chatting with."
private struct ThreadWithCallingView: View {
    let conversationId: ConversationId
    let calls: CallCenter
    @Environment(RelayClient.self) private var client

    var body: some View {
        MessageThreadView(conversationId: conversationId)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { start(.audio) } label: { Image(systemName: "phone") }
                        .disabled(calls.call != nil)
                    Button { start(.video) } label: { Image(systemName: "video") }
                        .disabled(calls.call != nil)
                }
            }
    }

    private func start(_ type: CallType) {
        guard let conversation = client.chat.conversation(conversationId) else { return }
        calls.start(conversation: conversation, type: type)
    }
}
