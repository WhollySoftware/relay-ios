import XCTest
@testable import RelayCore

@MainActor
final class ChatStoreTests: XCTestCase {
    var sent: [[String: Any]] = []
    var store: ChatStore!

    override func setUp() async throws {
        MockURLProtocol.reset()
        sent = []
        var config = RelayConfig(baseURL: URL(string: "https://relay.test")!, publicKey: "pk_test", token: .static("tok"))
        config.session = mockSession()
        let api = RelayAPI(config: config, tokens: TokenSource(config.token))
        store = ChatStore(api: api) { [weak self] frame in self?.sent.append(frame) }
        store.setMe(RelayUser(userId: "alice", displayName: "Alice"))
    }

    func testLoadConversationsSortsNewestFirstAndSumsUnread() async throws {
        MockURLProtocol.on("GET /conversations", json: ["conversations": [
            conversationJSON(1, unread: 2, lastMessageAt: "2026-05-01T00:00:00.000Z"),
            conversationJSON(2, unread: 3, lastMessageAt: "2026-06-01T00:00:00.000Z"),
            conversationJSON(3, unread: 0, createdAt: "2026-07-01T00:00:00.000Z"),
        ]])
        try await store.loadConversations()
        XCTAssertEqual(store.conversations.map(\.id), ["3", "2", "1"])
        XCTAssertEqual(store.totalUnread, 5)
        XCTAssertTrue(store.conversationsLoaded)
    }

    func testOptimisticSendIsReplacedByServerMessageWithoutDuplicate() async throws {
        MockURLProtocol.on("GET /conversations", json: ["conversations": [conversationJSON(1)]])
        try await store.loadConversations()
        MockURLProtocol.on("POST /conversations/1/messages") { req in
            let body = try! JSONSerialization.jsonObject(with: req.httpBody ?? Data()) as! [String: Any]
            let clientId = body["clientId"] as! String
            return (201, try! JSONSerialization.data(withJSONObject: ["message": messageJSON(10, sender: "alice", body: "hi"), "clientId": clientId]))
        }
        let task = Task { try await store.sendMessage("1", text: "hi") }
        await Task.yield()
        // Optimistic bubble is visible immediately.
        XCTAssertEqual(store.thread("1").messages.map(\.status), [.sending])
        let sent = try await task.value
        XCTAssertEqual(sent.id, "10")
        let thread = store.thread("1")
        XCTAssertEqual(thread.messages.map(\.id), ["10"])
        XCTAssertEqual(thread.messages[0].status, .sent)
        XCTAssertEqual(store.conversations[0].lastMessage?.body, "hi")
        XCTAssertEqual(store.conversations[0].unreadCount, 0)
        // Echo from the socket carries the same clientId → still exactly one message.
        store.apply(.chatMessage(conversationId: "1", message: sent, clientId: sent.clientId))
        XCTAssertEqual(store.thread("1").messages.count, 1)
    }

    func testFailedSendCanBeRetried() async throws {
        MockURLProtocol.on("GET /conversations", json: ["conversations": [conversationJSON(1)]])
        try await store.loadConversations()
        MockURLProtocol.on("POST /conversations/1/messages", status: 500, json: ["error": "boom", "message": "server down"])
        do { _ = try await store.sendMessage("1", SendMessageInput(body: "flaky", clientId: "c-f")); XCTFail("should throw") } catch {}
        XCTAssertEqual(store.thread("1").messages.first?.status, .failed)
        MockURLProtocol.on("POST /conversations/1/messages", status: 201, json: ["message": messageJSON(7, sender: "alice", body: "flaky"), "clientId": "c-f"])
        let m = try await store.retryMessage("1", clientId: "c-f")
        XCTAssertEqual(m.id, "7")
        XCTAssertEqual(store.thread("1").messages.map(\.id), ["7"])
    }

    func testIncomingMessageIncrementsUnreadUnlessViewing() async throws {
        MockURLProtocol.on("GET /conversations", json: ["conversations": [conversationJSON(1)]])
        try await store.loadConversations()
        let msg = try RelayJSON.decoder.decode(Message.self, from: JSONSerialization.data(withJSONObject: messageJSON(3, sender: "bob", body: "yo")))
        store.apply(.chatMessage(conversationId: "1", message: msg, clientId: nil))
        XCTAssertEqual(store.conversations[0].unreadCount, 1)
        XCTAssertEqual(store.conversations[0].lastMessage?.body, "yo")
        XCTAssertEqual(store.thread("1").messages.count, 0, "thread not open — only the row updates")

        MockURLProtocol.on("POST /conversations/1/read", json: ["ok": true, "lastReadAt": "2026-01-01T00:00:05.000Z"])
        store.setViewing("1")
        XCTAssertEqual(sent.last?["event"] as? String, "viewing")
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(store.conversations[0].unreadCount, 0)
        let msg2 = try RelayJSON.decoder.decode(Message.self, from: JSONSerialization.data(withJSONObject: messageJSON(4, sender: "bob", body: "again")))
        store.apply(.chatMessage(conversationId: "1", message: msg2, clientId: nil))
        XCTAssertEqual(store.conversations[0].unreadCount, 0, "viewing → no increment")
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertGreaterThanOrEqual(MockURLProtocol.callCount("POST /conversations/1/read"), 2)
    }

    func testTypingAppearsAndClearsOnMessage() async throws {
        MockURLProtocol.on("GET /conversations", json: ["conversations": [conversationJSON(1)]])
        try await store.loadConversations()
        store.apply(.typing(conversationId: "1", userId: "bob"))
        XCTAssertEqual(store.typing["1"], ["bob"])
        store.apply(.typing(conversationId: "1", userId: "alice"))
        XCTAssertEqual(store.typing["1"], ["bob"], "own typing ignored")
        let msg = try RelayJSON.decoder.decode(Message.self, from: JSONSerialization.data(withJSONObject: messageJSON(5, sender: "bob", body: "done")))
        store.apply(.chatMessage(conversationId: "1", message: msg, clientId: nil))
        XCTAssertEqual(store.typing["1"] ?? [], [])
        store.sendTyping("1"); store.sendTyping("1")
        XCTAssertEqual(sent.filter { $0["event"] as? String == "typing" }.count, 1, "throttled")
    }

    func testPresenceAndLifecycleEvents() async throws {
        MockURLProtocol.on("GET /conversations", json: ["conversations": [conversationJSON(1)]])
        try await store.loadConversations()
        store.apply(.presence(userId: "bob", online: true, lastSeenAt: nil))
        XCTAssertEqual(store.conversations[0].peer?.isOnline, true)
        XCTAssertEqual(store.presence["bob"]?.online, true)
        store.apply(.chatRead(conversationId: "1", userId: "bob", lastReadAt: Date()))
        XCTAssertNotNil(store.readReceipts["1"]?["bob"] ?? nil)
        MockURLProtocol.on("GET /conversations/2", json: ["conversation": conversationJSON(2, peer: "carol", lastMessageAt: "2026-09-01T00:00:00.000Z")])
        store.apply(.conversationCreated(conversationId: "2"))
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(store.conversations.map(\.id), ["2", "1"])
        store.apply(.conversationDeleted(conversationId: "2"))
        XCTAssertEqual(store.conversations.map(\.id), ["1"])
    }

    func testResyncMergesNewestPageWithoutDroppingOlder() async throws {
        MockURLProtocol.on("GET /conversations", json: ["conversations": [conversationJSON(1)]])
        try await store.loadConversations()
        MockURLProtocol.on("GET /conversations/1/messages", json: ["messages": [messageJSON(20, sender: "bob", body: "old"), messageJSON(21, sender: "bob", body: "older-new")], "hasMore": true])
        MockURLProtocol.on("GET /conversations/1/read-receipts", json: ["receipts": []])
        try await store.loadMessages("1")
        XCTAssertEqual(store.thread("1").messages.map(\.id), ["20", "21"])
        MockURLProtocol.on("GET /conversations/1/messages", json: ["messages": [messageJSON(21, sender: "bob", body: "older-new"), messageJSON(22, sender: "bob", body: "missed")], "hasMore": true])
        await store.resync()
        XCTAssertEqual(store.thread("1").messages.map(\.id), ["20", "21", "22"])
        XCTAssertTrue(store.thread("1").hasMore)
    }
}
