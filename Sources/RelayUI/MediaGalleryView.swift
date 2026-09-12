import SwiftUI

/// WhatsApp-style "Media, links & docs" gallery: photos/videos in a 4-column grid, generic
/// attachments as a list, both grouped by month (newest first). Backed by `kind=media` on the
/// messages endpoint (see RelayAPI.getMedia) so it scales without paging through the whole text
/// history. Mirrors the web client's MediaGalleryModal.tsx. There's no "Links" tab yet — the
/// server doesn't tag which plain-text messages contain a URL.
struct MediaGalleryView: View {
    @Environment(RelayClient.self) private var client
    @Environment(\.relayTheme) private var theme
    @Environment(\.relayIcons) private var icons
    let conversationId: ConversationId

    private enum Tab { case media, docs }

    @State private var tab: Tab = .media
    @State private var messages: [Message]?
    @State private var hasMore = false
    @State private var loadingMore = false
    @State private var errorText: String?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 4)

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("Media").tag(Tab.media)
                Text("Docs").tag(Tab.docs)
            }
            .pickerStyle(.segmented)
            .padding()

            if let errorText {
                Text(errorText).font(.footnote).foregroundStyle(theme.danger).padding(.horizontal)
            }

            if messages == nil {
                Spacer()
                ProgressView("Loading…")
                Spacer()
            } else if tab == .media {
                mediaGrid
            } else {
                docsList
            }
        }
        .navigationTitle("Media, links & docs")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await load() }
    }

    // MARK: - Media grid

    private var mediaItems: [Message] { (messages ?? []).filter(isVisual).reversed() }
    private var docItems: [Message] { (messages ?? []).filter { !isVisual($0) }.reversed() }

    @ViewBuilder
    private var mediaGrid: some View {
        let groups = groupByMonth(mediaItems)
        if groups.isEmpty {
            Spacer()
            Text("No photos or videos yet.").foregroundStyle(theme.secondaryText)
            Spacer()
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(groups, id: \.label) { group in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(group.label).font(.subheadline.weight(.semibold)).padding(.horizontal)
                            LazyVGrid(columns: columns, spacing: 2) {
                                ForEach(group.items) { m in
                                    mediaTile(m)
                                }
                            }
                        }
                    }
                    loadMoreButton
                }
                .padding(.bottom, 12)
            }
        }
    }

    @ViewBuilder
    private func mediaTile(_ m: Message) -> some View {
        let thumbUrl = m.imageUrl ?? m.fileThumbnailUrl
        ZStack {
            if let thumbUrl, let url = URL(string: thumbUrl) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        Color.gray.opacity(0.15)
                    }
                }
            } else {
                Color.gray.opacity(0.15)
            }
            if m.imageUrl == nil {
                icons.playFilled
                    .foregroundStyle(.white)
                    .padding(6)
                    .background(Circle().fill(Color.black.opacity(0.4)))
            }
        }
        .aspectRatio(1, contentMode: .fill)
        .clipped()
    }

    // MARK: - Docs list

    @ViewBuilder
    private var docsList: some View {
        let groups = groupByMonth(docItems)
        if groups.isEmpty {
            Spacer()
            Text("No documents yet.").foregroundStyle(theme.secondaryText)
            Spacer()
        } else {
            List {
                ForEach(groups, id: \.label) { group in
                    Section(group.label) {
                        ForEach(group.items) { m in
                            HStack(spacing: 12) {
                                (m.audioUrl != nil ? icons.voiceMessage : icons.document)
                                    .frame(width: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(m.fileName ?? (m.audioUrl != nil ? "Voice message" : "File"))
                                        .lineLimit(1)
                                    if let bytes = m.fileSizeBytes {
                                        Text("\(bytes / 1024) KB").font(.caption).foregroundStyle(theme.secondaryText)
                                    }
                                }
                            }
                        }
                    }
                }
                if hasMore {
                    loadMoreButton
                }
            }
            .listStyle(.plain)
        }
    }

    @ViewBuilder
    private var loadMoreButton: some View {
        if hasMore {
            Button {
                Task { await load(before: messages?.first?.id) }
            } label: {
                if loadingMore {
                    ProgressView()
                } else {
                    Text("Load earlier")
                }
            }
            .frame(maxWidth: .infinity)
            .disabled(loadingMore)
        }
    }

    // MARK: - Data

    private func isVisual(_ m: Message) -> Bool {
        m.imageUrl != nil || (m.fileUrl != nil && (m.fileMime ?? "").hasPrefix("video/"))
    }

    private func load(before: MessageId? = nil) async {
        if before != nil { loadingMore = true }
        do {
            let page = try await client.chat.getMedia(conversationId, before: before, limit: 60)
            if let before {
                _ = before
                messages = page.messages + (messages ?? [])
            } else {
                messages = page.messages
            }
            hasMore = page.hasMore
        } catch {
            errorText = "Could not load media."
        }
        loadingMore = false
    }

    private struct MonthGroup { let label: String; let items: [Message] }

    private func groupByMonth(_ items: [Message]) -> [MonthGroup] {
        var groups: [MonthGroup] = []
        for item in items {
            let label = monthLabel(item.createdAt)
            if let last = groups.last, last.label == label {
                groups[groups.count - 1] = MonthGroup(label: label, items: last.items + [item])
            } else {
                groups.append(MonthGroup(label: label, items: [item]))
            }
        }
        return groups
    }

    private func monthLabel(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        let comps = calendar.dateComponents([.year, .month], from: date)
        let nowComps = calendar.dateComponents([.year, .month], from: now)
        if comps.year == nowComps.year && comps.month == nowComps.month { return "This month" }
        if comps.year == nowComps.year { return date.formatted(.dateTime.month(.wide)) }
        return date.formatted(.dateTime.month(.wide).year())
    }
}
