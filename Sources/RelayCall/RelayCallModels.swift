import Foundation
import RelayCore

public enum CallType: String, Codable, Sendable { case audio, video }
public enum CallStatus: String, Codable, Sendable { case ringing, active, ended, missed, declined, busy, failed }

public struct Call: Codable, Sendable, Equatable {
    public let callId: String
    public let conversationId: ConversationId
    public let type: CallType
    public let status: CallStatus
    public let callerId: UserId
    public let calleeId: UserId
    public let startedAt: Date?
    public let endedAt: Date?
    public let endReason: String?
    public let createdAt: Date
}

public struct TurnCredentials: Codable, Sendable {
    public let urls: [String]
    public let username: String
    public let credential: String
    public let expiresAt: Int
}

public struct SDPPayload: Codable, Sendable, Equatable {
    public let type: String
    public let sdp: String
    public init(type: String, sdp: String) { self.type = type; self.sdp = sdp }
}

public struct ICECandidatePayload: Codable, Sendable, Equatable {
    public let candidate: String
    public let sdpMid: String?
    public let sdpMLineIndex: Int32?
    public init(candidate: String, sdpMid: String?, sdpMLineIndex: Int32?) { self.candidate = candidate; self.sdpMid = sdpMid; self.sdpMLineIndex = sdpMLineIndex }
}

/// Call events decoded from the gateway's `unknown` frames (RelayCore knows only chat events).
enum CallEvent {
    case invite(callId: String, conversationId: ConversationId, callerId: UserId, callerName: String?, type: CallType)
    case accepted(callId: String, acceptedBy: UserId)
    case declined(callId: String)
    case ended(callId: String, reason: String?)
    case missed(callId: String)
    case busy(conversationId: ConversationId)
    case offer(callId: String, senderId: UserId, sdp: SDPPayload)
    case answerSDP(callId: String, sdp: SDPPayload)
    case ice(callId: String, candidate: ICECandidatePayload)
    // Only the field that changed is present — the other is nil, not false. See handle(_:) for
    // why each side must be applied independently.
    case mediaState(callId: String, cameraEnabled: Bool?, micEnabled: Bool?)

    private struct Raw: Decodable {
        let event: String; let callId: String?; let conversationId: String?; let callerId: String?; let callerName: String?
        let type: String?; let acceptedBy: String?; let reason: String?; let senderId: String?; let sdp: SDPPayload?; let candidate: ICECandidatePayload?
        let cameraEnabled: Bool?; let micEnabled: Bool?
    }

    static func decode(_ data: Data) -> CallEvent? {
        guard let r = try? JSONDecoder().decode(Raw.self, from: data) else { return nil }
        switch r.event {
        case "call_invite":
            guard let c = r.callId, let conv = r.conversationId, let caller = r.callerId else { return nil }
            return .invite(callId: c, conversationId: conv, callerId: caller, callerName: r.callerName, type: CallType(rawValue: r.type ?? "audio") ?? .audio)
        case "call_accepted": guard let c = r.callId, let by = r.acceptedBy else { return nil }; return .accepted(callId: c, acceptedBy: by)
        case "call_declined": guard let c = r.callId else { return nil }; return .declined(callId: c)
        case "call_end": guard let c = r.callId else { return nil }; return .ended(callId: c, reason: r.reason)
        case "call_missed": guard let c = r.callId else { return nil }; return .missed(callId: c)
        case "call_busy": guard let conv = r.conversationId else { return nil }; return .busy(conversationId: conv)
        case "call_offer": guard let c = r.callId, let s = r.senderId, let sdp = r.sdp else { return nil }; return .offer(callId: c, senderId: s, sdp: sdp)
        case "call_answer_sdp": guard let c = r.callId, let sdp = r.sdp else { return nil }; return .answerSDP(callId: c, sdp: sdp)
        case "call_ice_candidate": guard let c = r.callId, let cand = r.candidate else { return nil }; return .ice(callId: c, candidate: cand)
        case "call_media_state": guard let c = r.callId else { return nil }; return .mediaState(callId: c, cameraEnabled: r.cameraEnabled, micEnabled: r.micEnabled)
        default: return nil
        }
    }
}

extension RelayAPI {
    private struct CallEnvelope: Decodable { let call: Call }
    private struct StartBody: Encodable { let conversationId: String; let type: String }
    private struct EndBody: Encodable { let reason: String? }
    private struct TurnEnvelope: Decodable { let turn: TurnCredentials? }

    public func startCall(conversationId: ConversationId, type: CallType) async throws -> Call {
        (try await request("POST", "/calls", body: StartBody(conversationId: conversationId, type: type.rawValue)) as CallEnvelope).call
    }
    public func answerCall(_ id: String) async throws -> Call { (try await request("POST", "/calls/\(id)/answer") as CallEnvelope).call }
    public func declineCall(_ id: String) async throws -> Call { (try await request("POST", "/calls/\(id)/decline") as CallEnvelope).call }
    public func endCall(_ id: String, reason: String? = nil) async throws -> Call {
        (try await request("POST", "/calls/\(id)/end", body: EndBody(reason: reason)) as CallEnvelope).call
    }
    public func turnCredentials() async throws -> TurnCredentials? { (try await request("GET", "/calls/turn-credentials") as TurnEnvelope).turn }
}
