import XCTest
@testable import RelayCore

/// Boots the real service (node) against DATABASE_URL / REDIS_URL from the environment and drives
/// two RelayClients end-to-end. Skipped when those variables are absent, so plain `swift test`
/// stays hermetic; CI sets them (see service/test/ephemeral-db.sh).
@MainActor
final class IntegrationTests: XCTestCase {
    static let port = 4197
    static var base: URL { URL(string: "http://127.0.0.1:\(port)")! }
    nonisolated(unsafe) static var server: Process?
    nonisolated(unsafe) static var project: (publicKey: String, secretKey: String)?

    override class func setUp() {
        super.setUp()
        guard let db = ProcessInfo.processInfo.environment["DATABASE_URL"], let redis = ProcessInfo.processInfo.environment["REDIS_URL"] else { return }
        let serviceDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("service").path
        let env = ["DATABASE_URL": db, "REDIS_URL": redis, "JWT_SECRET": "test-secret", "PORT": String(port), "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin"]
        let migrate = Process(); migrate.executableURL = URL(fileURLWithPath: "/usr/bin/env"); migrate.arguments = ["node", "src/migrate.js"]
        migrate.currentDirectoryURL = URL(fileURLWithPath: serviceDir); migrate.environment = env
        try? migrate.run(); migrate.waitUntilExit()
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/env"); p.arguments = ["node", "src/server.js"]
        p.currentDirectoryURL = URL(fileURLWithPath: serviceDir); p.environment = env
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try? p.run()
        server = p
        for _ in 0..<50 {
            if let data = try? Data(contentsOf: base.appendingPathComponent("health")), !data.isEmpty { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        var req = URLRequest(url: base.appendingPathComponent("projects")); req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type"); req.httpBody = Data(#"{"name":"iOS SDK Test"}"#.utf8)
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, _, _ in
            if let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let pk = json["publicKey"] as? String, let sk = json["secretKey"] as? String {
                project = (pk, sk)
            }
            sem.signal()
        }.resume()
        sem.wait()
    }

    override class func tearDown() {
        server?.terminate()
        super.tearDown()
    }

    private func mint(_ id: String, _ name: String) async throws -> String {
        var req = URLRequest(url: Self.base.appendingPathComponent("users/token")); req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(Self.project!.secretKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["externalId": id, "displayName": name])
        let (data, _) = try await URLSession.shared.data(for: req)
        return (try JSONSerialization.jsonObject(with: data) as! [String: Any])["userToken"] as! String
    }

    private func client(_ id: String, _ name: String) -> RelayClient {
        var config = RelayConfig(baseURL: Self.base, publicKey: Self.project!.publicKey, tokenProvider: { try await self.mint(id, name) })
        config.pingInterval = 1
        return RelayClient(config: config)
    }

    private func until(_ label: String, timeout: TimeInterval = 5, _ pred: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !pred() {
            if Date() > deadline { XCTFail("timed out: \(label)"); return }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
    }

    func testTwoClientsChatEndToEnd() async throws {
        try XCTSkipIf(Self.project == nil, "DATABASE_URL/REDIS_URL not set — integration test skipped")
        let alice = client("alice", "Alice")
        let bob = client("bob", "Bob")
        defer { alice.disconnect(); bob.disconnect() }
        let me = try await alice.connect()
        XCTAssertEqual(me.userId, "alice")
        XCTAssertEqual(alice.connection.state, .connected)
        _ = try await bob.connect()

        try await alice.chat.loadConversations()
        let convo = try await alice.chat.openConversation(with: "bob")
        XCTAssertEqual(convo.peer?.userId, "bob")
        XCTAssertEqual(convo.peer?.isOnline, true)
        try await bob.chat.loadConversations()

        let sent = try await alice.chat.sendMessage(convo.id, text: "hello bob")
        XCTAssertEqual(sent.senderId, "alice")
        try await until("bob unread 1") { bob.chat.conversation(convo.id)?.unreadCount == 1 }
        XCTAssertEqual(bob.chat.conversation(convo.id)?.lastMessage?.body, "hello bob")
        XCTAssertEqual(alice.chat.thread(convo.id).messages.count, 1)

        try await bob.chat.loadMessages(convo.id)
        bob.chat.setViewing(convo.id)
        try await until("bob unread 0") { bob.chat.conversation(convo.id)?.unreadCount == 0 }
        try await until("alice sees receipt") { (alice.chat.readReceipts[convo.id]?["bob"] ?? nil) != nil }

        bob.chat.sendTyping(convo.id)
        try await until("alice sees typing") { (alice.chat.typing[convo.id] ?? []).contains("bob") }

        alice.chat.setViewing(convo.id)
        _ = try await bob.chat.sendMessage(convo.id, text: "hi alice")
        try await until("alice gets reply") { alice.chat.thread(convo.id).messages.count == 2 }
        XCTAssertEqual(alice.chat.conversation(convo.id)?.unreadCount, 0)

        bob.disconnect()
        try await until("bob offline") { alice.chat.presence["bob"]?.online == false }
    }
}
