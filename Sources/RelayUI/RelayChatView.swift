import SwiftUI

/// The whole chat UI in one view: conversation list → thread, with a connection banner.
/// Drop it anywhere (a tab, a sheet, a navigation destination):
///
///     RelayChatView(client: relay)
///
/// Everything inside reads the client from the SwiftUI environment, so you can also compose
/// `ConversationListView` / `MessageThreadView` yourself and inject it with `.environment(relay)`.
public struct RelayChatView: View {
    private let client: RelayClient
    @State private var path: [ConversationId] = []

    public init(client: RelayClient) { self.client = client }

    public var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                ConnectionBanner(connection: client.connection)
                ConversationListView()
                    .navigationDestination(for: ConversationId.self) { id in MessageThreadView(conversationId: id) }
            }
            .navigationTitle("Chats")
        }
        .environment(client)
        .task {
            if client.connection.state == .idle || client.connection.state == .closed { _ = try? await client.connect() }
        }
    }

    /// Programmatically open a thread (e.g. from a push notification tap).
    public func opening(_ conversationId: ConversationId) -> some View {
        var copy = self
        copy._path = State(initialValue: [conversationId])
        return copy
    }
}

struct ConnectionBanner: View {
    @Environment(\.relayTheme) private var theme
    let connection: ConnectionSnapshot
    var body: some View {
        if connection.state != .connected && connection.state != .idle {
            Text(connection.state == .connecting ? "Connecting…" : connection.state == .reconnecting ? "Reconnecting…" : "Disconnected")
                .font(.caption).foregroundStyle(theme.secondaryText)
                .frame(maxWidth: .infinity).padding(.vertical, 4)
                .background(Color.gray.opacity(0.12))
        }
    }
}
