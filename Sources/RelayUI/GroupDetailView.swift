import SwiftUI

/// Group info screen opened by tapping the group name in the thread header: photo, name, member
/// count + created date, and (creator only, since that's the SDK's only notion of "admin" — see
/// `conversation.creatorId`) add/remove participants. Mirrors the web client's GroupDetailModal.
struct GroupDetailView: View {
    @Environment(RelayClient.self) private var client
    @Environment(\.relayTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    let conversationId: ConversationId

    /// Invoked when "Add people" is tapped; the host owns the user-picker UI. Return the ids to
    /// add, or nil/empty to cancel. Omitted hides the "Add people" row.
    var onPickAdd: (() async -> [UserId]?)?

    @State private var participants: [Participant]?
    @State private var creatorId: UserId?
    @State private var busyUserId: UserId?
    @State private var addingBusy = false
    @State private var errorText: String?

    var body: some View {
        let conversation = client.chat.conversation(conversationId)
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 8) {
                        AvatarView(name: conversation?.title, url: conversation?.photoUrl, colorKey: "g:\(conversationId)", size: 72)
                        Text(conversation?.title ?? "Group").font(.title3).fontWeight(.semibold)
                        Text(summary(conversation))
                            .font(.footnote).foregroundStyle(theme.secondaryText)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .listRowBackground(Color.clear)
                }

                if let errorText {
                    Section { Text(errorText).font(.footnote).foregroundStyle(theme.danger) }
                }

                Section {
                    if isAdmin, onPickAdd != nil {
                        Button {
                            Task { await addPeople() }
                        } label: {
                            HStack(spacing: 12) {
                                ZStack {
                                    Circle().fill(Color.gray.opacity(0.15)).frame(width: 36, height: 36)
                                    Image(systemName: "plus")
                                }
                                Text("Add people")
                            }
                        }
                        .disabled(addingBusy)
                    }

                    if let participants {
                        ForEach(participants) { p in
                            HStack(spacing: 12) {
                                AvatarView(name: p.displayName ?? p.userId, url: p.avatarUrl, colorKey: p.userId, size: 36)
                                HStack(spacing: 6) {
                                    Text(p.displayName ?? p.userId)
                                    if p.userId == creatorId {
                                        Text("Admin")
                                            .font(.caption2).fontWeight(.semibold)
                                            .padding(.horizontal, 6).padding(.vertical, 2)
                                            .background(Capsule().fill(Color.gray.opacity(0.15)))
                                    }
                                    if p.userId == client.userId {
                                        Text("(You)").font(.footnote).foregroundStyle(theme.secondaryText)
                                    }
                                }
                                Spacer()
                                if isAdmin, p.userId != creatorId {
                                    Button("Remove", role: .destructive) {
                                        Task { await remove(p.userId) }
                                    }
                                    .font(.footnote)
                                    .disabled(busyUserId == p.userId)
                                }
                            }
                        }
                    } else {
                        Text("Loading…").foregroundStyle(theme.secondaryText)
                    }
                }
            }
            .navigationTitle("Group info")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .task { await load() }
        }
    }

    private var isAdmin: Bool {
        guard let me = client.userId, let creatorId else { return false }
        return me == creatorId
    }

    private func summary(_ conversation: Conversation?) -> String {
        guard let conversation else { return "" }
        let created = conversation.createdAt.formatted(.dateTime.month(.wide).day().year())
        return "\(conversation.memberCount) members · Created \(created)"
    }

    private func load() async {
        do {
            let response = try await client.api.participants(of: conversationId)
            participants = response.participants
            creatorId = response.creatorId
        } catch {
            errorText = "Could not load participants."
        }
    }

    private func remove(_ userId: UserId) async {
        busyUserId = userId
        errorText = nil
        do {
            try await client.chat.removeMember(conversationId, userId: userId)
            await load()
        } catch {
            errorText = "Could not remove that member."
        }
        busyUserId = nil
    }

    private func addPeople() async {
        guard let onPickAdd else { return }
        guard let userIds = await onPickAdd(), !userIds.isEmpty else { return }
        addingBusy = true
        errorText = nil
        do {
            try await client.chat.addMembers(conversationId, userIds: userIds)
            await load()
        } catch {
            errorText = "Could not add those members."
        }
        addingBusy = false
    }
}
