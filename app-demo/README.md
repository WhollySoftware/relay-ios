# ios-demo — Relay iOS SDK reference integration

A SwiftUI app ("RelayDemo") that shows the whole integration surface for the iOS SDK
(`packages/ios` — products `RelayCore`, `RelayUI`, `RelayCall`): sign-in against your own
backend, `RelayChatView`-style chat, 1:1 audio/video calling with `CallCenter` +
`RelayCallOverlay`, and VoIP push registration scaffolding via `RelayPushRegistry`.

It reuses the **same token server the web demo uses** (`sample-apps/web-demo/token-server.mjs`)
rather than inventing a second backend — the point of the demo is that every client SDK talks to
one small server your team writes the same way. See "Token server" below if you'd rather not run
Node at all.

## Prerequisites

- Xcode 26 (tested with 26.6), iOS 17+ simulator.
- `xcodegen` (`brew install xcodegen`) — the `.xcodeproj` is generated from `project.yml`, not
  hand-committed.
- The Relay service running locally, and the web demo's token server running against it (see
  next section).

## 1. Start the Relay service + token server

From the repo root, in one terminal (this is the same setup `sample-apps/web-demo/README.md`
uses — skip steps you've already done for that demo):

```bash
# Postgres + Redis (throwaway, no Docker):
eval "$(service/test/ephemeral-db.sh start)"

export PORT=4100 JWT_SECRET=dev-secret-change-me
npm install
npm run migrate --workspace=service
npm run dev --workspace=service                 # http://localhost:4100
```

In a second terminal, start just the token server (you don't need Vite/React for the iOS demo):

```bash
npm run token-server --workspace=sample-apps/web-demo   # http://localhost:4101
```

`GET http://localhost:4101/api/config` should return `{ relayUrl, publicKey }` once it's up. The
iOS Simulator can reach the Mac's `localhost` directly, so no IP address juggling is needed. (A
physical device cannot reach `localhost` on your Mac — point `TokenServerClient.baseURL` at your
Mac's LAN IP, e.g. `http://192.168.1.23:4101`, if you run this on real hardware.)

**Testing chat alongside the web demo or the Android demo?** Set `RELAY_PUBLIC_URL` (e.g.
`http://192.168.1.23:4100`, your Mac's LAN IP) on the Relay service before sending any
attachments. Without it, an attachment's URL is built from whichever host the uploading client
happened to connect through — `localhost` for this Simulator, `10.0.2.2` for an Android emulator —
and that URL is only reachable from that same client. The other platform sees a broken image, not
because anything is broken, just because it can't reach that address. One `RELAY_PUBLIC_URL`
every platform can reach fixes it for all of them.

### Don't want to run the Node token server?

`RelayDemo/Sources/TokenServerClient.swift` is the only place that assumes it exists. Swap its
two calls (`fetchConfig`, `mintToken`) for a same-process alternative that calls
`POST {relayUrl}/projects` once and `POST {relayUrl}/users/token` per sign-in with a hardcoded
secret key — exactly what `token-server.mjs` does, just in Swift. This is explicitly a
**demo-only** shortcut: a real app must never ship a secret key (`sk_…`) inside a client binary.

## 2. Generate and build the Xcode project

```bash
cd packages/ios/app-demo
xcodegen generate
xcodebuild -project RelayDemo.xcodeproj -scheme RelayDemo \
  -destination 'platform=iOS Simulator,name=iPhone 17' build
```

Or open `RelayDemo.xcodeproj` in Xcode and hit Run. `RelayDemo.xcodeproj` is generated (and
gitignored) — always run `xcodegen generate` after pulling changes to `project.yml` or adding new
source files under `RelayDemo/Sources`.

The package dependency in `project.yml` points at `..` (a local path, not a git
URL) so it always builds against the SDK sitting in this checkout, plus WebRTC
(`github.com/stasel/WebRTC`, pinned the same way `packages/ios/Package.swift` pins it) resolved
transitively through `RelayCall`.

## 3. Try it

1. Launch the app, tap **Alice** (or type any id), **Sign in**. This calls the token server for
   `{relayUrl, publicKey}` and mints a user token, then constructs a `RelayConfig` +
   `RelayClient` and connects.
2. **Chats** tab: `ConversationListView` (empty at first) → tap **+** and open a chat with `bob`
   (or whatever id you sign the other side in as — a second simulator, or the web demo at
   `http://localhost:5173`, works as the other party since they share the same Relay project).
   Send messages; `MessageThreadView` handles typing/read receipts/live updates.
3. In the thread, tap the phone or video icon in the toolbar to start a call
   (`CallCenter.start(conversation:type:)`). `RelayCallOverlay`, mounted once at the app root in
   `RelayDemoApp.swift`, takes over full-screen for outgoing/connecting/active/reconnecting.
   Incoming calls surface via CallKit's native system UI (this needs a *second* signed-in party
   actually calling you — see the two-simulator setup below).
4. **About** tab: shows the signed-in user, connection state, VoIP push registration status, and
   a recap of the three core concepts (public key / user token / calling+push).

### Two simulators calling each other

Boot two simulators, install the same build on both, sign in as `alice` on one and `bob` on the
other, open a chat, and call. `xcrun simctl list devices` / `xcrun simctl boot <udid>` /
`xcrun simctl install <udid> <path-to-.app>` if you're doing this outside Xcode's UI.

## What each file demonstrates

```
project.yml                       xcodegen spec: app target, local SPM dependency on the parent packages/ios,
                                   Info.plist keys, entitlements
RelayDemo/Sources/
  RelayDemoApp.swift               app entry point; mounts RelayCallOverlay once at the root
  SignInView.swift                 fetches public config, mints a token, builds the AppSession
  TokenServerClient.swift          the ONLY file that talks to "your backend" (localhost:4101)
  AppSession.swift                 owns RelayClient + CallCenter + RelayPushRegistry for one user
  ChatRootView.swift                tab bar; composes ConversationListView + MessageThreadView
                                   with a call button (RelayChatView itself doesn't expose that
                                   hook, so we assemble the pieces ourselves)
  AboutView.swift                  connection/push status + the three-concepts explainer
  HowThisWorksView.swift           same explainer, reachable pre-sign-in
```

## Push notifications on a Simulator — known limitation

> Setting up real APNs credentials for a tenant (the .p8 key, Team ID, etc.)? See
> [`docs/push-credentials.md`](../../../docs/push-credentials.md) in the repo root.

`AppSession.registerForPush()` calls `RelayPushRegistry.start()`, which asks `PKPushRegistry` for
a VoIP token and registers it with the Relay service. **This never produces a real token on the
iOS Simulator** — there is no APNs connection to the Simulator, full stop. The About screen will
show "No VoIP token (expected on Simulator)" rather than silently pretending it worked.

To actually receive an incoming-call push and see `CXProvider` ring from a cold start, you need:

1. A physical device.
2. `NSMicrophoneUsageDescription` / `NSCameraUsageDescription` (already in `project.yml`) plus the
   **Push Notifications** and **Background Modes → Voice over IP** capabilities enabled for a real
   provisioning profile (xcodegen writes the `voip` background mode and an `aps-environment`
   entitlement, but Xcode's automatic signing still needs a real team/profile to make Push
   Notifications an active capability — add it in Signing & Capabilities once you have a team).
3. Real APNs credentials (a `.p8` key or certificate) configured for the project in the tenant
   admin dashboard, so the Relay service can actually send the VoIP push when `CallCenter.start`
   is invoked against a device that's backgrounded.

None of that can be faked in a demo, so this README says so plainly instead of stubbing in a fake
"success" state.

## Verified

```
cd packages/ios/app-demo
xcodegen generate
xcodebuild -project RelayDemo.xcodeproj -scheme RelayDemo \
  -destination 'platform=iOS Simulator,name=iPhone 17' build
# ** BUILD SUCCEEDED **
```

The built app was also installed and launched on an iPhone 17 simulator and the sign-in screen
was confirmed to render correctly.
