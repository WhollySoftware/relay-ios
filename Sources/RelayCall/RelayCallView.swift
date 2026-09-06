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
                if call.phase == .incoming {
                    #if !os(iOS)
                    IncomingCallBanner(center: center, call: call)
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

    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if call.type == .video, let remote = center.remoteVideoTrack {
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
                if call.type == .video, center.remoteVideoTrack != nil { statusView.padding(.top, 8) }
                Spacer()
                if call.type == .video, let local = center.localVideoTrack {
                    HStack { Spacer(); VideoRenderView(track: local).frame(width: 100, height: 150).clipShape(RoundedRectangle(cornerRadius: 14)).padding() }
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
