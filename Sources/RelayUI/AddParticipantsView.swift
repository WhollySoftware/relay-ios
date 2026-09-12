import SwiftUI

/// SDK-owned "Add participants" screen, opened from `GroupDetailView` when the host supplies
/// `onSearchPeople` (rich `RelayUser` results) instead of — or as well as — the older
/// `onPickAdd` raw-id callback. Search-as-you-type over the host's directory, multi-select with
/// removable chips, then a single `addMembers` call identical to the one `GroupDetailView`'s own
/// `onPickAdd` flow already makes.
struct AddParticipantsView: View {
    @Environment(RelayClient.self) private var client
    @Environment(\.relayTheme) private var theme
    @Environment(\.relayIcons) private var icons
    @Environment(\.dismiss) private var dismiss
    let conversationId: ConversationId
    let onSearchPeople: (String) async -> [RelayUser]
    /// Called after a successful add, before dismissing — lets the caller (GroupDetailView)
    /// refresh its own participant list.
    var onAdded: (() async -> Void)?

    @State private var query = ""
    @State private var results: [RelayUser] = []
    @State private var selected: [RelayUser] = []
    @State private var loading = false
    @State private var adding = false
    @State private var errorText: String?

    // Out-of-order responses are discarded by generation, not by task cancellation — a debounced
    // keystroke and the initial "" search can complete in either order.
    @State private var searchGeneration = 0
    @State private var debounceTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchField
                if !selected.isEmpty { chipsRow }
                if let errorText {
                    Text(errorText).font(.footnote).foregroundStyle(theme.danger)
                        .padding(.horizontal, 16).padding(.top, 4)
                }
                Divider()
                resultsArea
            }
            .navigationTitle("Add participants")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("Add (\(selected.count))") { Task { await addSelected() } }
                        .disabled(selected.isEmpty || adding)
                }
            }
            .task { await performSearch("") }
            .onChange(of: query) { _, newValue in scheduleSearch(newValue) }
        }
    }

    // MARK: - Search field & chips

    private var searchField: some View {
        HStack(spacing: 8) {
            icons.search.foregroundStyle(theme.secondaryText)
            TextField("Search people", text: $query)
                .textFieldStyle(.plain)
                #if os(iOS)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                #endif
            if loading {
                ProgressView().controlSize(.small)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.12)))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var chipsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(selected) { user in
                    HStack(spacing: 6) {
                        AvatarView(name: user.displayName ?? user.userId, url: user.avatarUrl, colorKey: user.userId, size: 24)
                        Text(firstName(user)).font(.footnote).lineLimit(1)
                        Button { toggle(user) } label: {
                            icons.close.foregroundStyle(theme.secondaryText)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.leading, 4).padding(.trailing, 8).padding(.vertical, 4)
                    .background(Capsule().fill(Color.gray.opacity(0.15)))
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 8)
    }

    // MARK: - Results

    @ViewBuilder
    private var resultsArea: some View {
        if loading && results.isEmpty {
            ScrollView { skeletonRows }
        } else if results.isEmpty {
            emptyState
        } else {
            List(results) { user in
                row(user)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            }
            .listStyle(.plain)
        }
    }

    private func row(_ user: RelayUser) -> some View {
        let isSelected = isSelected(user)
        return Button {
            toggle(user)
        } label: {
            HStack(spacing: 12) {
                ZStack(alignment: .bottomTrailing) {
                    AvatarView(name: user.displayName ?? user.userId, url: user.avatarUrl, colorKey: user.userId, size: 44)
                    if user.isOnline == true { PresenceDot(online: true) }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(user.displayName ?? user.userId).foregroundStyle(.primary)
                    if let subtitle = subtitle(user) {
                        Text(subtitle).font(.caption).foregroundStyle(theme.secondaryText)
                    }
                }
                Spacer()
                (isSelected ? icons.selected : icons.unselected)
                    .font(.system(size: 20))
                    .foregroundStyle(isSelected ? theme.accent : theme.secondaryText.opacity(0.5))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var skeletonRows: some View {
        VStack(spacing: 0) {
            ForEach(0..<6, id: \.self) { _ in
                HStack(spacing: 12) {
                    Circle().fill(Color.gray.opacity(0.15)).frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 6) {
                        RoundedRectangle(cornerRadius: 4).fill(Color.gray.opacity(0.15)).frame(width: 140, height: 12)
                        RoundedRectangle(cornerRadius: 4).fill(Color.gray.opacity(0.1)).frame(width: 90, height: 10)
                    }
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            icons.personQuestion
                .font(.system(size: 36))
                .foregroundStyle(theme.secondaryText)
            Text("No one matches \u{201C}\(query)\u{201D}").font(.subheadline.weight(.semibold))
            Text("Try a different name or check the spelling.")
                .font(.footnote).foregroundStyle(theme.secondaryText)
        }
        .multilineTextAlignment(.center)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Selection

    private func isSelected(_ user: RelayUser) -> Bool {
        selected.contains { $0.userId == user.userId }
    }

    private func toggle(_ user: RelayUser) {
        if let index = selected.firstIndex(where: { $0.userId == user.userId }) {
            selected.remove(at: index)
        } else {
            selected.append(user)
        }
    }

    private func firstName(_ user: RelayUser) -> String {
        let name = user.displayName ?? user.userId
        return name.split(separator: " ").first.map(String.init) ?? name
    }

    /// "Online" / "Last seen …" / omitted — a stricter, "omit when unknown" variant of
    /// `RelayFormat.lastSeen`, which falls back to "Offline" instead.
    private func subtitle(_ user: RelayUser) -> String? {
        if user.isOnline == true { return "Online" }
        guard let lastSeenAt = user.lastSeenAt else { return nil }
        let rel = RelayFormat.relative(lastSeenAt)
        return rel == "now" ? "Last seen just now" : "Last seen \(rel)\(rel.last.map { "mhd".contains($0) } == true ? " ago" : "")"
    }

    // MARK: - Search

    private func scheduleSearch(_ text: String) {
        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            await performSearch(text)
        }
    }

    private func performSearch(_ text: String) async {
        searchGeneration += 1
        let generation = searchGeneration
        loading = true
        let people = await onSearchPeople(text)
        // A later search may already have started (or finished) while this one was in flight —
        // only the most recent generation is allowed to write into `results`.
        guard generation == searchGeneration else { return }
        results = people
        loading = false
    }

    // MARK: - Add

    private func addSelected() async {
        guard !selected.isEmpty else { return }
        adding = true
        errorText = nil
        do {
            try await client.chat.addMembers(conversationId, userIds: selected.map(\.userId))
            await onAdded?()
            dismiss()
        } catch {
            errorText = "Could not add those members."
        }
        adding = false
    }
}
