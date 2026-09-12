import SwiftUI

/// Every SF Symbol used by RelayUI/RelayCall's views. Override any of them and inject with
/// `.relayIcons(...)`; every default below is today's actual hardcoded `Image(systemName:)`
/// literal (verified against each of the 34 real call sites across RelayUI+RelayCall — not
/// invented), so an unmodified host sees a pixel-identical app. Lives in RelayCore (rather than
/// RelayUI) so RelayCall — which doesn't depend on RelayUI — can read it too, same reasoning as
/// `RelayTheme`.
public struct RelayIcons: Sendable {
    // MARK: Call controls (RelayCallView, GroupCallView, IncomingCallBanner, PermissionBanner)
    public var micOn = Image(systemName: "mic.fill")
    public var micOff = Image(systemName: "mic.slash.fill")
    public var cameraOn = Image(systemName: "video.fill")
    public var cameraOff = Image(systemName: "video.slash.fill")
    public var speakerOn = Image(systemName: "speaker.wave.2.fill")
    public var speakerOff = Image(systemName: "speaker.slash.fill")
    /// Answer button when the call is audio-only (a video call's answer button reuses `cameraOn`,
    /// matching `IncomingCallBanner`'s actual `call.type == .video ? "video.fill" : "phone.fill"`).
    public var callAnswer = Image(systemName: "phone.fill")
    /// `IncomingCallBanner`'s decline button — a plain "xmark" in the real UI today, not the
    /// "phone.down.fill" the illustrative sketch guessed.
    public var callDecline = Image(systemName: "xmark")
    /// Hang-up, in both 1:1 and group calls.
    public var callEnd = Image(systemName: "phone.down.fill")
    /// `PermissionBanner`'s mic/camera-denied warning triangle.
    public var callWarning = Image(systemName: "exclamationmark.triangle.fill")

    // MARK: Composer & attachments (MessageComposerView, MessageBubbleView, MediaGalleryView)
    public var attach = Image(systemName: "paperclip")
    /// Composer send button (editing == nil case).
    public var send = Image(systemName: "arrow.up.circle.fill")
    /// A generic filled-circle confirm/save action — the composer's save-edit button today.
    public var confirm = Image(systemName: "checkmark.circle.fill")
    /// A generic, chrome-less cancel — link-preview dismiss and the group-call expanded-tile
    /// collapse button today.
    public var dismiss = Image(systemName: "xmark")
    /// A circled-x remove/cancel affordance — reply/edit banner cancel, attachment-preview
    /// remove, and the "add participants" selected-chip remove button today.
    public var close = Image(systemName: "xmark.circle.fill")
    public var document = Image(systemName: "doc.fill")
    public var pdfDocument = Image(systemName: "doc.richtext.fill")
    /// Small "this tile is a video" play badge (media gallery thumbnails).
    public var playFilled = Image(systemName: "play.fill")
    /// Larger centered play glyph over a video attachment in a message bubble.
    public var playCircle = Image(systemName: "play.circle.fill")
    /// Message-bubble "sending…" clock.
    public var sending = Image(systemName: "clock")
    /// Voice-message row icon in the media gallery's Docs tab.
    public var voiceMessage = Image(systemName: "mic.fill")

    // MARK: Message receipts (MessageBubbleView)
    public var checkSent = Image(systemName: "checkmark")
    /// Rendered twice, WhatsApp-style, for a seen/read receipt.
    public var checkRead = Image(systemName: "checkmark")

    // MARK: Selection & lists (AddParticipantsView)
    public var selected = Image(systemName: "checkmark.circle.fill")
    public var unselected = Image(systemName: "circle")
    public var search = Image(systemName: "magnifyingglass")
    public var personQuestion = Image(systemName: "person.crop.circle.badge.questionmark")

    // MARK: Group management (GroupDetailView)
    public var addPeople = Image(systemName: "plus")
    public var editPhoto = Image(systemName: "pencil.circle.fill")
    public var photo = Image(systemName: "photo.on.rectangle")
    public var muteNotifications = Image(systemName: "bell.slash")
    public var delete = Image(systemName: "trash")
    public var leaveGroup = Image(systemName: "rectangle.portrait.and.arrow.right")

    public init() {}
}

private struct RelayIconsKey: EnvironmentKey {
    static let defaultValue = RelayIcons()
}

public extension EnvironmentValues {
    var relayIcons: RelayIcons {
        get { self[RelayIconsKey.self] }
        set { self[RelayIconsKey.self] = newValue }
    }
}

public extension View {
    func relayIcons(_ icons: RelayIcons) -> some View { environment(\.relayIcons, icons) }
}
