import SwiftUI
import RelayCore
@preconcurrency import WebRTC

/// Group (mesh) call UI — one tile per entry in `remoteVideoTracks` plus a local preview, reusing
/// `VideoRenderView` from RelayCallView for consistency. Kept as its own view (rather than folding
/// isGroup branches into RelayCallView's body) so the 1:1 layout stays exactly as it was.
struct GroupCallView: View {
    let center: CallCenter
    let call: CallCenter.ActiveCall

    private var status: String {
        switch call.phase {
        case .outgoing: return "Calling…"
        case .connecting: return "Connecting…"
        case .reconnecting: return "Reconnecting…"
        case .incoming, .active: return ""
        }
    }

    private let columns = [GridItem(.adaptive(minimum: 140), spacing: 8)]

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 8) {
                statusView.padding(.top, 8)
                PermissionBanner(micDenied: center.localMicPermissionDenied, cameraDenied: call.type == .video && center.localCameraPermissionDenied)
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(call.participantIds.filter { $0 != center.client.userId }, id: \.self) { userId in
                            tile(for: userId)
                        }
                        localTile
                    }
                    .padding(8)
                }
            }
            VStack {
                Spacer()
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

    @ViewBuilder private func tile(for userId: String) -> some View {
        let track = center.remoteVideoTracks[userId]
        let cameraOn = center.remoteCameraEnabledByUser[userId] ?? true
        let micOn = center.remoteMicEnabledByUser[userId] ?? true
        ZStack(alignment: .bottomLeading) {
            if let track, call.type == .video, cameraOn {
                VideoRenderView(track: track)
            } else {
                Color(white: 0.12)
                Circle().fill(Color.gray.opacity(0.4)).frame(width: 56, height: 56)
                    .overlay(Text(String(userId.prefix(2)).uppercased()).font(.headline.bold()).foregroundStyle(.white))
            }
            if !micOn {
                Image(systemName: "mic.slash.fill").foregroundStyle(.white)
                    .padding(6).background(Circle().fill(.black.opacity(0.5))).padding(6)
            }
        }
        .aspectRatio(1, contentMode: .fill)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder private var localTile: some View {
        ZStack {
            if call.type == .video, let local = center.localVideoTrack, center.cameraEnabled {
                VideoRenderView(track: local)
            } else {
                Color(white: 0.18)
                VStack(spacing: 4) {
                    Circle().fill(Color.gray.opacity(0.5)).frame(width: 40, height: 40)
                        .overlay(Text(String((center.client.me?.displayName ?? "You").prefix(2)).uppercased()).font(.caption.bold()).foregroundStyle(.white))
                    Text(center.client.me?.displayName ?? "You").font(.caption2.bold()).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                }
            }
        }
        .aspectRatio(1, contentMode: .fill)
        .clipShape(RoundedRectangle(cornerRadius: 12))
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
