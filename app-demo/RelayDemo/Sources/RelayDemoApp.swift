import SwiftUI
import RelayCall

@main
struct RelayDemoApp: App {
    @State private var session: AppSession?

    var body: some Scene {
        WindowGroup {
            ZStack {
                if let session {
                    ChatRootView(session: session)
                        // Mounted once at the root, per RelayCallView.swift's doc comment: it
                        // shows outgoing/connecting/active/reconnecting full-screen and floats
                        // above whatever chat screen is underneath. (Incoming calls surface via
                        // CallKit's native system UI on iOS, not this view.)
                        .overlay(RelayCallOverlay(center: session.calls))
                } else {
                    SignInView { newSession in
                        session = newSession
                        Task {
                            await newSession.connect()
                            newSession.registerForPush()
                        }
                    }
                }
            }
        }
    }
}
