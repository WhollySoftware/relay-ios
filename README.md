# Relay iOS SDK

Two SwiftPM products, same split as the web packages:

| Product | What it is | Depends on |
|---|---|---|
| `RelayCore` | Headless client: REST (`RelayAPI`), realtime gateway (`RelaySocket`), and an `@Observable` `ChatStore`. Foundation only — builds and tests on macOS too. | – |
| `RelayUI` | Drop-in SwiftUI chat kit: `RelayChatView`, `ConversationListView`, `MessageThreadView`, `MessageComposerView`, `MessageBubbleView`, theming via `RelayTheme`. | `RelayCore` |
| `RelayCall` | 1:1 audio/video calls: `CallCenter` (WebRTC + CallKit state machine), `RelayCallOverlay` / `RelayCallView`. Separate product so chat-only apps skip the WebRTC binary. | `RelayCore`, `WebRTC` |

Requires iOS 17 (SwiftUI `@Observable`). Xcode 15+.

## Install

Xcode → *File → Add Package Dependencies…* → the URL of this repo (or a local path to `packages/ios`) → add `RelayUI` (and `RelayCore` if you want the headless client alone).

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
