import SwiftUI

/// Settings/About tab: shows the signed-in identity, push registration status, and the same
/// "how this works" explainer offered pre-sign-in — the three concepts every integrator needs to
/// internalize before wiring up their own backend.
struct AboutView: View {
    let session: AppSession

    var body: some View {
        NavigationStack {
            List {
                Section("Signed in as") {
                    LabeledContent("User id", value: session.userId)
                    LabeledContent("Connection", value: "\(session.relay.connection.state)")
                }

                Section {
                    LabeledContent("VoIP push", value: session.pushStatus)
                } header: {
                    Text("Push registration")
                } footer: {
                    // Honest about the Simulator's ceiling — see README.md, "Push notifications
                    // on a simulator" for the full explanation of what a physical device adds.
                    Text("The Simulator has no real APNs connection, so this will read \"No VoIP token\" here even though `RelayPushRegistry.start()` ran successfully. A physical device with push entitlements and a project configured with real APNs credentials (tenant dashboard → Push) is required to see an actual token and receive a wake-up.")
                }

                Section("How this works") {
                    conceptRow(
                        title: "Public key",
                        detail: "pk_… — embedded in this app (see RelayPublicConfig / TokenServerClient.fetchConfig()). Identifies the project, not a person; safe to ship."
                    )
                    conceptRow(
                        title: "User token",
                        detail: "Minted by your backend (here, the same Node token server the web demo uses) with the project's SECRET key, which this app never sees. Expires in 15 minutes — RelayConfig's tokenProvider closure re-mints it automatically."
                    )
                    conceptRow(
                        title: "Calling + VoIP push",
                        detail: "CallCenter drives WebRTC + CallKit for the call UI; RelayPushRegistry registers a PushKit VoIP token so the OS can wake the app for an incoming call even when it isn't running."
                    )
                }

                Section {
                    Button("Sign out", role: .destructive) {
                        Task { await session.signOut() }
                    }
                }
            }
            .navigationTitle("About")
        }
    }

    private func conceptRow(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).bold()
            Text(detail).font(.footnote).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
