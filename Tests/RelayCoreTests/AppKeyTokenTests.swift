import XCTest
@testable import RelayCore

final class AppKeyTokenTests: XCTestCase {
    override func setUp() { MockURLProtocol.reset() }

    func testMintsAndReturnsTheUserToken() async throws {
        MockURLProtocol.on("POST /users/token", json: ["userToken": "jwt-abc", "expiresAt": "2099-01-01T00:00:00Z"])

        let options = AppKeyTokenOptions(baseURL: URL(string: "https://relay.test")!, appKey: "ak_test", externalId: "guest-1", displayName: "Guest", session: mockSession())
        guard case .provider(let getToken) = RelayToken.appKey(options) else { XCTFail("expected .provider"); return }

        let token = try await getToken()
        XCTAssertEqual(token, "jwt-abc")
        XCTAssertEqual(MockURLProtocol.callCount("POST /users/token"), 1)
    }

    func testSendsTheAppKeyAsBearerAndTheIdentityAsJSON() async throws {
        MockURLProtocol.on("POST /users/token") { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "authorization"), "Bearer ak_test")
            let body = try! JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as! [String: Any]
            XCTAssertEqual(body["externalId"] as? String, "guest-1")
            XCTAssertEqual(body["displayName"] as? String, "Guest")
            return (200, try! JSONSerialization.data(withJSONObject: ["userToken": "jwt-abc"]))
        }

        let options = AppKeyTokenOptions(baseURL: URL(string: "https://relay.test")!, appKey: "ak_test", externalId: "guest-1", displayName: "Guest", session: mockSession())
        guard case .provider(let getToken) = RelayToken.appKey(options) else { XCTFail("expected .provider"); return }
        _ = try await getToken()
    }

    func testARevokedOrInvalidAppKeyThrowsAServerError() async throws {
        MockURLProtocol.on("POST /users/token", status: 401, json: ["error": "unauthorized", "message": "Invalid or revoked app key"])

        let options = AppKeyTokenOptions(baseURL: URL(string: "https://relay.test")!, appKey: "ak_bad", externalId: "guest-1", session: mockSession())
        guard case .provider(let getToken) = RelayToken.appKey(options) else { XCTFail("expected .provider"); return }

        do {
            _ = try await getToken()
            XCTFail("expected an error")
        } catch let error as RelayError {
            XCTAssertEqual(error.status, 401)
            XCTAssertTrue(error.isAuth)
        }
    }
}
