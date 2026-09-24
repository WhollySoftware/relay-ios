import SwiftUI
import RelayCore
@preconcurrency import WebRTC
#if os(iOS)
import UIKit
#endif

/// Full-screen call UI for outgoing/connecting/active/reconnecting (CallKit shows incoming on iOS;
/// on other platforms, or if you don't use CallKit, show `IncomingCallBanner`). Mount
/// `RelayCallOverlay` once at your root.
public struct RelayCallOverlay: View {
    @Environment(\.relayTheme) private var theme
    let center: CallCenter
    public init(center: CallCenter) { self.center = center }
    public var body: some View {
        ZStack {
            if let call = center.call {
                if call.isGroup && call.phase != .incoming {
                    GroupCallView(center: center, call: call).transition(.opacity)
                } else if call.phase == .incoming {
                    // CallKit shows the incoming call natively on iOS. On a device/region where
                    // CallKit reporting fails (the Simulator, or China-region builds — CallKit is
                    // disallowed there by App Store guidelines), CallCenter sets
                    // `callKitUnavailable` and falls back to a local notification; this banner is
                    // the in-app half of that fallback so the call still has a visible affordance.
                    #if !os(iOS)
                    IncomingCallBanner(center: center, call: call)
                    #else
                    if center.callKitUnavailable {
                        IncomingCallBanner(center: center, call: call)
                    }
                    #endif
                } else {
                    RelayCallView(center: center, call: call).transition(.opacity)
                }
            }
            if let message = center.errorMessage {
                VStack {
                    Text(message).font(.footnote).padding(10).background(theme.danger.opacity(0.9)).foregroundStyle(theme.accentForeground).clipShape(RoundedRectangle(cornerRadius: 10))
                        .onTapGesture { center.errorMessage = nil }
                    Spacer()
                }.padding(.top, 12)
            }
        }
        .relayTypography(theme)
        // Whatever put a call on screen — a call button, a host calling center.start(), or a ring
        // arriving mid-typing — the keyboard must go first: left up, it hides the incoming banner's
        // Answer/Decline row and pushes the in-call controls off the bottom. Keyed on the call id so
        // it fires once per call, not on every phase change.
        .onChange(of: center.call?.id, initial: true) { _, id in
            if id != nil { dismissKeyboard() }
        }
    }

    private func dismissKeyboard() {
        #if os(iOS)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #else
        NSApp.keyWindow?.makeFirstResponder(nil)
        #endif
    }
}

/// Persistent, non-blocking banner shown in-call when the mic/camera couldn't be captured because
/// the OS permission isn't granted — the call still connects and the other side is still fully
/// audible/visible to this device, but this device is silently sending nothing. Doesn't block the
/// call controls; just a dismiss-free hint with a shortcut to Settings.
struct PermissionBanner: View {
    @Environment(\.relayTheme) private var theme
    @Environment(\.relayIcons) private var icons
    let micDenied: Bool
    let cameraDenied: Bool

    private var message: String {
        switch (micDenied, cameraDenied) {
        case (true, true): return "Microphone/camera access needed — you can hear/see the other person, but they can't hear/see you."
        case (true, false): return "Microphone access needed — you can hear the other person, but they can't hear you."
        case (false, true): return "Camera access needed — you can see the other person, but they can't see you."
        case (false, false): return ""
        }
    }

    var body: some View {
        if micDenied || cameraDenied {
            HStack(spacing: 10) {
                icons.callWarning.foregroundStyle(.yellow)
                Text(message).font(.caption).foregroundStyle(.white)
                Spacer(minLength: 8)
                #if os(iOS)
                Button("Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .font(.caption.bold())
                .buttonStyle(.plain)
                .foregroundStyle(.yellow)
                #endif
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(theme.callScrimStart.opacity(0.55))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal)
        }
    }
}

public struct IncomingCallBanner: View {
    @Environment(\.relayTheme) private var theme
    @Environment(\.relayIcons) private var icons
    let center: CallCenter
    let call: CallCenter.ActiveCall
    public var body: some View {
        VStack {
            HStack(spacing: 12) {
                VStack(alignment: .leading) {
                    Text(call.peerName ?? call.peerId).bold()
                    Text("Incoming \(call.type.rawValue) call…").font(.caption).foregroundStyle(theme.secondaryText)
                }
                Spacer()
                Button { center.decline() } label: { icons.callDecline.padding(10).background(Circle().fill(theme.danger)).foregroundStyle(theme.accentForeground) }.buttonStyle(.plain)
                Button { center.answer() } label: { (call.type == .video ? icons.cameraOn : icons.callAnswer).padding(10).background(Circle().fill(theme.online)).foregroundStyle(theme.accentForeground) }.buttonStyle(.plain)
            }
            .padding(12).background(.regularMaterial).clipShape(RoundedRectangle(cornerRadius: 16)).padding()
            Spacer()
        }
        .relayTypography(theme)
    }
}

public struct RelayCallView: View {
    @Environment(\.relayTheme) private var theme
    @Environment(\.relayIcons) private var icons
    let center: CallCenter
    let call: CallCenter.ActiveCall
    public init(center: CallCenter, call: CallCenter.ActiveCall) { self.center = center; self.call = call }

    private var status: String {
        switch call.phase {
        case .outgoing: return "Calling…"
        case .connecting: return "Connecting…"
        case .reconnecting: return "Reconnecting…"
        case .incoming: return ""
        case .active: return ""
        }
    }

    // A disabled remote camera still sends frames (all black), so the video-vs-avatar decision
    // uses remoteCameraEnabled, not just "is there a remote track".
    private var showRemoteVideo: Bool { call.type == .video && center.remoteVideoTrack != nil && center.remoteCameraEnabled }

    public var body: some View {
        ZStack {
            theme.callScrimStart.ignoresSafeArea()
            if showRemoteVideo, let remote = center.remoteVideoTrack {
                RelayVideoView(track: remote).ignoresSafeArea()
            } else {
                VStack(spacing: 14) {
                    Circle().fill(Color(hue: avatarHue(for: call.peerId), saturation: theme.avatarSaturation, brightness: theme.avatarLightness)).frame(width: 110, height: 110)
                        .overlay(Text(String((call.peerName ?? call.peerId).prefix(2)).uppercased()).font(.largeTitle.bold()).foregroundStyle(.white))
                    Text(call.peerName ?? call.peerId).font(.title2.bold()).foregroundStyle(.white)
                    statusView
                }
            }
            VStack {
                HStack {
                    if !center.remoteMicEnabled {
                        HStack(spacing: 5) {
                            icons.micOff
                            Text("Muted").font(.caption).fontWeight(.semibold)
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Capsule().fill(theme.callScrimStart.opacity(0.45)))
                        .padding(.leading)
                    }
                    Spacer()
                }
                PermissionBanner(micDenied: center.localMicPermissionDenied, cameraDenied: call.type == .video && center.localCameraPermissionDenied)
                    .padding(.top, 6)
                if showRemoteVideo { statusView.padding(.top, 8) }
                Spacer()
                // The renderer stays mounted (not conditionally) when the camera is off, so its
                // track assignment survives the toggle — only the overlay changes. Without this
                // the box shows a stale black frame instead of your own avatar when you turn your
                // camera off mid-call.
                if call.type == .video, let local = center.localVideoTrack {
                    HStack {
                        Spacer()
                        ZStack {
                            RelayVideoView(track: local).opacity(center.cameraEnabled ? 1 : 0)
                            if !center.cameraEnabled {
                                VStack(spacing: 4) {
                                    Circle().fill(Color(hue: avatarHue(for: center.client.userId ?? "you"), saturation: theme.avatarSaturation, brightness: theme.avatarLightness)).frame(width: 36, height: 36)
                                        .overlay(Text(String((center.client.me?.displayName ?? "You").prefix(2)).uppercased()).font(.caption.bold()).foregroundStyle(.white))
                                    Text(center.client.me?.displayName ?? "You").font(.caption2.bold()).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                                }
                            }
                        }
                        .frame(width: 100, height: 150).background(theme.callScrimEnd).clipShape(RoundedRectangle(cornerRadius: 14)).padding()
                    }
                }
                HStack(spacing: 24) {
                    control(center.micEnabled ? icons.micOn : icons.micOff, on: center.micEnabled) { center.toggleMic() }
                    if call.type == .video { control(center.cameraEnabled ? icons.cameraOn : icons.cameraOff, on: center.cameraEnabled) { center.toggleCamera() } }
                    control(center.speakerEnabled ? icons.speakerOn : icons.speakerOff, on: !center.speakerEnabled) { center.toggleSpeaker() }
                    Button { center.hangUp() } label: { icons.callEnd.font(.title2).frame(width: 64, height: 64).background(Circle().fill(theme.danger)).foregroundStyle(theme.accentForeground) }.buttonStyle(.plain)
                }
                .padding(.bottom, 40)
            }
        }
    }

    @ViewBuilder private var statusView: some View {
        if call.phase == .active, let started = call.startedAt {
            TimelineView(.periodic(from: started, by: 1)) { ctx in
                let s = max(0, Int(ctx.date.timeIntervalSince(started)))
                Text(String(format: "%02d:%02d", s / 60, s % 60)).monospacedDigit().foregroundStyle(.white.opacity(0.75))
            }
        } else {
            Text(status).foregroundStyle(call.phase == .reconnecting ? .yellow : .white.opacity(0.75))
        }
    }

    // `on` here means "not the highlighted/active toggle state" (see call sites) — this is a
    // neutral light/dark control chrome over video, not a brand color, so it stays plain
    // white/black rather than reading from the theme.
    private func control(_ icon: Image, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            icon.font(.title2).frame(width: 64, height: 64)
                .background(Circle().fill(on ? Color.white.opacity(0.18) : Color.white))
                .foregroundStyle(on ? Color.white : Color.black)
        }.buttonStyle(.plain)
    }
}

/// Stable per-key hue for a fallback call avatar — mirrors `RelayFormat.hue(for:)` in RelayUI
/// (duplicated rather than shared, since RelayCall intentionally doesn't depend on RelayUI).
func avatarHue(for key: String) -> Double {
    var h: UInt32 = 0
    for u in key.utf8 { h = h &* 31 &+ UInt32(u) }
    return Double(h % 360) / 360
}

/// Renders a WebRTC video track — the same view `RelayCallView`/`GroupCallView` use for both local
/// preview and remote video. Public so a fully custom call UI (see "Headless calling" in the
/// package README) never has to reimplement WebRTC video rendering itself: pass
/// `center.remoteVideoTrack` / `center.localVideoTrack` straight in. A `nil` track renders as an
/// empty view — callers typically show their own avatar/placeholder instead in that case (see
/// `RelayCallView`'s `showRemoteVideo` check for the pattern: don't mount this at all until there's
/// a track and the peer's camera is actually enabled).
#if os(iOS)
public struct RelayVideoView: UIViewRepresentable {
    let track: RTCVideoTrack?
    public init(track: RTCVideoTrack?) { self.track = track }
    public func makeUIView(context: Context) -> RTCMTLVideoView { let v = RTCMTLVideoView(); v.videoContentMode = .scaleAspectFill; return v }
    public func updateUIView(_ uiView: RTCMTLVideoView, context: Context) { track?.add(uiView) }
}
#else
public struct RelayVideoView: NSViewRepresentable {
    let track: RTCVideoTrack?
    public init(track: RTCVideoTrack?) { self.track = track }
    public func makeNSView(context: Context) -> RTCMTLNSVideoView { RTCMTLNSVideoView() }
    public func updateNSView(_ nsView: RTCMTLNSVideoView, context: Context) { track?.add(nsView) }
}
#endif
