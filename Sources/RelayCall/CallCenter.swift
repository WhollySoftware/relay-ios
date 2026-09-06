import Foundation
import Observation
import RelayCore
@preconcurrency import WebRTC
#if canImport(CallKit) && os(iOS)
import CallKit
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
    }

    public private(set) var call: ActiveCall?
    public private(set) var localVideoTrack: RTCVideoTrack?
    public private(set) var remoteVideoTrack: RTCVideoTrack?
    public private(set) var micEnabled = true
    public private(set) var cameraEnabled = true
    public private(set) var speakerEnabled = false
    public var errorMessage: String?
    /// Shown by CallKit for outgoing calls and as a fallback name; set your app's display name.
    public var localizedAppName = "Call"

    let client: RelayClient
    private var manager: PeerConnectionManager?
    private var pendingOffer: (callId: String, sdp: SDPPayload)?
    private var pendingCandidates: [(callId: String, candidate: ICECandidatePayload)] = []
    private var pendingAcceptRecipient: UserId?
    private var answeringCallId: String?
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
    #endif

    public init(client: RelayClient, supportsVideo: Bool = true) {
        self.client = client
        #if canImport(CallKit) && os(iOS)
        let config = CXProviderConfiguration()
        config.supportsVideo = supportsVideo
        config.maximumCallGroups = 1
        config.maximumCallsPerCallGroup = 1
        config.supportedHandleTypes = [.generic]
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

    public func start(conversation: Conversation, type: CallType) {
        guard call == nil, !isStarting, let peer = conversation.peer else { return }
        isStarting = true
        Task {
            defer { isStarting = false }
            do {
                let res = try await client.api.startCall(conversationId: conversation.id, type: type)
                let uuid = UUID()
                call = ActiveCall(id: res.callId, uuid: uuid, conversationId: conversation.id, peerId: peer.userId, peerName: peer.displayName, type: type, phase: .outgoing)
                reportOutgoingStarted(uuid: uuid, name: peer.displayName ?? peer.userId, video: type == .video)
                scheduleRing(callId: res.callId)
                let manager = makeManager(callId: res.callId)
                do {
                    let servers = await iceServers()
                    guard call?.uuid == uuid else { manager.close(); return }
                    #if !os(iOS)
                    PeerConnectionManager.configureAudioSession(video: type == .video)
                    #endif
                    try manager.start(type: type, iceServers: servers)
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
                if let recipient = pendingAcceptRecipient, call?.phase == .connecting { pendingAcceptRecipient = nil; sendOffer(manager, callId: res.callId) }
            } catch let error as RelayError where error.status == 409 {
                errorMessage = "They're already on another call."
            } catch {
                errorMessage = "Couldn't start the call. Please try again."
            }
        }
    }

    // MARK: - Incoming

    func handleInvite(callId: String, conversationId: ConversationId, callerId: UserId, callerName: String?, type: CallType) {
        guard callerId != myUserId, call == nil else { return }
        let uuid = UUID()
        call = ActiveCall(id: callId, uuid: uuid, conversationId: conversationId, peerId: callerId, peerName: callerName, type: type, phase: .incoming)
        reportIncoming(uuid: uuid, name: callerName ?? callerId, video: type == .video)
    }

    /// Answer the ringing call (CallKit calls this itself when the user taps its UI).
    public func answer() {
        guard let current = call, current.phase == .incoming else { return }
        #if canImport(CallKit) && os(iOS)
        controller.request(CXTransaction(action: CXAnswerCallAction(call: current.uuid))) { [weak self] error in
            if error != nil { Task { @MainActor in self?.performAnswer(uuid: current.uuid) } }
        }
        #else
        performAnswer(uuid: current.uuid)
        #endif
    }

    private func performAnswer(uuid: UUID) {
        guard let current = call, current.uuid == uuid, current.phase == .incoming else { return }
        let callId = current.id, type = current.type
        answeringCallId = callId
        Task {
            defer { if answeringCallId == callId { answeringCallId = nil } }
            var manager: PeerConnectionManager?
            do {
                try await client.api.answerCall(callId)
                guard var live = call, live.uuid == uuid else { return }
                live.phase = .connecting
                call = live
                scheduleConnect(callId: callId)
                let m = makeManager(callId: callId)
                manager = m
                let servers = await iceServers()
                guard stillMine(uuid) else { m.close(); return }
                try m.start(type: type, iceServers: servers)
                guard stillMine(uuid) else { m.close(); return }
                self.manager = m
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
                manager?.close()
                if stillMine(uuid) { finish(failed: false) }
            } catch {
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

    public func toggleMic() { micEnabled.toggle(); manager?.setMicEnabled(micEnabled) }
    public func toggleCamera() { cameraEnabled.toggle(); manager?.setCameraEnabled(cameraEnabled) }
    public func toggleSpeaker() { speakerEnabled.toggle(); PeerConnectionManager.setSpeaker(speakerEnabled) }

    // MARK: - Internals

    private func stillMine(_ uuid: UUID) -> Bool { call?.uuid == uuid }
    private func send(_ frame: [String: Any]) { client.sendFrame(frame) }

    private func iceServers() async -> [PeerConnectionManager.IceServer] {
        guard let turn = try? await client.api.turnCredentials() else { return [] }
        return [.init(urls: turn.urls, username: turn.username, credential: turn.credential)]
    }

    private func makeManager(callId: String) -> PeerConnectionManager {
        let m = PeerConnectionManager()
        m.onIceCandidate = { [weak self] c in
            Task { @MainActor in
                var json: [String: Any] = ["candidate": c.candidate]
                json["sdpMid"] = c.sdpMid; json["sdpMLineIndex"] = c.sdpMLineIndex.map { NSNumber(value: $0) }
                self?.send(["event": "call_ice_candidate", "callId": callId, "candidate": json])
            }
        }
        m.onRemoteVideoTrack = { [weak self] track in Task { @MainActor in self?.remoteVideoTrack = track } }
        m.onConnectionStateChange = { [weak self] state in
            Task { @MainActor in
                guard let self, self.manager === m, self.call?.id == callId else { return }
                switch state {
                case .connected:
                    self.connectTask?.cancel(); self.graceTask?.cancel(); self.restartTask?.cancel()
                    m.noteConnected()
                    if var c = self.call { c.phase = .active; c.startedAt = c.startedAt ?? Date(); self.call = c }
                    self.reportConnected()
                    PeerConnectionManager.setSpeaker(self.speakerEnabled)
                case .disconnected: self.connectionLost(callId: callId, failed: false, manager: m)
                case .failed: self.connectionLost(callId: callId, failed: true, manager: m)
                default: break
                }
            }
        }
        return m
    }

    private func sendOffer(_ manager: PeerConnectionManager, callId: String) {
        Task {
            guard let offer = try? await manager.createOffer(), call?.id == callId else { return }
            send(["event": "call_offer", "callId": callId, "sdp": ["type": offer.type, "sdp": offer.sdp]])
        }
    }

    private func drainCandidates(into manager: PeerConnectionManager, callId: String) {
        let mine = pendingCandidates.filter { $0.callId == callId }
        pendingCandidates = []
        mine.forEach { manager.addRemoteIceCandidate($0.candidate) }
    }

    private func connectionLost(callId: String, failed: Bool, manager: PeerConnectionManager) {
        guard var current = call, current.id == callId else { return }
        guard current.phase == .active || current.phase == .reconnecting else {
            if failed, !manager.canRestartIce { failCall(callId, "Call failed to connect — check your network and try again.") }
            return
        }
        if current.phase == .active { current.phase = .reconnecting; call = current }
        if graceTask == nil {
            graceTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: Self.reconnectGrace * 1_000_000_000)
                guard let self, !Task.isCancelled, self.call?.id == callId, self.call?.phase == .reconnecting else { return }
                self.failCall(callId, "Call dropped — check your network and try again.")
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

    private func failCall(_ callId: String, _ message: String) {
        Task { _ = try? await client.api.endCall(callId, reason: "failed") }
        errorMessage = message
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
            self.failCall(callId, "Call failed to connect — check your network and try again.")
        }
    }

    func finish(failed: Bool) {
        if let call { reportEnded(uuid: call.uuid, failed: failed) }
        cleanup()
    }

    private func cleanup() {
        for t in [ringTask, connectTask, graceTask, restartTask] { t?.cancel() }
        ringTask = nil; connectTask = nil; graceTask = nil; restartTask = nil
        manager?.close(); manager = nil
        pendingOffer = nil; pendingCandidates = []; pendingAcceptRecipient = nil; answeringCallId = nil
        call = nil; localVideoTrack = nil; remoteVideoTrack = nil
        micEnabled = true; cameraEnabled = true; speakerEnabled = false
    }

    private func handle(_ event: CallEvent) {
        switch event {
        case .invite(let callId, let conversationId, let callerId, let callerName, let type):
            handleInvite(callId: callId, conversationId: conversationId, callerId: callerId, callerName: callerName, type: type)
        case .accepted(let callId, let by):
            if let c = call, c.id == callId, c.phase == .incoming, by == myUserId, answeringCallId != callId { finish(failed: false); return }
            guard var c = call, c.id == callId, c.phase == .outgoing else { return }
            ringTask?.cancel(); ringTask = nil
            c.phase = .connecting; call = c
            scheduleConnect(callId: callId)
            reportOutgoingConnecting(uuid: c.uuid)
            guard let manager else { pendingAcceptRecipient = by; return }
            sendOffer(manager, callId: callId)
        case .offer(let callId, _, let sdp):
            guard let manager, call?.id == callId else { pendingOffer = (callId, sdp); return }
            Task {
                guard let answer = try? await manager.createAnswer(offer: sdp), call?.id == callId else { return }
                send(["event": "call_answer_sdp", "callId": callId, "sdp": ["type": answer.type, "sdp": answer.sdp]])
            }
        case .answerSDP(let callId, let sdp):
            guard call?.id == callId else { return }
            Task { try? await manager?.acceptAnswer(sdp) }
        case .ice(let callId, let candidate):
            if let manager, call?.id == callId { manager.addRemoteIceCandidate(candidate) }
            else if call == nil || call?.id == callId, pendingCandidates.count < 64 { pendingCandidates.append((callId, candidate)) }
        case .busy: break
        case .declined(let callId), .missed(let callId), .ended(let callId, _):
            guard call?.id == callId else { return }
            finish(failed: false)
        }
    }

    // MARK: - CallKit bridge

    private func reportIncoming(uuid: UUID, name: String, video: Bool) {
        #if canImport(CallKit) && os(iOS)
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: name)
        update.localizedCallerName = name
        update.hasVideo = video
        update.supportsHolding = false; update.supportsGrouping = false; update.supportsUngrouping = false; update.supportsDTMF = false
        provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
            if error != nil { Task { @MainActor in self?.finish(failed: true) } }
        }
        #endif
    }
    private func reportOutgoingStarted(uuid: UUID, name: String, video: Bool) {
        #if canImport(CallKit) && os(iOS)
        let action = CXStartCallAction(call: uuid, handle: CXHandle(type: .generic, value: name))
        action.isVideo = video
        controller.request(CXTransaction(action: action)) { _ in }
        #endif
    }
    private func reportOutgoingConnecting(uuid: UUID) {
        #if canImport(CallKit) && os(iOS)
        provider.reportOutgoingCall(with: uuid, startedConnectingAt: nil)
        #endif
    }
    private func reportConnected() {
        #if canImport(CallKit) && os(iOS)
        if let call { provider.reportOutgoingCall(with: call.uuid, connectedAt: nil) }
        #endif
    }
    private func reportEnded(uuid: UUID, failed: Bool) {
        #if canImport(CallKit) && os(iOS)
        provider.reportCall(with: uuid, endedAt: nil, reason: failed ? .failed : .remoteEnded)
        #endif
    }
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
        Task { @MainActor in self.performEnd(uuid: action.callUUID) }
        action.fulfill()
    }
    nonisolated public func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        Task { @MainActor in
            guard self.call?.uuid == action.callUUID else { return }
            self.micEnabled = !action.isMuted
            self.manager?.setMicEnabled(!action.isMuted)
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
