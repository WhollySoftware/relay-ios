import Foundation
import Observation
import RelayCore
import RelayCall

/// Everything the demo needs after sign-in: a `RelayClient` (chat) plus a `CallCenter` (calling)
/// built on top of it, and the push registry that wakes the app for incoming calls. One instance
/// per signed-in user — torn down on sign-out.
@MainActor
@Observable
final class AppSession {
    let userId: String
    let displayName: String
    let relay: RelayClient
    let calls: CallCenter
    let pushRegistry: RelayPushRegistry
    private(set) var pushStatus = "Not started"

    init(userId: String, displayName: String, relayUrl: URL, publicKey: String) {
        self.userId = userId
        self.displayName = displayName

        // The token PROVIDER (not a plain string): RelayClient calls this again whenever the
        // 15-minute token expires or the service rejects it with a 401/4401. Re-minting just
        // means asking our own token server for a fresh one — the user never re-authenticates.
        let config = RelayConfig(
            baseURL: relayUrl,
            publicKey: publicKey,
            tokenProvider: {
                try await TokenServerClient.mintToken(userId: userId, displayName: displayName).userToken
            }
        )
        let relay = RelayClient(config: config)
        self.relay = relay
        self.calls = CallCenter(client: relay)
        self.calls.localizedAppName = "Relay Demo"
        self.pushRegistry = RelayPushRegistry(client: relay, calls: calls)
    }

    /// Starts the realtime connection. Call once after constructing the session.
    func connect() async {
        _ = try? await relay.connect()
    }

    /// VoIP push registration. On a SIMULATOR this always fails silently (no real APNs
    /// connection exists), which is expected — see README "Push notifications" section for what
    /// a physical device + real APNs credentials would additionally require.
    func registerForPush() {
        pushRegistry.start()
        // PushKit hands back a token asynchronously via the delegate; give it a moment before
        // reporting status so the About screen shows something meaningful.
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            pushStatus = pushRegistry.voipToken != nil
                ? "VoIP token registered: \(pushRegistry.voipToken!.prefix(12))…"
                : "No VoIP token (expected on Simulator — see README)"
        }
    }

    func signOut() async {
        calls.detach()
        await pushRegistry.unregisterAll()
        relay.disconnect()
    }
}
