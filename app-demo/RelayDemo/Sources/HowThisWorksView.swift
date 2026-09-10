import SwiftUI

/// Pre-sign-in explainer, reachable from the sign-in screen. The signed-in "About" tab repeats
/// this once there's a live connection/push status to show alongside it.
struct HowThisWorksView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("This app talks to a small Node token server (the same one the web demo uses) instead of Relay directly for sign-in. That server is a stand-in for YOUR backend.")
                }
                Section("1. Public key") {
                    Text("pk_… — fetched from GET /api/config and embedded in RelayConfig. Safe to log or ship; it only identifies the project.")
                }
                Section("2. User token") {
                    Text("Minted server-side (POST /api/token) using the project's secret key, which never reaches this app. Expires in 15 minutes; RelayConfig's tokenProvider closure is called again automatically to refresh it.")
                }
                Section("3. Calling & push") {
                    Text("CallCenter wraps WebRTC + CallKit for 1:1 audio/video. RelayPushRegistry registers a PushKit VoIP token so iOS can wake the app for an incoming call — real delivery needs a physical device and APNs credentials configured for the project; the Simulator cannot receive real pushes.")
                }
            }
            .navigationTitle("How this works")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
