import SwiftUI

/// Sign-in screen. Mirrors the web demo's "Sign in as Alice / Bob" presets: two people running
/// this same app (two simulators, or a simulator + the web demo) can message and call each other
/// because both mint tokens for the same Relay project from the same token server.
struct SignInView: View {
    let onSignedIn: (AppSession) -> Void

    @State private var userId = ""
    @State private var isConnecting = false
    @State private var errorMessage: String?
    @State private var showHowItWorks = false

    private let presets = ["alice", "bob"]

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.tint)
                    Text("Relay Demo").font(.largeTitle.bold())
                    Text("Chat + calling, wired up end to end")
                        .font(.subheadline).foregroundStyle(.secondary)
                }

                VStack(spacing: 12) {
                    TextField("User id (e.g. alice)", text: $userId)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(.horizontal, 32)

                    HStack {
                        ForEach(presets, id: \.self) { preset in
                            Button(preset.capitalized) { userId = preset }
                                .buttonStyle(.bordered)
                        }
                    }

                    Button {
                        Task { await signIn() }
                    } label: {
                        if isConnecting {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Text("Sign in").frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(userId.trimmingCharacters(in: .whitespaces).isEmpty || isConnecting)
                    .padding(.horizontal, 32)

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote).foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                }

                Spacer()

                Button("How this works") { showHowItWorks = true }
                    .font(.footnote)
                    .padding(.bottom, 24)
            }
            .sheet(isPresented: $showHowItWorks) { HowThisWorksView() }
        }
    }

    private func signIn() async {
        isConnecting = true
        errorMessage = nil
        defer { isConnecting = false }
        do {
            // Step 1: ask the token server for the project's public config. The public key
            // (`pk_…`) is safe to embed/log/ship — it identifies the project, not a user.
            let config = try await TokenServerClient.fetchConfig()
            guard let relayUrl = URL(string: config.relayUrl) else { throw TokenServerError.badResponse }

            // Step 2: mint this user's short-lived token up front just to fail fast with a clear
            // error if the token server or Relay service isn't running; RelayClient will also
            // call the provider itself on connect (and again on every future expiry).
            _ = try await TokenServerClient.mintToken(userId: userId, displayName: userId.capitalized)

            let session = AppSession(userId: userId, displayName: userId.capitalized, relayUrl: relayUrl, publicKey: config.publicKey)
            onSignedIn(session)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
