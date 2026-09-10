import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import AVFoundation
#if os(iOS)
import UIKit
#endif

// Client-side caps mirroring the service's own (service/src/routes/conversations.js) — rejecting
// an oversized pick here gives an instant, specific error instead of a round trip that 400s.
private let maxImageBytes = 1_800_000   // ~1.8MB of raw bytes leaves room for base64 under the service's 2.5MB data: URL cap
private let maxAttachmentBytes = 9_500_000 // same margin under the service's 14MB (~10MB raw) file cap

/// Text box + send button, plus an attach menu (Camera / Photo Library / File) mirroring
/// DevBattel's chat composer. Return sends; the store throttles typing indicators. Doubles as the
/// inline editor when `editing` is set.
///
/// Permissions: `PhotosPicker` and `.fileImporter` need NONE (both are out-of-process pickers —
/// this code never gets broader photo-library or file-system access than the one item the user
/// picked). Only **Camera** needs anything from the host app: add `NSCameraUsageDescription` to
/// its Info.plist (the same key `RelayCall` already needs for video calls, so an app with calling
/// already has it) — without it, tapping Camera does nothing but log a crash to the console, iOS
/// silently kills apps that omit a required usage string the moment they touch that API.
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

    @State private var showAttachMenu = false
    @State private var showPhotoLibrary = false
    @State private var photoItem: PhotosPickerItem?
    @State private var showFileImporter = false
    #if os(iOS)
    @State private var showCamera = false
    #endif
    @State private var pendingAttachment: PendingAttachment?
    @State private var loadingAttachment = false
    @State private var dismissedPreviewUrl: String?

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
            if let pendingAttachment {
                attachmentPreview(pendingAttachment)
            }
            if loadingAttachment {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Preparing attachment…").font(.caption).foregroundStyle(theme.secondaryText) }
            }
            if pendingAttachment == nil, editing == nil, let draftUrl = RelayFormat.firstUrl(in: text), draftUrl != dismissedPreviewUrl {
                ComposeLinkPreviewCard(url: draftUrl) { dismissedPreviewUrl = draftUrl }
            }
            if let error { Text(error).font(.caption).foregroundStyle(theme.danger) }
            HStack(alignment: .bottom, spacing: 8) {
                if editing == nil {
                    Button { showAttachMenu = true } label: { Image(systemName: "paperclip").font(.system(size: 20)) }
                        .buttonStyle(.plain)
                        .foregroundStyle(theme.secondaryText)
                        .confirmationDialog("Attach", isPresented: $showAttachMenu, titleVisibility: .hidden) {
                            #if os(iOS)
                            Button("Camera") { showCamera = true }
                            #endif
                            Button("Photo Library") { showPhotoLibrary = true }
                            Button("File") { showFileImporter = true }
                            Button("Cancel", role: .cancel) {}
                        }
                }
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
        .photosPicker(isPresented: $showPhotoLibrary, selection: $photoItem, matching: .any(of: [.images, .videos]))
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task { await loadPickedPhoto(item) }
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item]) { result in
            Task { await handlePickedFile(result) }
        }
        #if os(iOS)
        .sheet(isPresented: $showCamera) {
            CameraCapture { image in
                showCamera = false
                if let image { Task { await attachImage(image) } }
            }
        }
        #endif
    }

    private var canSend: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || pendingAttachment != nil }

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

    @ViewBuilder
    private func attachmentPreview(_ attachment: PendingAttachment) -> some View {
        HStack(spacing: 8) {
            switch attachment {
            case .image(let dataUrl):
                if let url = URL(string: dataUrl) {
                    AsyncImage(url: url) { $0.image?.resizable().scaledToFill() }
                        .frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 8))
                }
            case .file(_, let name, let mime, let thumbnail, _):
                if let thumbnail, let url = URL(string: thumbnail) {
                    AsyncImage(url: url) { $0.image?.resizable().scaledToFill() }
                        .frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    Image(systemName: mime.hasPrefix("video/") ? "video.fill" : "doc.fill").frame(width: 44, height: 44)
                }
                Text(name).font(.caption).lineLimit(1)
            }
            Spacer()
            Button { pendingAttachment = nil } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(theme.secondaryText)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.12)))
    }

    private func send() async {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty || pendingAttachment != nil, !busy else { return }
        busy = true
        defer { busy = false }
        error = nil
        let draft = text
        let attachment = pendingAttachment
        text = ""
        pendingAttachment = nil
        dismissedPreviewUrl = nil
        do {
            if let editing {
                _ = try await client.chat.editMessage(conversationId, messageId: editing.id, body: body)
                self.editing = nil
            } else {
                var input = SendMessageInput(body: body.isEmpty ? nil : body, replyToId: replyTo?.id)
                switch attachment {
                case .image(let dataUrl): input.imageUrl = dataUrl
                case .file(let dataUrl, let name, _, let thumbnail, let durationSec):
                    input.fileUrl = dataUrl; input.fileName = name; input.fileThumbnailUrl = thumbnail; input.fileDurationSec = durationSec
                case nil: break
                }
                _ = try await client.chat.sendMessage(conversationId, input)
                replyTo = nil
            }
        } catch {
            // The optimistic bubble already shows Retry/Discard; keep the box empty to avoid a
            // double send, but say why.
            self.error = error.localizedDescription
            if editing != nil { text = draft }
            pendingAttachment = attachment
        }
    }

    // MARK: - Picking

    private enum PendingAttachment: Equatable {
        case image(dataUrl: String)
        case file(dataUrl: String, name: String, mime: String, thumbnail: String?, durationSec: Int?)
    }

    private func loadPickedPhoto(_ item: PhotosPickerItem) async {
        defer { photoItem = nil }
        let isVideo = item.supportedContentTypes.contains { $0.conforms(to: .movie) }
        loadingAttachment = true
        defer { loadingAttachment = false }
        if isVideo {
            guard let data = try? await item.loadTransferable(type: Data.self) else { error = "Couldn't load that video."; return }
            let contentType = item.supportedContentTypes.first { $0.conforms(to: .movie) }
            await attachVideoData(data, contentType: contentType)
            return
        }
        guard let data = try? await item.loadTransferable(type: Data.self) else { error = "Couldn't load that photo."; return }
        await attachImageData(data, mime: item.supportedContentTypes.first?.preferredMIMEType ?? "image/jpeg")
    }

    #if os(iOS)
    private func attachImage(_ image: UIImage) async {
        guard let data = image.jpegData(compressionQuality: 0.7) else { error = "Couldn't process that photo."; return }
        await attachImageData(data, mime: "image/jpeg")
    }
    #endif

    private func attachImageData(_ data: Data, mime: String) async {
        guard data.count <= maxImageBytes else { error = "Image too large — keep it under 1.8MB."; return }
        pendingAttachment = .image(dataUrl: "data:\(mime);base64,\(data.base64EncodedString())")
    }

    private func attachVideoData(_ data: Data, contentType: UTType?) async {
        guard data.count <= maxAttachmentBytes else { error = "That video is too large (max ~9.5MB)."; return }
        let ext = contentType?.preferredFilenameExtension ?? "mov"
        let mime = contentType?.preferredMIMEType ?? "video/quicktime"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
        do { try data.write(to: tempURL) } catch { self.error = "Couldn't process that video."; return }
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let (thumbnail, durationSec) = await generateVideoThumbnail(url: tempURL)
        let fileName = "video_\(Int(Date().timeIntervalSince1970)).\(ext)"
        pendingAttachment = .file(dataUrl: "data:\(mime);base64,\(data.base64EncodedString())", name: fileName, mime: mime, thumbnail: thumbnail, durationSec: durationSec)
    }

    private func handlePickedFile(_ result: Result<URL, Error>) async {
        switch result {
        case .failure(let err):
            error = err.localizedDescription
        case .success(let url):
            guard url.startAccessingSecurityScopedResource() else { error = "Couldn't access that file."; return }
            defer { url.stopAccessingSecurityScopedResource() }
            loadingAttachment = true
            defer { loadingAttachment = false }
            guard let data = try? Data(contentsOf: url) else { error = "Couldn't read that file."; return }
            guard data.count <= maxAttachmentBytes else { error = "That file is too large (max ~9.5MB)."; return }
            let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            let (thumbnail, durationSec): (String?, Int?) = mime.hasPrefix("video/") ? await generateVideoThumbnail(url: url) : (nil, nil)
            pendingAttachment = .file(dataUrl: "data:\(mime);base64,\(data.base64EncodedString())", name: url.lastPathComponent, mime: mime, thumbnail: thumbnail, durationSec: durationSec)
        }
    }

    /// A small JPEG frame + rounded duration, entirely client-side (this SDK never decodes video
    /// server-side either — see service/src/lib/mediaStorage.js's own comment on the same point).
    /// Best-effort: nil thumbnail/duration on any failure rather than blocking the send.
    private func generateVideoThumbnail(url: URL) async -> (thumbnailDataURL: String?, durationSec: Int?) {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 400, height: 400)
        let durationSec: Int?
        if let loaded = try? await asset.load(.duration) { durationSec = Int(CMTimeGetSeconds(loaded).rounded()) } else { durationSec = nil }
        do {
            let time = CMTime(seconds: 0.1, preferredTimescale: 600)
            let cgImage = try await generator.image(at: time).image
            #if os(iOS)
            guard let jpegData = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.6) else { return (nil, durationSec) }
            #else
            let rep = NSBitmapImageRep(cgImage: cgImage)
            guard let jpegData = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.6]) else { return (nil, durationSec) }
            #endif
            return ("data:image/jpeg;base64,\(jpegData.base64EncodedString())", durationSec)
        } catch {
            return (nil, durationSec)
        }
    }
}

#if os(iOS)
/// Thin UIImagePickerController wrapper for camera capture — the one attachment source that
/// genuinely needs a host-app permission (NSCameraUsageDescription). SwiftUI has no native camera
/// picker as of this SDK's minimum OS versions.
private struct CameraCapture: UIViewControllerRepresentable {
    let onCapture: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onCapture: onCapture) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onCapture: (UIImage?) -> Void
        init(onCapture: @escaping (UIImage?) -> Void) { self.onCapture = onCapture }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            onCapture(info[.originalImage] as? UIImage)
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { onCapture(nil) }
    }
}
#endif
