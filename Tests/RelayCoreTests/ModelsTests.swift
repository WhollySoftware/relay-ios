import XCTest
@testable import RelayCore

final class ModelsTests: XCTestCase {
    func testDecodesMessageWithFractionalSeconds() throws {
        let json = #"{"id":"7","conversationId":"3","senderId":"alice","body":"hi","createdAt":"2026-09-06T00:12:34.567Z","editedAt":null,"deleted":false,"imageUrl":null,"audioUrl":null,"audioDurationSec":null,"replyTo":null}"#
        let m = try RelayJSON.decoder.decode(Message.self, from: Data(json.utf8))
        XCTAssertEqual(m.id, "7")
        XCTAssertEqual(m.kind, .text)
        XCTAssertEqual(Int(m.createdAt.timeIntervalSince1970), 1788653554)
    }

    func testDecodesChatMessageEvent() {
        let json = #"{"event":"chat_message","conversationId":"3","clientId":"c_1","message":{"id":"7","conversationId":"3","senderId":"alice","body":"hi","createdAt":"2026-09-06T00:12:34Z","editedAt":null,"deleted":false,"imageUrl":null,"audioUrl":null,"audioDurationSec":null,"replyTo":null}}"#
        guard case .chatMessage(let conversationId, let message, let clientId)? = RelayEvent.decode(Data(json.utf8)) else {
            return XCTFail("expected chat_message")
        }
        XCTAssertEqual(conversationId, "3")
        XCTAssertEqual(message.senderId, "alice")
        XCTAssertEqual(clientId, "c_1")
    }

    func testUnknownEventsAreTolerated() {
        guard case .unknown(let name, _)? = RelayEvent.decode(Data(#"{"event":"future_thing","x":1}"#.utf8)) else { return XCTFail() }
        XCTAssertEqual(name, "future_thing")
    }

    @MainActor
    func testMergeDedupesOptimisticByClientId() {
        let pending = Message(id: "pending:c1", conversationId: "1", senderId: "me", body: "hi", createdAt: Date(), clientId: "c1", status: .sending)
        let server = Message(id: "42", conversationId: "1", senderId: "me", body: "hi", createdAt: Date(), clientId: "c1", status: .sent)
        let merged = ChatStore.merge([pending], [server])
        XCTAssertEqual(merged.map(\.id), ["42"])
        let mergedReverse = ChatStore.merge([server], [pending])
        XCTAssertEqual(mergedReverse.map(\.id), ["42"], "echo before the optimistic insert must not duplicate")
    }

    func testGatewayURL() {
        let config = RelayConfig(baseURL: URL(string: "https://relay.example.com")!, publicKey: "pk_x", token: .static("t"))
        XCTAssertEqual(config.gatewayURL.absoluteString, "wss://relay.example.com/ws/gateway")
    }
}
