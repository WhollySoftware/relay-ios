import SwiftUI
import RelayCore
@preconcurrency import WebRTC

/// Full-screen call UI for outgoing/connecting/active/reconnecting (CallKit shows incoming on iOS;
/// on other platforms, or if you don't use CallKit, show `IncomingCallBanner`). Mount
/// `RelayCallOverlay` once at your root.
public struct RelayCallOverlay: View {
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
                    Text(message).font(.footnote).padding(10).background(.red.opacity(0.9)).foregroundStyle(.white).clipShape(RoundedRectangle(cornerRadius: 10))
                        .onTapGesture { center.errorMessage = nil }
                    Spacer()
                }.padding(.top, 12)
            }
        }
    }
}

public struct IncomingCallBanner: View {
    let center: CallCenter
    let call: CallCenter.ActiveCall
    public var body: some View {
        VStack {
            HStack(spacing: 12) {
                VStack(alignment: .leading) {
                    Text(call.peerName ?? call.peerId).bold()
                    Text("Incoming \(call.type.rawValue) call…").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { center.decline() } label: { Image(systemName: "xmark").padding(10).background(Circle().fill(.red)).foregroundStyle(.white) }.buttonStyle(.plain)
                Button { center.answer() } label: { Image(systemName: call.type == .video ? "video.fill" : "phone.fill").padding(10).background(Circle().fill(.green)).foregroundStyle(.white) }.buttonStyle(.plain)
            }
            .padding(12).background(.regularMaterial).clipShape(RoundedRectangle(cornerRadius: 16)).padding()
            Spacer()
        }
    }
}

public struct RelayCallView: View {
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
            Color.black.ignoresSafeArea()
            if showRemoteVideo, let remote = center.remoteVideoTrack {
                VideoRenderView(track: remote).ignoresSafeArea()
            } else {
                VStack(spacing: 14) {
                    Circle().fill(Color.gray.opacity(0.4)).frame(width: 110, height: 110)
                        .overlay(Text(String((call.peerName ?? call.peerId).prefix(2)).uppercased()).font(.largeTitle.bold()).foregroundStyle(.white))
                    Text(call.peerName ?? call.peerId).font(.title2.bold()).foregroundStyle(.white)
                    statusView
                }
            }
            VStack {
                HStack {
                    if !center.remoteMicEnabled {
                        HStack(spacing: 5) {
                            Image(systemName: "mic.slash.fill")
                            Text("Muted").font(.caption).fontWeight(.semibold)
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Capsule().fill(.black.opacity(0.45)))
                        .padding(.leading)
                    }
                    Spacer()
                }
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
                            VideoRenderView(track: local).opacity(center.cameraEnabled ? 1 : 0)
                            if !center.cameraEnabled {
                                VStack(spacing: 4) {
                                    Circle().fill(Color.gray.opacity(0.5)).frame(width: 36, height: 36)
                                        .overlay(Text(String((center.client.me?.displayName ?? "You").prefix(2)).uppercased()).font(.caption.bold()).foregroundStyle(.white))
                                    Text(center.client.me?.displayName ?? "You").font(.caption2.bold()).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                                }
                            }
                        }
                        .frame(width: 100, height: 150).background(Color(white: 0.12)).clipShape(RoundedRectangle(cornerRadius: 14)).padding()
                    }
                }
                HStack(spacing: 24) {
                    control(center.micEnabled ? "mic.fill" : "mic.slash.fill", on: center.micEnabled) { center.toggleMic() }
                    if call.type == .video { control(center.cameraEnabled ? "video.fill" : "video.slash.fill", on: center.cameraEnabled) { center.toggleCamera() } }
                    control(center.speakerEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill", on: !center.speakerEnabled) { center.toggleSpeaker() }
                    Button { center.hangUp() } label: { Image(systemName: "phone.down.fill").font(.title2).frame(width: 64, height: 64).background(Circle().fill(.red)).foregroundStyle(.white) }.buttonStyle(.plain)
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

    private func control(_ symbol: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.title2).frame(width: 64, height: 64)
                .background(Circle().fill(on ? Color.white.opacity(0.18) : Color.white))
                .foregroundStyle(on ? Color.white : Color.black)
        }.buttonStyle(.plain)
    }
}

#if os(iOS)
struct VideoRenderView: UIViewRepresentable {
    let track: RTCVideoTrack?
    func makeUIView(context: Context) -> RTCMTLVideoView { let v = RTCMTLVideoView(); v.videoContentMode = .scaleAspectFill; return v }
    func updateUIView(_ uiView: RTCMTLVideoView, context: Context) { track?.add(uiView) }
}
#else
struct VideoRenderView: NSViewRepresentable {
    let track: RTCVideoTrack?
    func makeNSView(context: Context) -> RTCMTLNSVideoView { RTCMTLNSVideoView() }
    func updateNSView(_ nsView: RTCMTLNSVideoView, context: Context) { track?.add(nsView) }
}
#endif
