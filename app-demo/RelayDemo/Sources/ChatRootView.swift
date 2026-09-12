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
        MessageThreadView(conversationId: conversationId, onSearchPeople: searchPeople)
            .toolbar {
                // Reference pattern for host apps: since RelayCall has no SDK-owned call button,
                // WE own gating it on the `audioCalls`/`videoCalls` module flags from
                // `client.modules` (populated from GET /users/me at connect time). `calls.start`
                // itself does not check this — it would just fail server-side (403
                // module_disabled) if a disabled call type were started, so the button must not
                // be offered in the first place.
                ToolbarItemGroup(placement: .primaryAction) {
                    if client.modules.audioCalls {
                        Button { start(.audio) } label: { Image(systemName: "phone") }
                            .disabled(calls.call != nil)
                    }
                    if client.modules.videoCalls {
                        Button { start(.video) } label: { Image(systemName: "video") }
                            .disabled(calls.call != nil)
                    }
                }
            }
    }

    private func start(_ type: CallType) {
        guard let conversation = client.chat.conversation(conversationId) else { return }
        calls.start(conversation: conversation, type: type)
    }

    /// "Add people" in the group-info screen now drives the SDK's own `AddParticipantsView` —
    /// this app just needs to answer its search queries. A real host would call its own directory
    /// or contacts API here; this is an in-memory mock so the picker has something to show.
    private func searchPeople(_ query: String) async -> [RelayUser] {
        try? await Task.sleep(nanoseconds: 200_000_000) // pretend this is a network round trip
        guard !query.isEmpty else { return mockDirectory }
        return mockDirectory.filter { ($0.displayName ?? "").localizedCaseInsensitiveContains(query) }
    }
}

/// Fake directory for the "Add participants" demo — varied online/offline and last-seen states,
/// no avatarUrl on any of them so AddParticipantsView's initials fallback gets exercised.
private let mockDirectory: [RelayUser] = [
    RelayUser(userId: "u_amelia", displayName: "Amelia Chen", isOnline: true),
    RelayUser(userId: "u_ben", displayName: "Ben Okafor", isOnline: false, lastSeenAt: Date().addingTimeInterval(-3600)),
    RelayUser(userId: "u_carla", displayName: "Carla Reyes", isOnline: true),
    RelayUser(userId: "u_diego", displayName: "Diego Fernandez", isOnline: false),
    RelayUser(userId: "u_elena", displayName: "Elena Petrova", isOnline: false, lastSeenAt: Date().addingTimeInterval(-2 * 86_400)),
    RelayUser(userId: "u_farid", displayName: "Farid Haidari", isOnline: true),
    RelayUser(userId: "u_grace", displayName: "Grace Kim", isOnline: false),
    RelayUser(userId: "u_hassan", displayName: "Hassan Ali", isOnline: true),
]
