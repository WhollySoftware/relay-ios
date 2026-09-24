import SwiftUI
import RelayCore
@preconcurrency import WebRTC

/// Group (mesh) call UI — one tile per entry in `remoteVideoTracks` plus a local preview, reusing
/// `RelayVideoView` from RelayCallView for consistency. Kept as its own view (rather than folding
/// isGroup branches into RelayCallView's body) so the 1:1 layout stays exactly as it was.
struct GroupCallView: View {
    @Environment(\.relayTheme) private var theme
    @Environment(\.relayIcons) private var icons
    let center: CallCenter
    let call: CallCenter.ActiveCall

    /// Tapping a tile expands it full-screen; tapping the exit button returns to the grid. `nil`
    /// means "showing the grid."
    private enum ExpandedTile: Equatable { case remote(String); case local }
    @State private var expanded: ExpandedTile?

    private var status: String {
        switch call.phase {
        case .outgoing: return "Calling…"
        case .connecting: return "Connecting…"
        case .reconnecting: return "Reconnecting…"
        case .incoming, .active: return ""
        }
    }

    /// Everyone on the call arranged in balanced rows (your own tile — `nil` — included last): 2
    /// stacks top/bottom, 3 is 2-over-1, 4 is 2-and-2, 5 is 3-over-2, and 6 (the group-call cap) is
    /// three rows of 2 rather than 2 rows of 3.
    private var rows: [[String?]] {
        let tileIds: [String?] = call.participantIds.filter { $0 != center.client.userId } + [nil]
        let sizes: [Int]
        switch tileIds.count {
        case 0: sizes = []
        case 1: sizes = [1]
        case 6: sizes = [2, 2, 2]
        default: sizes = [(tileIds.count + 1) / 2, tileIds.count / 2]
        }
        var result: [[String?]] = []
        var index = 0
        for size in sizes { result.append(Array(tileIds[index..<index + size])); index += size }
        return result
    }

    var body: some View {
        ZStack {
            theme.callScrimStart.ignoresSafeArea()
            VStack(spacing: 8) {
                statusView.padding(.top, 8)
                PermissionBanner(micDenied: center.localMicPermissionDenied, cameraDenied: call.type == .video && center.localCameraPermissionDenied)
                if let expanded, isStillOnCall(expanded) {
                    expandedView(expanded).padding(8)
                } else {
                    // Flexible frames (`maxHeight: .infinity`) on nested VStack/HStack rows don't
                    // reliably split space evenly here, so every tile's exact pixel size is
                    // computed directly from the available geometry instead of left to stack
                    // auto-sizing.
                    GeometryReader { geo in
                        let rowGaps = CGFloat(max(0, rows.count - 1)) * 8
                        let rowHeight = rows.isEmpty ? 0 : (geo.size.height - rowGaps) / CGFloat(rows.count)
                        VStack(spacing: 8) {
                            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                                let colGaps = CGFloat(max(0, row.count - 1)) * 8
                                let colWidth = row.isEmpty ? 0 : (geo.size.width - colGaps) / CGFloat(row.count)
                                HStack(spacing: 8) {
                                    ForEach(Array(row.enumerated()), id: \.offset) { _, userId in
                                        cell(for: userId)
                                            .frame(width: colWidth, height: rowHeight)
                                            .contentShape(Rectangle())
                                            .onTapGesture { expanded = userId.map(ExpandedTile.remote) ?? .local }
                                    }
                                }
                            }
                        }
                        // GeometryReader has no intrinsic size of its own to report, so a plain
                        // VStack parent gives it zero/minimal height unless it's explicitly marked
                        // as flexible.
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .padding(8)
                }
            }
            VStack {
                Spacer()
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

    /// False once the expanded participant has left the call — falls back to the grid instead of
    /// showing a frozen tile for someone no longer on it.
    private func isStillOnCall(_ tile: ExpandedTile) -> Bool {
        switch tile {
        case .local: return true
        case .remote(let id): return call.participantIds.contains(id) && id != center.client.userId
        }
    }

    @ViewBuilder private func expandedView(_ tile: ExpandedTile) -> some View {
        Group {
            switch tile {
            case .local: localTile
            case .remote(let id): self.tile(for: id)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Top-leading, not trailing — a remote tile's own per-participant mute button
        // (tile(for:)) already occupies top-trailing and would otherwise sit right under this.
        .overlay(alignment: .topLeading) {
            Button { expanded = nil } label: {
                icons.dismiss.font(.headline).foregroundStyle(.white)
                    .padding(10).background(Circle().fill(theme.callScrimStart.opacity(0.5)))
            }
            .buttonStyle(.plain)
            .padding(12)
        }
    }

    @ViewBuilder private func cell(for userId: String?) -> some View {
        if let userId { tile(for: userId) } else { localTile }
    }

    @ViewBuilder private func tile(for userId: String) -> some View {
        let track = center.remoteVideoTracks[userId]
        let cameraOn = center.remoteCameraEnabledByUser[userId] ?? true
        let micOn = center.remoteMicEnabledByUser[userId] ?? true
        let locallyMuted = center.locallyMutedUsers.contains(userId)
        Group {
            if let track, call.type == .video, cameraOn {
                RelayVideoView(track: track)
            } else {
                theme.callScrimEnd.overlay {
                    Circle().fill(Color(hue: avatarHue(for: userId), saturation: theme.avatarSaturation, brightness: theme.avatarLightness)).frame(width: 56, height: 56)
                        .overlay(Text(String(userId.prefix(2)).uppercased()).font(.headline.bold()).foregroundStyle(.white))
                }
            }
        }
        .overlay(alignment: .bottomLeading) { nameBadge(userId, muted: !micOn) }
        .overlay(alignment: .topTrailing) {
            // Local-only "don't let me hear this person" toggle — never sent over the wire.
            Button { center.toggleLocalMute(for: userId) } label: {
                (locallyMuted ? icons.speakerOff : icons.speakerOn)
                    .font(.caption).foregroundStyle(.white)
                    .padding(6).background(Circle().fill(theme.callScrimStart.opacity(0.5)))
            }
            .buttonStyle(.plain)
            .padding(6)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder private var localTile: some View {
        Group {
            // Permission-denied can still produce a (silent, frameless) local track on some
            // devices, which would otherwise render as a blank black rectangle instead of falling
            // back to the avatar — so this checks the permission flag too, not just "is there a
            // track."
            if call.type == .video, let local = center.localVideoTrack, center.cameraEnabled, !center.localCameraPermissionDenied {
                RelayVideoView(track: local)
            } else {
                theme.callScrimEnd.overlay {
                    Circle().fill(Color(hue: avatarHue(for: center.client.userId ?? "you"), saturation: theme.avatarSaturation, brightness: theme.avatarLightness)).frame(width: 40, height: 40)
                        .overlay(Text(String((center.client.me?.displayName ?? "You").prefix(2)).uppercased()).font(.caption.bold()).foregroundStyle(.white))
                }
            }
        }
        .overlay(alignment: .bottomLeading) { nameBadge(center.client.me?.displayName ?? "You", muted: !center.micEnabled) }
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func nameBadge(_ name: String, muted: Bool) -> some View {
        HStack(spacing: 4) {
            if muted { icons.micOff.font(.system(size: 10)) }
            Text(name).font(.caption2.bold()).lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Capsule().fill(theme.callScrimStart.opacity(0.45)))
        .padding(8)
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

    // Neutral light/dark control chrome over video (not a brand color) — see the matching note
    // in RelayCallView.control(_:on:action:).
    private func control(_ icon: Image, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            icon.font(.title2).frame(width: 64, height: 64)
                .background(Circle().fill(on ? Color.white.opacity(0.18) : Color.white))
                .foregroundStyle(on ? Color.white : Color.black)
        }.buttonStyle(.plain)
    }
}
