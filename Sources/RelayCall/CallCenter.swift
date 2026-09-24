import AVFoundation
import Foundation
import Observation
import RelayCore
@preconcurrency import WebRTC
#if canImport(CallKit) && os(iOS)
import CallKit
#endif
#if canImport(UserNotifications) && os(iOS)
import UserNotifications
#endif

/// 1:1 call state machine — the DevBattel CallCoordinator with its later fixes, as an SDK:
/// one call at a time, events validated against the current callId, ownership re-checked after
/// every await, ICE restart with a "reconnecting" grace period, and (on iOS) CallKit for the
/// native incoming UI, audio-session activation and lock-screen controls.
///
///     let calls = CallCenter(client: relay)          // once per RelayClient
///     calls.start(conversation: convo, type: .video)
///     // observe calls.call / calls.remoteVideoTrack in SwiftUI (RelayCallView does this)
@MainActor
@Observable
public final class CallCenter: NSObject {
    public enum Phase: Equatable { case outgoing, incoming, connecting, active, reconnecting }

    public struct ActiveCall: Identifiable, Equatable {
        public let id: String
        public let uuid: UUID
        public let conversationId: ConversationId
        public let peerId: UserId
        public let peerName: String?
        public let type: CallType
        public var phase: Phase
        public var startedAt: Date?
        /// False for every existing 1:1 call site (default keeps that path unchanged).
        public var isGroup: Bool = false
        /// Currently-known participants (including self) for a group call; empty for 1:1 — use
        /// `peerId` there instead.
        public var participantIds: [UserId] = []
    }

    public private(set) var call: ActiveCall?
    public private(set) var localVideoTrack: RTCVideoTrack?
    /// 1:1-only — populated exactly as before. A group call uses `remoteVideoTracks` instead.
    public private(set) var remoteVideoTrack: RTCVideoTrack?
    /// Group-only, keyed by participant userId. Empty for a 1:1 call — use `remoteVideoTrack`.
    public private(set) var remoteVideoTracks: [UserId: RTCVideoTrack] = [:]
    public private(set) var micEnabled = true
    public private(set) var cameraEnabled = true
    public private(set) var speakerEnabled = false
    /// The PEER's reported mic/camera state (call_media_state) — a disabled camera still sends
    /// frames (all black), so the UI uses this rather than "is there a remote track" to decide
    /// when to show the peer's avatar instead of a black rectangle. 1:1-only; see the
    /// `...ByUser` dictionaries below for a group call.
    public private(set) var remoteMicEnabled = true
    public private(set) var remoteCameraEnabled = true
    /// Group-only, keyed by participant userId; defaults (true/true) apply until told otherwise,
    /// matching the 1:1 scalars above.
    public private(set) var remoteMicEnabledByUser: [UserId: Bool] = [:]
    public private(set) var remoteCameraEnabledByUser: [UserId: Bool] = [:]
    /// Group-only: participants whose incoming audio THIS device has locally silenced — a
    /// listener-side preference (e.g. "I don't want to hear C") that never reaches the network, so
    /// nobody else's call is affected and it resets when the call ends.
    public private(set) var locallyMutedUsers: Set<UserId> = []
    public func toggleLocalMute(for userId: UserId) {
        let muted = !locallyMutedUsers.contains(userId)
        if muted { locallyMutedUsers.insert(userId) } else { locallyMutedUsers.remove(userId) }
        peers[userId]?.setLocalMute(muted)
    }
    public var errorMessage: String?
    /// The underlying WebRTC state at the moment a call failed — e.g. "peer connection: failed,
    /// ice: disconnected". `errorMessage` stays a short user-facing string on purpose; this is the
    /// detail to log or show in your own debug UI when a call fails and you need to tell "expected
    /// network/Simulator limitation" apart from "something actually broke". Not localized, not
    /// meant for end users. Cleared at the start of every call.
    public private(set) var lastFailureDetail: String?
    /// True when the mic is not authorized (denied/restricted, or not-yet-determined and then
    /// denied when we prompted). Computed once, right around call start/answer — no live
    /// permission-change observer. The call proceeds regardless (WebRTC/AVFoundation just
    /// captures silence for a denied mic); this only drives the in-call banner so the local user
    /// knows the other side can't hear them.
    public private(set) var localMicPermissionDenied = false
    /// Same as `localMicPermissionDenied`, but for the camera — only meaningful for video calls.
    public private(set) var localCameraPermissionDenied = false
    /// Shown by CallKit for outgoing calls and as a fallback name; set your app's display name.
    public var localizedAppName = "Call"
    /// True once CallKit has been observed to reject a call on this device (the Simulator, or a
    /// China-region build — Apple's App Store guidelines there disallow CallKit — or any other
    /// device where `CX*` reporting errors out). Persisted to `UserDefaults` (key below) so this
    /// discovery survives relaunches too — on a device where CallKit is structurally unavailable
    /// (Simulator, China-region build) it will fail on every launch, and without persisting the
    /// finding, the first real incoming call after every cold start would be sacrificed re-probing
    /// a failure we already know about instead of just showing the banner. `RelayCallOverlay` shows
    /// `IncomingCallBanner` on iOS when this is true.
    // Stored (not computed) so @Observable tracks it and RelayCallOverlay re-renders the instant
    // it flips — init() seeds it from UserDefaults and markCallKitUnavailable() keeps both in sync.
    public private(set) var callKitUnavailable = false
    private static let callKitUnavailableKey = "dev.relay.call.callKitUnavailable"
    private func markCallKitUnavailable() {
        guard !callKitUnavailable else { return }
        callKitUnavailable = true
        UserDefaults.standard.set(true, forKey: Self.callKitUnavailableKey)
    }

    let client: RelayClient
    /// One RTCPeerConnection per remote participant, keyed by their userId. A 1:1 call has exactly
    /// one entry (keyed by `call.peerId`).
    private var peers: [UserId: PeerConnectionManager] = [:]
    /// The call's one shared mic/camera capture, handed to every entry in `peers`.
    private var localMedia: LocalMedia?
    /// 1:1-only convenience — the single entry of `peers`, exactly as `manager` behaved before
    /// group calls existed.
    private var manager: PeerConnectionManager? {
        get { call.flatMap { peers[$0.peerId] } }
        set { if let peerId = call?.peerId { peers[peerId] = newValue } }
    }
    private var pendingOffer: (callId: String, sdp: SDPPayload)?
    /// 1:1-only buffer, keyed by nothing (one peer) — same as before group calls existed.
    private var pendingCandidates: [(callId: String, candidate: ICECandidatePayload)] = []
    /// Group-only buffer: ICE candidates that arrived before their sender's PeerConnectionManager existed.
    private var pendingGroupCandidates: [UserId: [(callId: String, candidate: ICECandidatePayload)]] = [:]
    private var pendingAcceptRecipient: UserId?
    // internal (not private) so RelayPush.swift's cancel-push handler can exclude the call this
    // device is itself in the middle of answering — see its guard for why that matters.
    var answeringCallId: String?
    private var isStarting = false
    private var ringTask: Task<Void, Never>?
    private var connectTask: Task<Void, Never>?
    private var graceTask: Task<Void, Never>?
    private var restartTask: Task<Void, Never>?
    private var unsubscribe: (() -> Void)?

    private static let ringTimeout: UInt64 = 45
    private static let connectTimeout: UInt64 = 25
    private static let reconnectGrace: UInt64 = 20

    #if canImport(CallKit) && os(iOS)
    private let provider: CXProvider
    private let controller = CXCallController()
    // Set right after `reportNewIncomingCall`/`CXStartCallAction` succeeds. A CXEndCallAction for
    // that same call arriving within `Self.callKitProbeWindow` — before any human could plausibly
    // have declined/hung up — means CallKit itself is silently killing a call it just accepted
    // (observed on the Simulator; also expected on China-region builds, where CallKit is
    // disallowed by App Store guidelines). That's the signal `callKitUnavailable` is watching for.
    private var callKitReportedAt: (uuid: UUID, at: Date)?
    private static let callKitProbeWindow: TimeInterval = 2.5
    #endif

    public init(client: RelayClient, supportsVideo: Bool = true) {
        self.client = client
        #if canImport(CallKit) && os(iOS)
        callKitUnavailable = UserDefaults.standard.bool(forKey: Self.callKitUnavailableKey)
        let config = CXProviderConfiguration()
        config.supportsVideo = supportsVideo
        config.maximumCallGroups = 1
        config.maximumCallsPerCallGroup = 1
        config.supportedHandleTypes = [.generic]
        #if DEBUG
        // Debug builds point at a ringtone filename that doesn't exist in the bundle — CallKit
        // silently skips playback instead of erroring, so the native call UI still works exactly
        // as in production (answer/decline, lock-screen call, CallKit history), it just doesn't
        // audibly ring while iterating locally. Release builds leave this nil (system default).
        config.ringtoneSound = "relay-call-silent-debug-only.caf"
        #endif
        provider = CXProvider(configuration: config)
        #endif
        super.init()
        #if canImport(CallKit) && os(iOS)
        provider.setDelegate(self, queue: nil)
        RTCAudioSession.sharedInstance().useManualAudio = true
        RTCAudioSession.sharedInstance().isAudioEnabled = false
        #endif
        unsubscribe = client.onEvent { [weak self] event in
            guard case .unknown(_, let payload) = event, let callEvent = CallEvent.decode(payload) else { return }
            self?.handle(callEvent)
        }
    }

    /// Stop listening to the client (call from your own teardown; the listener holds `self` weakly).
    public func detach() { unsubscribe?(); unsubscribe = nil }

    private var myUserId: UserId? { client.userId }

    // MARK: - Outgoing

    /// Starts a call. `RelayCall` has no SDK-owned button for this — host apps wire their own UI
    /// to this method (see `packages/ios/app-demo` for a reference implementation). This method
    /// does NOT pre-emptively check `client.modules.audioCalls`/`.videoCalls` before starting —
    /// if the relevant module is disabled for the project, the server call started below will
    /// simply fail (403 `module_disabled`). Host apps should check `client.modules.audioCalls` /
    /// `client.modules.videoCalls` before showing their own audio/video call buttons at all,
    /// exactly like `MessageComposerView` hides its attach button when `chatAttachments` is off.
    public func start(conversation: Conversation, type: CallType) {
        // A group conversation has no single `peer` — this used to be the (accidental) gate that
        // hid calling for group conversations entirely; deriving participantIds from the member
        // list here, up front, is what lets a group call start at all (mirrors web's start(),
        // which takes participants from the host rather than waiting on the server).
        guard call == nil, !isStarting else { return }
        let isGroup = conversation.isGroup
        let groupParticipantIds: [UserId] = isGroup ? [myUserId].compactMap { $0 } + conversation.members.map(\.userId) : []
        guard isGroup ? !groupParticipantIds.isEmpty : conversation.peer != nil else { return }
        let peer = conversation.peer
        isStarting = true
        Task {
            defer { isStarting = false }
            do {
                // Otherwise the caller sits at "Calling…" while the callee's side connects, times
                // out, and hangs up on a peer that never heard a thing over the socket — the
                // offer/ICE exchange rides the gateway, not this REST call. Idempotent/instant
                // when already connected.
                _ = try? await client.connect()
                let res = try await client.api.startCall(conversationId: conversation.id, type: type)
                let uuid = UUID()
                // POST /calls returns no participant list at all for a group call — participantIds
                // must come from the conversation's own member list, derived above.
                let displayPeerId = isGroup ? (myUserId ?? "") : (peer?.userId ?? "")
                lastFailureDetail = nil
                call = ActiveCall(id: res.callId, uuid: uuid, conversationId: conversation.id, peerId: isGroup ? displayPeerId : (peer?.userId ?? ""),
                                   peerName: isGroup ? conversation.title : peer?.displayName, type: type, phase: .outgoing,
                                   isGroup: isGroup, participantIds: isGroup ? groupParticipantIds : [peer?.userId ?? ""])
                debugLog(client.config, "call \(res.callId) ringing (outgoing)")
                reportOutgoingStarted(uuid: uuid, name: isGroup ? conversation.title : (peer?.displayName ?? peer?.userId ?? ""), video: type == .video)
                scheduleRing(callId: res.callId)
                if isGroup {
                    // Nobody to offer to yet — only the caller has joined so far. Peer connections
                    // form when someone else answers and offers to us (newest-joiner-initiates).
                    // Local media is still acquired eagerly so the caller's own preview works.
                    do {
                        await refreshLocalPermissionFlags(type: type)
                        guard call?.uuid == uuid else { return }
                        let media = LocalMedia(type: type)
                        guard call?.uuid == uuid else { media.close(); return }
                        #if !os(iOS)
                        PeerConnectionManager.configureAudioSession(video: type == .video)
                        #endif
                        localMedia = media
                        localVideoTrack = media.videoTrack
                        speakerEnabled = type == .video
                    }
                    return
                }
                let manager = makeManager(callId: res.callId, userId: peer!.userId)
                do {
                    await refreshLocalPermissionFlags(type: type)
                    guard call?.uuid == uuid else { manager.close(); return }
                    let media = LocalMedia(type: type)
                    let servers = await iceServers()
                    guard call?.uuid == uuid else { manager.close(); media.close(); return }
                    #if !os(iOS)
                    PeerConnectionManager.configureAudioSession(video: type == .video)
                    #endif
                    try manager.start(localMedia: media, iceServers: servers)
                    localMedia = media
                } catch {
                    manager.close()
                    guard call?.uuid == uuid else { return }
                    _ = try? await client.api.endCall(res.callId, reason: "failed")
                    errorMessage = "Couldn't start the call — check your microphone/camera and try again."
                    finish(failed: true)
                    return
                }
                guard call?.uuid == uuid else { manager.close(); return }
                self.manager = manager
                localVideoTrack = manager.localVideoTrack
                speakerEnabled = type == .video
                if let recipient = pendingAcceptRecipient, call?.phase == .connecting { pendingAcceptRecipient = nil; sendOffer(manager, callId: res.callId, targetUserId: recipient) }
            } catch let error as RelayError where error.status == 409 {
                debugLog(client.config, "error starting call: \(error.localizedDescription)")
                errorMessage = "They're already on another call."
            } catch {
                debugLog(client.config, "error starting call: \(error.localizedDescription)")
                errorMessage = "Couldn't start the call. Please try again."
            }
        }
    }

    // MARK: - Incoming

    func handleInvite(callId: String, conversationId: ConversationId, callerId: UserId, callerName: String?, type: CallType, isGroup: Bool = false, participantIds: [UserId] = []) {
        guard callerId != myUserId, call == nil else { return }
        let uuid = UUID()
        lastFailureDetail = nil
        call = ActiveCall(id: callId, uuid: uuid, conversationId: conversationId, peerId: callerId, peerName: callerName, type: type, phase: .incoming,
                           isGroup: isGroup, participantIds: participantIds)
        debugLog(client.config, "call \(callId) ringing (incoming)")
        reportIncoming(uuid: uuid, name: callerName ?? callerId, video: type == .video)
    }

    /// Answer the ringing call (CallKit calls this itself when the user taps its UI).
    public func answer() {
        guard let current = call, current.phase == .incoming else { return }
        #if canImport(CallKit) && os(iOS)
        guard !callKitUnavailable else {
            PeerConnectionManager.configureAudioSession(video: current.type == .video)
            PeerConnectionManager.activateAudioSessionWithoutCallKit()
            performAnswer(uuid: current.uuid)
            return
        }
        controller.request(CXTransaction(action: CXAnswerCallAction(call: current.uuid))) { [weak self] error in
            if error != nil { Task { @MainActor in self?.performAnswer(uuid: current.uuid) } }
        }
        #else
        performAnswer(uuid: current.uuid)
        #endif
    }

    private func performAnswer(uuid: UUID) {
        guard let current = call, current.uuid == uuid, current.phase == .incoming else { return }
        let callId = current.id, type = current.type, isGroup = current.isGroup
        answeringCallId = callId
        Task {
            defer { if answeringCallId == callId { answeringCallId = nil } }
            var manager: PeerConnectionManager?
            do {
                // Must happen before the REST answer call below — answering immediately prompts
                // the caller to start sending its SDP offer + ICE candidates over the socket, and
                // if this device was woken from a fully backgrounded/locked state via VoIP push,
                // its own socket hasn't necessarily reconnected yet. Without this, that race can
                // lose the entire signaling exchange to a gateway channel we weren't subscribed
                // to. Idempotent/instant when already connected.
                _ = try? await client.connect()
                let (_, participants) = try await client.api.answerCall(callId)
                guard var live = call, live.uuid == uuid else { return }
                live.phase = .connecting
                call = live
                debugLog(client.config, "call \(callId) answered")
                scheduleConnect(callId: callId)

                if isGroup {
                    // Newest-joiner-initiates: offer to every already-joined participant (not us) —
                    // people who join later will offer to us instead (point 3 of the protocol).
                    await refreshLocalPermissionFlags(type: type)
                    guard stillMine(uuid) else { return }
                    let media = LocalMedia(type: type)
                    guard stillMine(uuid) else { media.close(); return }
                    localMedia = media
                    localVideoTrack = media.videoTrack
                    speakerEnabled = type == .video
                    let servers = await iceServers()
                    guard stillMine(uuid) else { media.close(); return }
                    let others = (participants ?? []).filter { $0.userId != myUserId && $0.joinedAt != nil && $0.leftAt == nil }
                    for p in others {
                        let m = makeManager(callId: callId, userId: p.userId)
                        do {
                            try m.start(localMedia: media, iceServers: servers)
                            guard stillMine(uuid) else { m.close(); return }
                            peers[p.userId] = m
                            let offer = try await m.createOffer()
                            guard stillMine(uuid) else { return }
                            send(["event": "call_offer", "callId": callId, "targetUserId": p.userId, "sdp": ["type": offer.type, "sdp": offer.sdp]])
                        } catch {
                            m.close()
                            if peers[p.userId] === m { peers[p.userId] = nil }
                        }
                    }
                    return
                }

                let m = makeManager(callId: callId, userId: current.peerId)
                manager = m
                await refreshLocalPermissionFlags(type: type)
                guard stillMine(uuid) else { m.close(); return }
                let media = LocalMedia(type: type)
                let servers = await iceServers()
                guard stillMine(uuid) else { m.close(); media.close(); return }
                try m.start(localMedia: media, iceServers: servers)
                guard stillMine(uuid) else { m.close(); media.close(); return }
                self.manager = m
                localMedia = media
                localVideoTrack = m.localVideoTrack
                speakerEnabled = type == .video
                if let pending = pendingOffer, pending.callId == callId {
                    pendingOffer = nil
                    let answer = try await m.createAnswer(offer: pending.sdp)
                    guard stillMine(uuid) else { return }
                    send(["event": "call_answer_sdp", "callId": callId, "sdp": ["type": answer.type, "sdp": answer.sdp]])
                }
                drainCandidates(into: m, callId: callId)
            } catch let error as RelayError where error.status == 409 {
                debugLog(client.config, "error answering call \(callId): \(error.localizedDescription)")
                manager?.close()
                if stillMine(uuid) { finish(failed: false) }
            } catch {
                debugLog(client.config, "error answering call \(callId): \(error.localizedDescription)")
                manager?.close()
                guard stillMine(uuid) else { return }
                _ = try? await client.api.endCall(callId, reason: "failed")
                errorMessage = "Couldn't answer the call — check your microphone/camera and try again."
                finish(failed: true)
            }
        }
    }

    public func decline() {
        guard let current = call, current.phase == .incoming else { return }
        Task { _ = try? await client.api.declineCall(current.id) }
        finish(failed: false)
    }

    public func hangUp() {
        guard let current = call else { return }
        #if canImport(CallKit) && os(iOS)
        guard !callKitUnavailable else { performEnd(uuid: current.uuid); return }
        controller.request(CXTransaction(action: CXEndCallAction(call: current.uuid))) { [weak self] error in
            if error != nil { Task { @MainActor in self?.performEnd(uuid: current.uuid) } }
        }
        #else
        performEnd(uuid: current.uuid)
        #endif
    }

    private func performEnd(uuid: UUID) {
        guard let current = call, current.uuid == uuid else { return }
        Task { _ = try? await (current.phase == .incoming ? client.api.declineCall(current.id) : client.api.endCall(current.id)) }
        cleanup()
    }

    public func toggleMic() {
        // Every peer connection sends the SAME shared LocalMedia track, so toggling it once here
        // mutes/unmutes on every leg (1:1 or group) at once.
        micEnabled.toggle(); localMedia?.setMicEnabled(micEnabled)
        if let call { send(["event": "call_media_state", "callId": call.id, "micEnabled": micEnabled]) }
    }
    public func toggleCamera() {
        cameraEnabled.toggle(); localMedia?.setCameraEnabled(cameraEnabled)
        if let call { send(["event": "call_media_state", "callId": call.id, "cameraEnabled": cameraEnabled]) }
    }
    public func toggleSpeaker() { speakerEnabled.toggle(); PeerConnectionManager.setSpeaker(speakerEnabled) }

    // MARK: - Internals

    private func stillMine(_ uuid: UUID) -> Bool { call?.uuid == uuid }
    private func send(_ frame: [String: Any]) { client.sendFrame(frame) }

    /// Detects (without gating) mic/camera permission ahead of constructing `LocalMedia`. Does
    /// NOT block the call — it always proceeds; this only updates the published flags so the UI
    /// can show a banner. For `.notDetermined` it actively prompts via `requestAccess` and waits
    /// for the result, since that's the only chance to know before the call is already underway.
    private func refreshLocalPermissionFlags(type: CallType) async {
        localMicPermissionDenied = await !Self.isAuthorized(.audio)
        localCameraPermissionDenied = type == .video ? await !Self.isAuthorized(.video) : false
    }

    private static func isAuthorized(_ mediaType: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { c in
                AVCaptureDevice.requestAccess(for: mediaType) { granted in c.resume(returning: granted) }
            }
        case .denied, .restricted: return false
        @unknown default: return false
        }
    }

    private func iceServers() async -> [PeerConnectionManager.IceServer] {
        guard let turn = try? await client.api.turnCredentials() else { return [] }
        // Count only — NEVER log turn.username/turn.credential.
        debugLog(client.config, "TURN credentials fetched (\(turn.urls.count) ICE server URLs)")
        return [.init(urls: turn.urls, username: turn.username, credential: turn.credential)]
    }

    /// `userId` is the remote participant this manager talks to — `call.peerId` for a 1:1 call, or
    /// one specific participant's id for a group call (there's one manager per participant).
    private func makeManager(callId: String, userId: UserId) -> PeerConnectionManager {
        let m = PeerConnectionManager()
        m.onIceCandidate = { [weak self] c in
            Task { @MainActor in
                guard let self else { return }
                var json: [String: Any] = ["candidate": c.candidate]
                json["sdpMid"] = c.sdpMid; json["sdpMLineIndex"] = c.sdpMLineIndex.map { NSNumber(value: $0) }
                var frame: [String: Any] = ["event": "call_ice_candidate", "callId": callId, "candidate": json]
                if self.call?.isGroup == true { frame["targetUserId"] = userId }
                self.send(frame)
            }
        }
        m.onRemoteVideoTrack = { [weak self] track in
            Task { @MainActor in
                guard let self else { return }
                if self.call?.isGroup == true { self.remoteVideoTracks[userId] = track } else { self.remoteVideoTrack = track }
            }
        }
        m.onIceConnectionStateChange = { [weak self] iceState in
            Task { @MainActor in
                guard let self else { return }
                debugLog(self.client.config, "call \(callId) peer \(userId) ice: \(describeIceState(iceState))")
            }
        }
        m.onConnectionStateChange = { [weak self] state in
            Task { @MainActor in
                guard let self, self.peers[userId] === m, self.call?.id == callId else { return }
                debugLog(self.client.config, "call \(callId) peer \(userId) connection: \(describeConnectionState(state))")
                let isGroup = self.call?.isGroup == true
                switch state {
                case .connected:
                    self.connectTask?.cancel(); self.graceTask?.cancel(); self.restartTask?.cancel()
                    m.noteConnected()
                    if var c = self.call, c.phase != .active {
                        c.phase = .active; c.startedAt = c.startedAt ?? Date(); self.call = c
                        debugLog(self.client.config, "call \(callId) active")
                    }
                    self.reportConnected()
                    PeerConnectionManager.setSpeaker(self.speakerEnabled)
                case .disconnected:
                    if isGroup { self.groupPeerLost(userId: userId, manager: m) } else { self.connectionLost(callId: callId, failed: false, manager: m) }
                case .failed:
                    if isGroup { self.groupPeerLost(userId: userId, manager: m) } else { self.connectionLost(callId: callId, failed: true, manager: m) }
                default: break
                }
            }
        }
        return m
    }

    /// A group call's own connection state isn't defined by any one leg — a dropped peer just
    /// loses that tile; call_participant_left/call_end (not this) end the call.
    private func groupPeerLost(userId: UserId, manager: PeerConnectionManager) {
        guard !manager.canRestartIce else { return }
        removePeer(userId)
    }

    private func removePeer(_ userId: UserId) {
        peers[userId]?.close()
        peers[userId] = nil
        remoteVideoTracks[userId] = nil
        remoteMicEnabledByUser[userId] = nil
        remoteCameraEnabledByUser[userId] = nil
        locallyMutedUsers.remove(userId)
        pendingGroupCandidates[userId] = nil
    }

    private func sendOffer(_ manager: PeerConnectionManager, callId: String, targetUserId: UserId?) {
        Task {
            guard let offer = try? await manager.createOffer(), call?.id == callId else { return }
            var frame: [String: Any] = ["event": "call_offer", "callId": callId, "sdp": ["type": offer.type, "sdp": offer.sdp]]
            if call?.isGroup == true, let targetUserId { frame["targetUserId"] = targetUserId }
            send(frame)
        }
    }

    private func drainCandidates(into manager: PeerConnectionManager, callId: String) {
        let mine = pendingCandidates.filter { $0.callId == callId }
        pendingCandidates = []
        mine.forEach { manager.addRemoteIceCandidate($0.candidate) }
    }

    /// Group-only mirror of `createPeerFor` in web's CallStore: a sender we've never seen
    /// signaling from before is a newer joiner offering to us — create their manager (sharing
    /// `localMedia`) and drain anything buffered for them.
    private func createGroupPeer(callId: String, senderId: UserId) async -> PeerConnectionManager? {
        guard let media = localMedia, call?.id == callId else { return nil }
        let m = makeManager(callId: callId, userId: senderId)
        let servers = await iceServers()
        guard call?.id == callId, localMedia === media else { m.close(); return nil }
        do {
            try m.start(localMedia: media, iceServers: servers)
        } catch {
            m.close()
            return nil
        }
        peers[senderId] = m
        let queued = pendingGroupCandidates[senderId] ?? []
        pendingGroupCandidates[senderId] = nil
        queued.forEach { m.addRemoteIceCandidate($0.candidate) }
        return m
    }

    private func connectionLost(callId: String, failed: Bool, manager: PeerConnectionManager) {
        guard var current = call, current.id == callId else { return }
        guard current.phase == .active || current.phase == .reconnecting else {
            if failed, !manager.canRestartIce {
                let state = manager.connectionState.map(describeConnectionState) ?? "unknown"
                failCall(callId, "Call failed to connect — check your network and try again.", detail: "peer connection: \(state) (ICE restart unavailable)")
            }
            return
        }
        if current.phase == .active { current.phase = .reconnecting; call = current }
        if graceTask == nil {
            graceTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: Self.reconnectGrace * 1_000_000_000)
                guard let self, !Task.isCancelled, self.call?.id == callId, self.call?.phase == .reconnecting else { return }
                let state = manager.connectionState.map(describeConnectionState) ?? "unknown"
                self.failCall(callId, "Call dropped — check your network and try again.", detail: "peer connection: \(state) (reconnect grace period expired)")
            }
        }
        guard manager.canRestartIce else { return }
        restartTask?.cancel()
        restartTask = Task { [weak self] in
            if !failed { try? await Task.sleep(nanoseconds: 3_000_000_000) }
            guard let self, !Task.isCancelled, self.call?.id == callId, manager.connectionState != .connected else { return }
            if let offer = try? await manager.restartIce() {
                self.send(["event": "call_offer", "callId": callId, "sdp": ["type": offer.type, "sdp": offer.sdp]])
            }
        }
    }

    private func failCall(_ callId: String, _ message: String, detail: String? = nil) {
        Task { _ = try? await client.api.endCall(callId, reason: "failed") }
        errorMessage = message
        lastFailureDetail = detail
        if let detail { debugLog(client.config, "call \(callId) failed — \(detail)") }
        finish(failed: true)
    }

    private func scheduleRing(callId: String) {
        ringTask?.cancel()
        ringTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.ringTimeout * 1_000_000_000)
            guard let self, !Task.isCancelled, self.call?.id == callId, self.call?.phase == .outgoing else { return }
            _ = try? await self.client.api.endCall(callId, reason: "timeout")
            self.finish(failed: false)
        }
    }

    private func scheduleConnect(callId: String) {
        connectTask?.cancel()
        connectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.connectTimeout * 1_000_000_000)
            guard let self, !Task.isCancelled, self.call?.id == callId, self.call?.phase == .connecting else { return }
            // Whatever state the WebRTC peer connection(s) got stuck in by the connect timeout —
            // e.g. "connecting" here almost always means ICE never found a working candidate pair
            // (common on a Simulator, which has no real network stack for two local instances to
            // negotiate over; rare on physical devices unless the network genuinely blocks it).
            let states = self.peers.map { "\($0.key): \($0.value.connectionState.map(describeConnectionState) ?? "unknown")" }
            let detail = "connect timeout (\(Int(Self.connectTimeout))s) — " + (states.isEmpty ? "no peer connection" : states.joined(separator: ", "))
            self.failCall(callId, "Call failed to connect — check your network and try again.", detail: detail)
        }
    }

    func finish(failed: Bool) {
        if let call {
            debugLog(client.config, "call \(call.id) ended (failed=\(failed))")
            reportEnded(uuid: call.uuid, failed: failed)
        }
        cleanup()
    }

    private func cleanup() {
        for t in [ringTask, connectTask, graceTask, restartTask] { t?.cancel() }
        ringTask = nil; connectTask = nil; graceTask = nil; restartTask = nil
        for m in peers.values { m.close() }
        peers = [:]
        localMedia?.close(); localMedia = nil
        pendingOffer = nil; pendingCandidates = []; pendingGroupCandidates = [:]; pendingAcceptRecipient = nil; answeringCallId = nil
        call = nil; localVideoTrack = nil; remoteVideoTrack = nil; remoteVideoTracks = [:]
        micEnabled = true; cameraEnabled = true; speakerEnabled = false
        remoteMicEnabled = true; remoteCameraEnabled = true; remoteMicEnabledByUser = [:]; remoteCameraEnabledByUser = [:]
        locallyMutedUsers = []
        localMicPermissionDenied = false; localCameraPermissionDenied = false
    }

    private func handle(_ event: CallEvent) {
        switch event {
        case .invite(let callId, let conversationId, let callerId, let callerName, let type, let isGroup, let participantIds):
            handleInvite(callId: callId, conversationId: conversationId, callerId: callerId, callerName: callerName, type: type, isGroup: isGroup, participantIds: participantIds)
        case .accepted(let callId, let by):
            // 1:1-only — a group call's per-member join uses call_participant_joined instead.
            if let c = call, c.id == callId, c.phase == .incoming, by == myUserId, answeringCallId != callId { finish(failed: false); return }
            guard var c = call, c.id == callId, c.phase == .outgoing, !c.isGroup else { return }
            ringTask?.cancel(); ringTask = nil
            c.phase = .connecting; call = c
            scheduleConnect(callId: callId)
            reportOutgoingConnecting(uuid: c.uuid)
            guard let manager else { pendingAcceptRecipient = by; return }
            sendOffer(manager, callId: callId, targetUserId: nil)
        case .offer(let callId, let senderId, let sdp, _):
            guard call == nil || call?.id == callId else { return }
            if let existing = peers[senderId] {
                Task {
                    guard let answer = try? await existing.createAnswer(offer: sdp), call?.id == callId else { return }
                    var frame: [String: Any] = ["event": "call_answer_sdp", "callId": callId, "sdp": ["type": answer.type, "sdp": answer.sdp]]
                    if call?.isGroup == true { frame["targetUserId"] = senderId }
                    send(frame)
                }
                return
            }
            if call?.isGroup == true {
                // No manager for this sender yet: they're a newer joiner offering to us (point 3,
                // "newest joiner initiates") — grow the mesh instead of buffering.
                Task {
                    guard let m = await createGroupPeer(callId: callId, senderId: senderId) else { return }
                    guard let answer = try? await m.createAnswer(offer: sdp), call?.id == callId else { return }
                    send(["event": "call_answer_sdp", "callId": callId, "targetUserId": senderId, "sdp": ["type": answer.type, "sdp": answer.sdp]])
                }
                return
            }
            // 1:1: no manager yet (still ringing, before answer() runs) — buffer for drainCandidates()/performAnswer().
            pendingOffer = (callId, sdp)
        case .answerSDP(let callId, let senderId, let sdp, _):
            guard call?.id == callId else { return }
            let target = call?.isGroup == true ? peers[senderId] : manager
            Task { try? await target?.acceptAnswer(sdp) }
        case .ice(let callId, let senderId, let candidate, _):
            guard call == nil || call?.id == callId else { return }
            if call?.isGroup == true {
                if let m = peers[senderId] { m.addRemoteIceCandidate(candidate) }
                else {
                    var list = pendingGroupCandidates[senderId] ?? []
                    if list.count < 64 { list.append((callId, candidate)) }
                    pendingGroupCandidates[senderId] = list
                }
                return
            }
            if let manager, call?.id == callId { manager.addRemoteIceCandidate(candidate) }
            else if call == nil || call?.id == callId, pendingCandidates.count < 64 { pendingCandidates.append((callId, candidate)) }
        case .busy: break
        case .declined(let callId), .missed(let callId), .ended(let callId, _):
            guard call?.id == callId else { return }
            finish(failed: false)
        case .mediaState(let callId, let senderId, let cam, let mic):
            guard call?.id == callId else { return }
            if call?.isGroup != true {
                // Each toggle sends only the ONE field that changed — the other is nil on this
                // event, not false — so each side is applied independently or a mic-only update
                // would wrongly stomp remoteCameraEnabled (or vice versa).
                if let cam { remoteCameraEnabled = cam }
                if let mic { remoteMicEnabled = mic }
                return
            }
            guard let senderId else { return }
            if let cam { remoteCameraEnabledByUser[senderId] = cam }
            if let mic { remoteMicEnabledByUser[senderId] = mic }
        case .participantJoined(let callId, _, _, let participantIds):
            // The joiner offers to us (point 3) — we just refresh the roster and wait for their offer.
            // Someone answered — stop the "nobody's answering" ring timeout (mirrors .accepted for
            // 1:1). Without this a group call the caller placed self-destructs at the ring timeout
            // even when other members are actively on it, since nothing else moves the caller's
            // own phase off .outgoing until ITS OWN peer connection reaches connected.
            if var c = call, c.id == callId { c.participantIds = participantIds; call = c; ringTask?.cancel() }
        case .participantDeclined(let callId, _, let userId):
            // Informational only — doesn't end the call. Drop them from the roster so the UI
            // doesn't keep showing a name that will never join.
            if var c = call, c.id == callId { c.participantIds.removeAll { $0 == userId }; call = c }
        case .participantLeft(let callId, _, let userId, _):
            guard var c = call, c.id == callId else { return }
            removePeer(userId)
            c.participantIds.removeAll { $0 == userId }
            call = c
        }
    }

    // MARK: - CallKit bridge

    private func reportIncoming(uuid: UUID, name: String, video: Bool) {
        #if canImport(CallKit) && os(iOS)
        // Already known-unusable on this device/region: skip straight to the fallback instead of
        // paying another round trip through CallKit to rediscover the same failure.
        guard !callKitUnavailable else { notifyIncomingCallLocally(uuid: uuid, name: name, video: video); return }
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: name)
        update.localizedCallerName = name
        update.hasVideo = video
        update.supportsHolding = false; update.supportsGrouping = false; update.supportsUngrouping = false; update.supportsDTMF = false
        provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
            guard let self else { return }
            Task { @MainActor in
                guard error != nil else { self.callKitReportedAt = (uuid, Date()); return }
                self.markCallKitUnavailable()
                self.notifyIncomingCallLocally(uuid: uuid, name: name, video: video)
            }
        }
        #endif
    }
    private func reportOutgoingStarted(uuid: UUID, name: String, video: Bool) {
        #if canImport(CallKit) && os(iOS)
        guard !callKitUnavailable else {
            PeerConnectionManager.configureAudioSession(video: video)
            PeerConnectionManager.activateAudioSessionWithoutCallKit()
            return
        }
        let action = CXStartCallAction(call: uuid, handle: CXHandle(type: .generic, value: name))
        action.isVideo = video
        controller.request(CXTransaction(action: action)) { [weak self] error in
            guard let self else { return }
            Task { @MainActor in
                guard error != nil else { self.callKitReportedAt = (uuid, Date()); return }
                self.markCallKitUnavailable()
                PeerConnectionManager.configureAudioSession(video: video)
                PeerConnectionManager.activateAudioSessionWithoutCallKit()
            }
        }
        #endif
    }
    private func reportOutgoingConnecting(uuid: UUID) {
        #if canImport(CallKit) && os(iOS)
        guard !callKitUnavailable else { return }
        provider.reportOutgoingCall(with: uuid, startedConnectingAt: nil)
        #endif
    }
    private func reportConnected() {
        #if canImport(CallKit) && os(iOS)
        guard !callKitUnavailable, let call else { return }
        provider.reportOutgoingCall(with: call.uuid, connectedAt: nil)
        #endif
    }
    private func reportEnded(uuid: UUID, failed: Bool) {
        #if canImport(CallKit) && os(iOS)
        if !callKitUnavailable { provider.reportCall(with: uuid, endedAt: nil, reason: failed ? .failed : .remoteEnded) }
        clearLocalCallNotification(uuid: uuid)
        #endif
    }

    #if canImport(UserNotifications) && os(iOS)
    /// In-app fallback for a device/region where CallKit's incoming-call reporting fails: a local
    /// notification (so the call surfaces even if the app is backgrounded) plus `IncomingCallBanner`
    /// in `RelayCallOverlay`, which renders on iOS only when `callKitUnavailable` is true.
    private func notifyIncomingCallLocally(uuid: UUID, name: String, video: Bool) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = name
            content.body = "Incoming \(video ? "video" : "audio") call"
            #if !DEBUG
            content.sound = .default
            #endif
            content.userInfo = ["relayCallUUID": uuid.uuidString]
            let request = UNNotificationRequest(identifier: "relay-call-\(uuid.uuidString)", content: content, trigger: nil)
            center.add(request)
        }
    }
    private func clearLocalCallNotification(uuid: UUID) {
        let ids = ["relay-call-\(uuid.uuidString)"]
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ids)
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }
    #endif
    #if canImport(CallKit) && os(iOS)
    func reportNewIncomingCall(uuid: UUID, update: CXCallUpdate, completion: @escaping @Sendable (Error?) -> Void) {
        provider.reportNewIncomingCall(with: uuid, update: update, completion: completion)
    }
    func reportCallEnded(uuid: UUID, reason: CXCallEndedReason) {
        provider.reportCall(with: uuid, endedAt: nil, reason: reason)
    }
    #endif
}

#if canImport(CallKit) && os(iOS)
extension CallCenter: CXProviderDelegate {
    nonisolated public func providerDidReset(_ provider: CXProvider) {}
    nonisolated public func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        PeerConnectionManager.configureAudioSession(video: action.isVideo)
        provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: nil)
        action.fulfill()
    }
    nonisolated public func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        Task { @MainActor in
            PeerConnectionManager.configureAudioSession(video: self.call?.type == .video)
            self.performAnswer(uuid: action.callUUID)
        }
        action.fulfill()
    }
    nonisolated public func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        Task { @MainActor in
            // CallKit ending a call it just finished reporting, this fast, is not a human tapping
            // decline — see `incomingReportedAt`'s doc comment. Flag it so the NEXT incoming call
            // skips CallKit and uses the banner/notification fallback (this one is already lost —
            // CallKit committed to ending it before we could intervene).
            if let probe = self.callKitReportedAt, probe.uuid == action.callUUID,
               Date().timeIntervalSince(probe.at) < Self.callKitProbeWindow,
               let phase = self.call?.phase, phase == .incoming || phase == .outgoing || phase == .connecting {
                self.markCallKitUnavailable()
            }
            self.performEnd(uuid: action.callUUID)
        }
        action.fulfill()
    }
    nonisolated public func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        Task { @MainActor in
            guard self.call?.uuid == action.callUUID else { return }
            self.micEnabled = !action.isMuted
            self.localMedia?.setMicEnabled(!action.isMuted)
        }
        action.fulfill()
    }
    nonisolated public func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        RTCAudioSession.sharedInstance().audioSessionDidActivate(audioSession)
        RTCAudioSession.sharedInstance().isAudioEnabled = true
    }
    nonisolated public func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        RTCAudioSession.sharedInstance().isAudioEnabled = false
        RTCAudioSession.sharedInstance().audioSessionDidDeactivate(audioSession)
    }
}
#endif
