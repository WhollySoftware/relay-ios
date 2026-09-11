import Foundation
@preconcurrency import WebRTC

/// The one getUserMedia()-equivalent per call: a shared audio track, (for video calls) a shared
/// video track + camera capturer, acquired ONCE and attached to every remote participant's
/// RTCPeerConnection. Mirrors web's CallStore holding a single MediaStream shared across all of a
/// call's PeerConnectionManagers — the capture session and mic are per-call, not per-peer.
final class LocalMedia {
    private static let factory: RTCPeerConnectionFactory = PeerConnectionManager.factory

    let audioTrack: RTCAudioTrack
    private(set) var videoTrack: RTCVideoTrack?
    private var capturer: RTCCameraVideoCapturer?

    init(type: CallType) {
        audioTrack = Self.factory.audioTrack(with: Self.factory.audioSource(with: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)), trackId: "audio0")
        if type == .video {
            let source = Self.factory.videoSource()
            let cap = RTCCameraVideoCapturer(delegate: source)
            capturer = cap
            videoTrack = Self.factory.videoTrack(with: source, trackId: "video0")
            let devices = RTCCameraVideoCapturer.captureDevices()
            if let device = devices.first(where: { $0.position == .front }) ?? devices.first,
               let format = RTCCameraVideoCapturer.supportedFormats(for: device).max(by: { CMVideoFormatDescriptionGetDimensions($0.formatDescription).width < CMVideoFormatDescriptionGetDimensions($1.formatDescription).width }) {
                let fps = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 30
                cap.startCapture(with: device, format: format, fps: Int(min(fps, 30)))
            }
        }
    }

    func setMicEnabled(_ enabled: Bool) { audioTrack.isEnabled = enabled }
    func setCameraEnabled(_ enabled: Bool) { videoTrack?.isEnabled = enabled }

    func close() {
        capturer?.stopCapture()
        capturer = nil
    }
}

/// One RTCPeerConnection for one remote participant — the DevBattel WebRTCManager, generalised:
/// candidates queued until the remote description exists, ICE restart by the offerer. A 1:1 call
/// has exactly one of these; a group call has one per other participant, all sharing the same
/// `LocalMedia` (one mic/camera, N RTCPeerConnections) — see `start(localMedia:iceServers:)`.
final class PeerConnectionManager: NSObject, @unchecked Sendable {
    struct IceServer { let urls: [String]; let username: String?; let credential: String? }
    enum CallError: Error { case peerConnectionFailed, notStarted }

    var onIceCandidate: (@Sendable (ICECandidatePayload) -> Void)?
    var onConnectionStateChange: (@Sendable (RTCPeerConnectionState) -> Void)?
    var onRemoteVideoTrack: (@Sendable (RTCVideoTrack) -> Void)?

    fileprivate static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(), decoderFactory: RTCDefaultVideoDecoderFactory())
    }()

    private var pc: RTCPeerConnection?
    // Not owned — LocalMedia owns acquisition/teardown; this class only attaches/reads.
    private(set) var localVideoTrack: RTCVideoTrack?
    private var pendingRemoteCandidates: [RTCIceCandidate] = []
    private var remoteDescriptionSet = false
    private(set) var isOfferer = false
    private var iceRestarts = 0
    var connectionState: RTCPeerConnectionState? { pc?.connectionState }
    var canRestartIce: Bool { pc != nil && isOfferer && iceRestarts < 3 }

    func start(localMedia: LocalMedia, iceServers: [IceServer]) throws {
        let config = RTCConfiguration()
        config.iceServers = iceServers.isEmpty ? [RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"])]
            : iceServers.map { RTCIceServer(urlStrings: $0.urls, username: $0.username, credential: $0.credential) }
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherContinually
        guard let pc = Self.factory.peerConnection(with: config, constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil), delegate: nil) else {
            throw CallError.peerConnectionFailed
        }
        pc.delegate = self
        self.pc = pc
        pc.add(localMedia.audioTrack, streamIds: ["stream0"])
        if let video = localMedia.videoTrack {
            localVideoTrack = video
            pc.add(video, streamIds: ["stream0"])
        }
    }

    private func offer(_ pc: RTCPeerConnection, restart: Bool) async throws -> SDPPayload {
        isOfferer = true
        let constraints = RTCMediaConstraints(mandatoryConstraints: restart ? [kRTCMediaConstraintsIceRestart: kRTCMediaConstraintsValueTrue] : nil, optionalConstraints: ["OfferToReceiveAudio": "true"])
        let sdp: RTCSessionDescription = try await withCheckedThrowingContinuation { c in
            pc.offer(for: constraints) { sdp, error in if let sdp { c.resume(returning: sdp) } else { c.resume(throwing: error ?? CallError.peerConnectionFailed) } }
        }
        try await setLocal(sdp, pc)
        if restart { remoteDescriptionSet = false }
        return SDPPayload(type: "offer", sdp: sdp.sdp)
    }

    func createOffer() async throws -> SDPPayload { guard let pc else { throw CallError.notStarted }; return try await offer(pc, restart: false) }

    func restartIce() async throws -> SDPPayload? {
        guard let pc, canRestartIce, pc.signalingState == .stable else { return nil }
        iceRestarts += 1
        return try await offer(pc, restart: true)
    }

    func noteConnected() { iceRestarts = 0 }

    func createAnswer(offer: SDPPayload) async throws -> SDPPayload {
        try await setRemote(offer)
        guard let pc else { throw CallError.notStarted }
        let sdp: RTCSessionDescription = try await withCheckedThrowingContinuation { c in
            pc.answer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: ["OfferToReceiveAudio": "true"])) { sdp, error in
                if let sdp { c.resume(returning: sdp) } else { c.resume(throwing: error ?? CallError.peerConnectionFailed) }
            }
        }
        try await setLocal(sdp, pc)
        return SDPPayload(type: "answer", sdp: sdp.sdp)
    }

    func acceptAnswer(_ answer: SDPPayload) async throws {
        guard let pc, pc.signalingState == .haveLocalOffer else { return }
        try await setRemote(answer)
    }

    private func setLocal(_ sdp: RTCSessionDescription, _ pc: RTCPeerConnection) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            pc.setLocalDescription(sdp) { error in if let error { c.resume(throwing: error) } else { c.resume() } }
        }
    }

    private func setRemote(_ payload: SDPPayload) async throws {
        guard let pc else { throw CallError.notStarted }
        let description = RTCSessionDescription(type: payload.type == "offer" ? .offer : .answer, sdp: payload.sdp)
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            pc.setRemoteDescription(description) { error in if let error { c.resume(throwing: error) } else { c.resume() } }
        }
        remoteDescriptionSet = true
        let queued = pendingRemoteCandidates
        pendingRemoteCandidates = []
        queued.forEach { pc.add($0) }
    }

    func addRemoteIceCandidate(_ payload: ICECandidatePayload) {
        let candidate = RTCIceCandidate(sdp: payload.candidate, sdpMLineIndex: payload.sdpMLineIndex ?? 0, sdpMid: payload.sdpMid)
        guard let pc, remoteDescriptionSet else { pendingRemoteCandidates.append(candidate); return }
        pc.add(candidate)
    }

    func close() {
        // Does NOT touch the shared LocalMedia (mic/camera/capturer) — other peers of the same
        // group call may still be using it; the call owner closes LocalMedia separately.
        pc?.close()
        pc = nil
        localVideoTrack = nil
        pendingRemoteCandidates = []
        remoteDescriptionSet = false
    }

    // MARK: audio session helpers (iOS only; CallKit owns activation — we set what it should activate)
    static func configureAudioSession(video: Bool) {
        #if os(iOS)
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration(); defer { session.unlockForConfiguration() }
        try? session.setCategory(.playAndRecord, mode: video ? .videoChat : .voiceChat, options: [.allowBluetooth, .allowBluetoothA2DP])
        #endif
    }
    /// CallKit normally activates the audio session itself (`provider(_:didActivate:)`, which flips
    /// `RTCAudioSession.isAudioEnabled`). When CallKit is unavailable that delegate never fires, so
    /// the CallKit-unavailable fallback calls this directly after `configureAudioSession` or audio
    /// stays silent for the whole call.
    static func activateAudioSessionWithoutCallKit() {
        #if os(iOS)
        RTCAudioSession.sharedInstance().isAudioEnabled = true
        #endif
    }
    static func setSpeaker(_ on: Bool) {
        #if os(iOS)
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration(); defer { session.unlockForConfiguration() }
        try? session.overrideOutputAudioPort(on ? .speaker : .none)
        #endif
    }
}

extension PeerConnectionManager: RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams mediaStreams: [RTCMediaStream]) {
        if let track = rtpReceiver.track as? RTCVideoTrack { onRemoteVideoTrack?(track) }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        onIceCandidate?(ICECandidatePayload(candidate: candidate.sdp, sdpMid: candidate.sdpMid, sdpMLineIndex: candidate.sdpMLineIndex))
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) { onConnectionStateChange?(newState) }
}
