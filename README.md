# Relay iOS SDK

Two SwiftPM products, same split as the web packages:

| Product | What it is | Depends on |
|---|---|---|
| `RelayCore` | Headless client: REST (`RelayAPI`), realtime gateway (`RelaySocket`), and an `@Observable` `ChatStore`. Foundation only — builds and tests on macOS too. | – |
| `RelayUI` | Drop-in SwiftUI chat kit: `RelayChatView`, `ConversationListView`, `MessageThreadView`, `MessageComposerView`, `MessageBubbleView`, theming via `RelayTheme`. | `RelayCore` |
| `RelayCall` | 1:1 audio/video calls: `CallCenter` (WebRTC + CallKit state machine), `RelayCallOverlay` / `RelayCallView`. Separate product so chat-only apps skip the WebRTC binary. | `RelayCore`, `WebRTC` |

Requires iOS 17 (SwiftUI `@Observable`). Xcode 15+.

## Install

This is a standard Swift Package pinned by git tag — nothing binary or pre-built, so Xcode
resolves and builds it like any other SPM dependency. The repo (`WhollySoftware/relay-ios`) is
**public** — no GitHub account, invite, or token needed to add it. No secret ever lives in the
package itself: your actual access to the Relay service is controlled entirely by your project's
`publicKey`/`secretKey`, not by anything to do with fetching the SDK's source.

**Add the package.** Xcode → *File → Add Package Dependencies…* → paste
`https://github.com/WhollySoftware/relay-ios.git` → pick a version rule (**Up to Next Major**
from the latest tag is recommended so you get fixes without breaking changes) → add the
`RelayUI` product (and `RelayCore` alone if you only want the headless client; `RelayCall` if you
want calling).

Pinning to a tagged version (rather than a branch) means your build is reproducible and immune to
upstream changes landing mid-build — check `git tag -l` in the repo (or the GitHub Releases page)
for the latest version.

For local development against an unpublished change, swap the remote package for a local one:
*File → Add Package Dependencies…* → *Add Local…* → the path to `packages/ios`.

## The 10-line integration

```swift
import RelayUI

@main struct MyApp: App {
    // One client per signed-in user. The token provider calls YOUR backend, which mints a
    // Relay user token with the project's secret key (see service/README.md) — the secret
    // never ships in the app; only the public key does.
    let relay = RelayClient(config: RelayConfig(
        baseURL: URL(string: "https://relay.example.com")!,
        publicKey: "pk_…",
        tokenProvider: { try await MyBackend.relayToken() }   // POST /users/token on your server
    ))

    var body: some Scene {
        WindowGroup { RelayChatView(client: relay) }
    }
}
```

`RelayChatView` connects on appear and shows the conversation list → thread → composer, with
presence dots, unread badges, typing indicators, read receipts, optimistic sends with retry,
edit/delete, replies, image and audio messages, and a reconnecting banner.

## Security

The SDK sends `X-App-Bundle-Id` (from `Bundle.main.bundleIdentifier`) on every REST call and on
the gateway connection automatically — no configuration needed. If the project has an iOS bundle
ID allowlist configured (in the admin panel or via `PATCH /projects/me/settings`), a request from
an app whose bundle ID isn't on that list is rejected; an empty allowlist leaves it unrestricted.

## Debugging

`RelayConfig` has an opt-in verbose logging mode for diagnosing connection/call/module issues in
a host app. It's off by default and changes nothing until you turn it on:

```swift
var config = RelayConfig(baseURL: url, publicKey: "pk_…", tokenProvider: { try await MyBackend.relayToken() })
config.debug = true
config.logger = { print("[Relay] \($0)") }
let relay = RelayClient(config: config)
```

With both set, the SDK emits lines like:

```
[Relay] connecting to wss://relay.example.com/ws/gateway
[Relay] connected
[Relay] -> GET /conversations
[Relay] <- GET /conversations 200
[Relay] event: chat_message (conversationId=c_123, messageId=m_456)
[Relay] modules updated: chat=true, audioCalls=true, videoCalls=false, chatAttachments=true, chatVoiceMessages=true, push=true
[Relay] call call_789 ringing (outgoing)
[Relay] TURN credentials fetched (3 ICE server URLs)
[Relay] disconnected (code=1006, reason=The network connection was lost.)
```

With `debug` left `false` (the default), only the existing minimal reconnect-backoff message ever
reaches `logger` — everything above is silent.

**Guarantee**: debug logs never include auth tokens, TURN credentials, message content, attachment
URLs, or user display names/avatars — only connection state, request paths (no query strings),
event types, and non-content ids.

## Attachments

`MessageComposerView` includes an attach button (Camera / Photo Library / File) alongside the
text field. Photo Library (`PhotosPicker`) and File (`.fileImporter`) need **no permission at
all** — both are out-of-process pickers, so this SDK never gets broader photo-library or
file-system access than the one item the user picked. **Camera is the one exception**: add
`NSCameraUsageDescription` to your app's Info.plist (the same key `RelayCall` already needs for
video calls, so an app with calling already has it) — without it, iOS kills the app the moment
Camera is tapped rather than showing a permission prompt. A video pick/capture gets a small
client-extracted thumbnail automatically; this SDK never decodes video server-side either.

## Link previews

A message whose body contains an `http(s)://` URL automatically gets a social-app-style preview
card (image, title, description, site name) under the bubble — and the same card appears above
`MessageComposerView`'s text field, live, the moment a link is typed or pasted into the draft,
before it's even sent. No setup needed: the metadata is fetched and cached server-side (`GET
/link-preview`), so this view never talks to the linked site directly. A link with no usable Open
Graph metadata (or that fails to load) renders no card at all — never an empty placeholder.

## Calling

```swift
import RelayCall

let calls = CallCenter(client: relay)               // once; uses CallKit on iOS
RelayChatView(client: relay)
    .overlay { RelayCallOverlay(center: calls) }     // full-screen call UI + errors
// From a thread header:
calls.start(conversation: conversation, type: .video)
```

Add the `voip` and `audio` background modes to your Info.plist. Incoming calls ring through
CallKit while the app is running.

### Ringing when the app is closed (PushKit)

Once the project has APNs credentials (`PATCH /projects/me/settings` with the .p8 key, team id,
key id and bundle id, done from your backend), the service sends a VoIP push for every incoming
call and a cancel when the ring ends. Wire PushKit once, before any push can arrive:

```swift
// AppDelegate.didFinishLaunching / @main App init
let push = RelayPushRegistry(client: relay, calls: calls)
push.start()                                   // registers the VoIP token with the service
// application(_:didRegisterForRemoteNotificationsWithDeviceToken:)
push.registerAlertToken(deviceToken)           // chat alerts through your normal APNs token
// after sign-in: push.resync()     on sign-out: await push.unregisterAll()
```

`RelayPushRegistry` reports the call to CallKit synchronously inside the PushKit callback (Apple's
rule for VoIP pushes), starts the gateway connection so answering is instant, and ignores the
socket's duplicate `call_invite`. If you already own a `PKPushRegistry`, call
`calls.handleVoipPush(payload.dictionaryPayload)` from your delegate instead. Chat alert pushes
carry `relay = "chat_message"`, `conversationId` and `messageId` for deep-linking.

## Headless (bring your own UI)

```swift
let relay = RelayClient(config: config)
try await relay.connect()
try await relay.chat.loadConversations()
let convo = try await relay.chat.openConversation(with: "user-42")   // your own user id
try await relay.chat.sendMessage(convo.id, text: "hello")
// relay.chat is @Observable: read relay.chat.conversations / relay.chat.thread(id).messages in SwiftUI.
relay.onEvent { event in print(event.name) }
```

Key `ChatStore` calls: `loadConversations(includeEmpty:)`, `openConversation(with:)`,
`createGroup(name:userIds:)`, `loadMessages(_:)`, `loadOlderMessages(_:)`, `sendMessage(_:_:)`,
`retryMessage(_:clientId:)`, `editMessage`, `deleteMessage`, `markRead`, `sendTyping`,
`setViewing(_:)`, plus `typing`, `readReceipts`, `presence`, `totalUnread`.

## App lifecycle

Call `await relay.goToBackground()` when the app goes to the background (it closes the socket
and tells the server immediately so peers see you offline) and `try await relay.connect()`
when it returns to the foreground. The store resyncs automatically after any reconnect — the
server never replays missed events.

## Theming

```swift
var theme = RelayTheme()
theme.bubbleMine = .indigo
theme.cornerRadius = 12
RelayChatView(client: relay).relayTheme(theme)
```

## Tests

```bash
cd packages/ios
swift test                                   # unit tests (mocked transport)
DATABASE_URL=… REDIS_URL=… swift test        # + the live end-to-end test, which boots the service
```

`service/test/ephemeral-db.sh start` prints throwaway `DATABASE_URL`/`REDIS_URL` values.

## Status

Chat (`RelayCore`, `RelayUI`), calling (`RelayCall`) and PushKit wake-up (`RelayPushRegistry`)
are implemented and build for the iOS simulator. Not yet exercised on a physical device against a
real APNs key — that needs a signed build. There is no sample Xcode project; the snippets above are
the integration.
