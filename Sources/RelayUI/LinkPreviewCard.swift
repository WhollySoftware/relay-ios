import SwiftUI
import RelayCore

/// Module-level so every card for the same URL across the app shares one fetch and one result —
/// the service already Redis-caches per URL; this just avoids re-asking it on every remount
/// (switching threads, scrolling a long history back into view, etc).
actor LinkPreviewCache {
    static let shared = LinkPreviewCache()
    private var results: [String: LinkPreview?] = [:]
    private var inflight: [String: Task<LinkPreview?, Never>] = [:]

    func preview(for url: String, using api: RelayAPI) async -> LinkPreview? {
        if let cached = results[url] { return cached }
        if let existing = inflight[url] { return await existing.value }
        let task = Task<LinkPreview?, Never> {
            (try? await api.linkPreview(url: url)) ?? nil
        }
        inflight[url] = task
        let result = await task.value
        results[url] = result
        inflight[url] = nil
        return result
    }
}

/// Social-app-style link preview card (title, description, image, site name) for a URL found in a
/// message — same shape WhatsApp/iMessage/etc. show under a bubble. Renders nothing at all while
/// loading or when the page has no usable Open Graph metadata, so a plain link doesn't get an
/// empty shell.
public struct LinkPreviewCard: View {
    @Environment(RelayClient.self) private var client
    let url: String
    let isOwn: Bool
    @State private var preview: LinkPreview?

    public init(url: String, isOwn: Bool) {
        self.url = url; self.isOwn = isOwn
    }

    public var body: some View {
        Group {
            if let preview, preview.title != nil || preview.description != nil {
                // Sizing/spacing mirrors the web card exactly (packages/web/react's
                // .relay-link-preview): 280pt max width, 144pt image, 10pt corner radius, a hairline
                // border rather than just a fill, 9/12/11pt type for site/title/description.
                Link(destination: URL(string: url) ?? URL(string: "about:blank")!) {
                    VStack(alignment: .leading, spacing: 0) {
                        if let imageUrlString = preview.imageUrl, let imageUrl = URL(string: imageUrlString) {
                            AsyncImage(url: imageUrl) { phase in
                                if let img = phase.image { img.resizable().scaledToFill() } else { Color.gray.opacity(0.15) }
                            }
                            .frame(height: 144).clipped()
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            if let site = preview.siteName {
                                Text(site.uppercased()).font(.system(size: 9, weight: .semibold)).opacity(0.65)
                            }
                            if let title = preview.title {
                                Text(title).font(.system(size: 12, weight: .bold)).lineLimit(2)
                            }
                            if let description = preview.description {
                                Text(description).font(.system(size: 11)).opacity(0.8).lineLimit(2)
                            }
                        }
                        .padding(9)
                    }
                }
                .frame(maxWidth: 280)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(isOwn ? 0.1 : 0.05)))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.gray.opacity(isOwn ? 0.25 : 0.12), lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(.primary)
            } else {
                // Not EmptyView(): a lazily-rendered list (LazyVStack/List) skips lifecycle
                // callbacks — including .task below — for a genuinely zero-sized view, so this
                // would otherwise never even fetch the preview it's waiting on.
                Color.clear.frame(width: 1, height: 1)
            }
        }
        .task(id: url) {
            preview = await LinkPreviewCache.shared.preview(for: url, using: client.api)
        }
    }
}

/// Compose-time preview shown above the input while a URL sits in the draft, before it's sent —
/// dismissible, and purely cosmetic: it never changes what's sent, since the recipient's bubble
/// renders its own `LinkPreviewCard` from the same URL once the message lands.
struct ComposeLinkPreviewCard: View {
    @Environment(RelayClient.self) private var client
    let url: String
    var onDismiss: () -> Void
    @State private var preview: LinkPreview?

    var body: some View {
        Group {
            if let preview, preview.title != nil || preview.description != nil {
                HStack(spacing: 10) {
                    if let imageUrlString = preview.imageUrl, let imageUrl = URL(string: imageUrlString) {
                        AsyncImage(url: imageUrl) { phase in
                            if let img = phase.image { img.resizable().scaledToFill() } else { Color.gray.opacity(0.15) }
                        }
                        .frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        if let site = preview.siteName {
                            Text(site.uppercased()).font(.system(size: 9, weight: .semibold)).opacity(0.65)
                        }
                        Text(preview.title ?? preview.url).font(.caption.bold()).lineLimit(1)
                        if let description = preview.description {
                            Text(description).font(.caption2).opacity(0.8).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    Button(action: onDismiss) {
                        Image(systemName: "xmark").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.1)))
            } else {
                Color.clear.frame(width: 1, height: 1)
            }
        }
        .task(id: url) {
            preview = await LinkPreviewCache.shared.preview(for: url, using: client.api)
        }
    }
}
