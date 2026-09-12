import SwiftUI
import PhotosUI

// Client-side cap mirroring MessageComposerView's own image cap (service/src/routes/conversations.js).
private let maxGroupPhotoBytes = 1_800_000

/// Group info screen opened by tapping the group name in the thread header: photo, name, member
/// count + created date, add/remove participants (creator only — since that's the SDK's only
/// notion of "admin", see `conversation.creatorId`), plus leave/mute/clear-chat for every member
/// and a media gallery. Mirrors the web client's GroupDetailModal.tsx.
struct GroupDetailView: View {
    @Environment(RelayClient.self) private var client
    @Environment(\.relayTheme) private var theme
    @Environment(\.relayIcons) private var icons
    @Environment(\.dismiss) private var dismiss
    let conversationId: ConversationId

    /// Invoked when "Add people" is tapped and `onSearchPeople` is NOT supplied; the host owns the
    /// user-picker UI. Return the ids to add, or nil/empty to cancel. Omitted (with `onSearchPeople`
    /// also omitted) hides the "Add people" row.
    var onPickAdd: (() async -> [UserId]?)?

    /// Invoked to search for people to add. When supplied, "Add people" opens the SDK-owned
    /// `AddParticipantsView` instead of calling `onPickAdd` directly.
    var onSearchPeople: ((String) async -> [RelayUser])?

    @State private var participants: [Participant]?
    @State private var creatorId: UserId?
    @State private var busyUserId: UserId?
    @State private var addingBusy = false
    @State private var leaveBusy = false
    @State private var clearBusy = false
    @State private var muteBusy = false
    @State private var errorText: String?

    @State private var confirmRemove: Participant?
    @State private var confirmLeave = false
    @State private var confirmClear = false
    @State private var showMedia = false
    @State private var showingAddParticipants = false

    @State private var editing = false
    @State private var editName = ""
    @State private var editPhoto: String?
    @State private var editPhotoItem: PhotosPickerItem?
    @State private var editSaving = false

    var body: some View {
        let conversation = client.chat.conversation(conversationId)
        NavigationStack {
            List {
                Section {
                    if editing {
                        editSummary(conversation)
                    } else {
                        summarySection(conversation)
                    }
                }

                if let errorText {
                    Section { Text(errorText).font(.footnote).foregroundStyle(theme.danger) }
                }

                Section {
                    NavigationLink {
                        MediaGalleryView(conversationId: conversationId)
                    } label: {
                        HStack(spacing: 12) {
                            iconBadge(icons.photo)
                            Text("Media, links & docs")
                        }
                    }

                    Toggle(isOn: Binding(
                        get: { conversation?.muted ?? false },
                        set: { newValue in Task { await toggleMute(newValue) } }
                    )) {
                        HStack(spacing: 12) {
                            iconBadge(icons.muteNotifications)
                            Text("Mute notifications")
                        }
                    }
                    .disabled(muteBusy)

                    Button(role: .destructive) {
                        confirmClear = true
                    } label: {
                        HStack(spacing: 12) {
                            iconBadge(icons.delete)
                            Text("Clear chat")
                        }
                    }
                    .disabled(clearBusy)

                    Button(role: .destructive) {
                        confirmLeave = true
                    } label: {
                        HStack(spacing: 12) {
                            iconBadge(icons.leaveGroup)
                            Text("Leave group")
                        }
                    }
                    .disabled(leaveBusy)
                }

                Section {
                    if isAdmin, onPickAdd != nil || onSearchPeople != nil {
                        Button {
                            if onSearchPeople != nil {
                                showingAddParticipants = true
                            } else {
                                Task { await addPeople() }
                            }
                        } label: {
                            HStack(spacing: 12) {
                                ZStack {
                                    Circle().fill(Color.gray.opacity(0.15)).frame(width: 36, height: 36)
                                    icons.addPeople
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
                                        confirmRemove = p
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
            .confirmationDialog(
                "Remove member",
                isPresented: Binding(get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } }),
                titleVisibility: .visible
            ) {
                if let target = confirmRemove {
                    Button("Remove", role: .destructive) { Task { await remove(target.userId) } }
                    Button("Cancel", role: .cancel) { confirmRemove = nil }
                }
            } message: {
                if let target = confirmRemove {
                    Text("Remove \(target.displayName ?? target.userId) from this group?")
                }
            }
            .alert("Leave group", isPresented: $confirmLeave) {
                Button("Leave", role: .destructive) { Task { await leave() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You will stop receiving messages from this group.")
            }
            .alert("Clear chat", isPresented: $confirmClear) {
                Button("Clear", role: .destructive) { Task { await clear() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This clears the chat history on your side only. Other members keep theirs.")
            }
            .sheet(isPresented: $showingAddParticipants) {
                if let onSearchPeople {
                    AddParticipantsView(conversationId: conversationId, onSearchPeople: onSearchPeople) {
                        await load()
                    }
                }
            }
        }
    }

    // MARK: - Summary / edit

    @ViewBuilder
    private func summarySection(_ conversation: Conversation?) -> some View {
        VStack(spacing: 8) {
            AvatarView(name: conversation?.title, url: conversation?.photoUrl, colorKey: "g:\(conversationId)", size: 72)
            Text(conversation?.title ?? "Group").font(.title3).fontWeight(.semibold)
            Text(summary(conversation))
                .font(.footnote).foregroundStyle(theme.secondaryText)
            if isAdmin {
                Button("Edit name & photo") {
                    editName = conversation?.name ?? ""
                    editPhoto = conversation?.photoUrl
                    editing = true
                }
                .font(.footnote)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .listRowBackground(Color.clear)
    }

    @ViewBuilder
    private func editSummary(_ conversation: Conversation?) -> some View {
        VStack(spacing: 8) {
            PhotosPicker(selection: $editPhotoItem, matching: .images) {
                ZStack(alignment: .bottomTrailing) {
                    AvatarView(name: editName.isEmpty ? "Group" : editName, url: editPhoto, colorKey: "g:\(conversationId)", size: 72)
                    icons.editPhoto
                        .font(.system(size: 20))
                        .foregroundStyle(.white, theme.accent)
                }
            }
            .buttonStyle(.plain)
            .onChange(of: editPhotoItem) { _, item in
                guard let item else { return }
                Task { await loadEditPhoto(item) }
            }

            TextField("Group name", text: $editName)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 220)

            HStack(spacing: 16) {
                Button("Cancel") { editing = false }
                    .disabled(editSaving)
                Button("Save") { Task { await saveEdit() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(editSaving || editName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .listRowBackground(Color.clear)
    }

    private func iconBadge(_ icon: Image) -> some View {
        ZStack {
            Circle().fill(Color.gray.opacity(0.15)).frame(width: 32, height: 32)
            icon.font(.system(size: 14))
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

    // MARK: - Actions

    private func load() async {
        do {
            let response = try await client.api.participants(of: conversationId)
            // Admin (the creator) always shown first, everyone else keeps the server's join order.
            if let cid = response.creatorId {
                participants = response.participants.sorted { ($0.userId == cid ? 0 : 1) < ($1.userId == cid ? 0 : 1) }
            } else {
                participants = response.participants
            }
            creatorId = response.creatorId
        } catch {
            errorText = "Could not load participants."
        }
    }

    private func remove(_ userId: UserId) async {
        confirmRemove = nil
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

    private func leave() async {
        confirmLeave = false
        leaveBusy = true
        errorText = nil
        do {
            try await client.chat.deleteConversation(conversationId)
            dismiss()
        } catch {
            errorText = "Could not leave the group."
            leaveBusy = false
        }
    }

    private func clear() async {
        confirmClear = false
        clearBusy = true
        errorText = nil
        do {
            try await client.chat.clearHistory(conversationId)
            dismiss()
        } catch {
            errorText = "Could not clear the chat."
            clearBusy = false
        }
    }

    private func toggleMute(_ muted: Bool) async {
        muteBusy = true
        errorText = nil
        do {
            try await client.chat.muteConversation(conversationId, muted: muted)
        } catch {
            errorText = "Could not update notifications."
        }
        muteBusy = false
    }

    private func loadEditPhoto(_ item: PhotosPickerItem) async {
        defer { editPhotoItem = nil }
        guard let data = try? await item.loadTransferable(type: Data.self) else { errorText = "Couldn't load that photo."; return }
        guard data.count <= maxGroupPhotoBytes else { errorText = "Image too large — keep it under 1.8MB."; return }
        let mime = item.supportedContentTypes.first?.preferredMIMEType ?? "image/jpeg"
        editPhoto = "data:\(mime);base64,\(data.base64EncodedString())"
    }

    private func saveEdit() async {
        let name = editName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { errorText = "Group name cannot be empty."; return }
        editSaving = true
        errorText = nil
        let conversation = client.chat.conversation(conversationId)
        do {
            try await client.chat.updateGroup(
                conversationId,
                name: name == conversation?.name ? nil : name,
                photoUrl: editPhoto == conversation?.photoUrl ? nil : .some(editPhoto)
            )
            editing = false
        } catch {
            errorText = "Could not save changes."
        }
        editSaving = false
    }
}
