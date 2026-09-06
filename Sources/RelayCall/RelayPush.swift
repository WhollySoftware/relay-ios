import Foundation
import RelayCore
#if canImport(PushKit) && os(iOS)
import PushKit
import CallKit
#endif

// Push wake-up for calls. The service sends an APNs VoIP push (see protocol/events.md, "Push
// wake-ups") to the PushKit token registered through RelayPushRegistry; iOS launches the app in
// the background and PushKit hands the payload here. Apple's rule: every VoIP push MUST report an
// incoming call to CallKit before the delegate returns, or the app is killed and further VoIP
// pushes are dropped — so handleVoipPush always reports something, even for a cancel or a
// duplicate, and retires the throwaway call immediately.
//
// Usage (AppDelegate / @main App init, BEFORE the first push can arrive):
//
//     let registry = RelayPushRegistry(client: relay, calls: callCenter)
//     registry.start()                                  // requests the VoIP token, registers it
//     // in application(_:didRegisterForRemoteNotificationsWithDeviceToken:):
//     registry.registerAlertToken(deviceToken)           // for chat notifications
//     // on sign-out:
//     await registry.unregisterAll()

extension CallCenter {
    public enum PushOutcome: Equatable { case incomingCall(callId: String), cancelled(callId: String), ignored }

    /// Handle the dictionary payload of a VoIP push. Must be called on the main actor from
    /// `pushRegistry(_:didReceiveIncomingPushWith:for:completion:)` before that completion runs.
    @discardableResult
    public func handleVoipPush(_ payload: [AnyHashable: Any]) -> PushOutcome {
        let kind = payload["relay"] as? String
        let callId = (payload["callId"] as? String) ?? (payload["callId"]).map { "\($0)" }
        switch kind {
        case "call_invite":
            guard let callId, let conversationId = payload["conversationId"] as? String, let callerId = payload["callerId"] as? String else {
                reportThrowawayCall(); return .ignored
            }
            let type = CallType(rawValue: payload["type"] as? String ?? "audio") ?? .audio
            let callerName = (payload["callerName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            // Already ringing for this call (the socket delivered the invite first) or busy with
            // another one: satisfy PushKit with a throwaway report and leave the real state alone.
            guard call == nil, callerId != client.userId else { reportThrowawayCall(); return .ignored }
            handleInvite(callId: callId, conversationId: conversationId, callerId: callerId, callerName: callerName, type: type)
            // The socket is what carries the offer/ICE once the user answers; open it now so the
            // answer path doesn't pay the connect latency (idempotent if already connected).
            Task { try? await client.connect() }
            return .incomingCall(callId: callId)
        case "call_cancel":
            reportThrowawayCall()
            guard let callId, let current = call, current.id == callId, current.phase == .incoming else { return .ignored }
            finish(failed: false)
            return .cancelled(callId: callId)
        default:
            reportThrowawayCall()
            return .ignored
        }
    }

    /// Report-and-retire a call so PushKit's "always report" rule holds for pushes that carry no
    /// new ring (cancel, duplicate, malformed).
    private func reportThrowawayCall() {
        #if canImport(CallKit) && os(iOS)
        let uuid = UUID()
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: localizedAppName)
        update.localizedCallerName = localizedAppName
        reportNewIncomingCall(uuid: uuid, update: update) { [weak self] _ in
            Task { @MainActor in self?.reportCallEnded(uuid: uuid, reason: .remoteEnded) }
        }
        #endif
    }
}

#if canImport(PushKit) && os(iOS)
/// Owns the `PKPushRegistry`, keeps the service's device registry in sync, and forwards VoIP
/// pushes to the `CallCenter`.
@MainActor
public final class RelayPushRegistry: NSObject, PKPushRegistryDelegate {
    private let client: RelayClient
    private let calls: CallCenter
    private var registry: PKPushRegistry?
    private(set) public var voipToken: String?
    private(set) public var alertToken: String?

    public init(client: RelayClient, calls: CallCenter) {
        self.client = client
        self.calls = calls
        super.init()
    }

    /// Ask PushKit for the VoIP token. Safe to call on every launch.
    public func start() {
        let registry = PKPushRegistry(queue: .main)
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
        self.registry = registry
        if let cached = registry.pushToken(for: .voIP) { register(cached, type: .apnsVoip) }
    }

    /// Forward the regular APNs token (from `didRegisterForRemoteNotificationsWithDeviceToken`) so
    /// the user also gets chat alerts.
    public func registerAlertToken(_ deviceToken: Data) {
        register(deviceToken, type: .apns)
    }

    /// Re-send whatever tokens are known — call after sign-in, since registration needs a user token.
    public func resync() {
        if let voipToken { Task { try? await client.api.registerDevice(token: voipToken, type: .apnsVoip) } }
        if let alertToken { Task { try? await client.api.registerDevice(token: alertToken, type: .apns) } }
    }

    /// Sign-out: remove this device's tokens for the current user (the tokens themselves stay valid
    /// and are re-registered by `resync()` after the next sign-in).
    public func unregisterAll() async {
        for token in [voipToken, alertToken].compactMap({ $0 }) { try? await client.api.unregisterDevice(token: token) }
    }

    private func register(_ data: Data, type: DeviceTokenType) {
        let hex = data.map { String(format: "%02x", $0) }.joined()
        if type == .apnsVoip { voipToken = hex } else { alertToken = hex }
        Task { try? await client.api.registerDevice(token: hex, type: type) }
    }

    // MARK: PKPushRegistryDelegate (delegate queue is main, so these hop onto the actor safely)

    nonisolated public func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        guard type == .voIP else { return }
        let data = pushCredentials.token
        Task { @MainActor in self.register(data, type: .apnsVoip) }
    }

    nonisolated public func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        guard type == .voIP else { return }
        Task { @MainActor in
            if let token = self.voipToken { self.voipToken = nil; try? await self.client.api.unregisterDevice(token: token) }
        }
    }

    nonisolated public func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType, completion: @escaping () -> Void) {
        guard type == .voIP else { completion(); return }
        let dict = payload.dictionaryPayload
        // PKPushRegistry(queue: .main) delivers on the main thread, so this runs synchronously
        // before completion() — which is what Apple requires for reportNewIncomingCall.
        MainActor.assumeIsolated {
            self.calls.handleVoipPush(dict)
        }
        completion()
    }
}
#endif
