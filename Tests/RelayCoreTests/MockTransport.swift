import Foundation
@testable import RelayCore

/// Serves canned JSON for RelayAPI so ChatStore can be exercised without a server.
/// Register handlers by "METHOD /path" (query string ignored).
final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handlers: [String: (URLRequest) -> (Int, Data)] = [:]
    nonisolated(unsafe) static var calls: [String] = []
    private static let lock = NSLock()

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        handlers = [:]; calls = []
    }

    static func on(_ key: String, status: Int = 200, json: Any) {
        lock.lock(); defer { lock.unlock() }
        handlers[key] = { _ in (status, try! JSONSerialization.data(withJSONObject: json)) }
    }

    static func on(_ key: String, _ handler: @escaping (URLRequest) -> (Int, Data)) {
        lock.lock(); defer { lock.unlock() }
        handlers[key] = handler
    }

    static func callCount(_ key: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return calls.filter { $0 == key }.count
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let key = "\(request.httpMethod ?? "GET") \(request.url?.path ?? "")"
        Self.lock.lock()
        Self.calls.append(key)
        let handler = Self.handlers[key]
        Self.lock.unlock()
        var req = request
        if let stream = request.httpBodyStream { // URLSession moves httpBody into a stream
            stream.open(); defer { stream.close() }
            var data = Data(); let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096); defer { buf.deallocate() }
            while stream.hasBytesAvailable { let n = stream.read(buf, maxLength: 4096); if n > 0 { data.append(buf, count: n) } else { break } }
            req.httpBody = data
        }
        let (status, body) = handler?(req) ?? (404, Data(#"{"error":"not_found","message":"no mock for \#(key)"}"#.utf8))
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

func mockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: config)
}

func conversationJSON(_ id: Int, peer: String = "bob", unread: Int = 0, lastMessage: [String: Any]? = nil, lastMessageAt: String? = nil, createdAt: String = "2026-01-01T00:00:00.000Z") -> [String: Any] {
    [
        "id": String(id), "isGroup": false, "name": NSNull(), "photoUrl": NSNull(), "creatorId": "alice",
        "peer": ["userId": peer, "displayName": peer.capitalized, "avatarUrl": NSNull(), "isOnline": false, "lastSeenAt": NSNull()],
        "members": [], "memberCount": 2, "lastMessage": lastMessage ?? NSNull(), "lastMessageAt": lastMessageAt ?? NSNull(),
        "unreadCount": unread, "createdAt": createdAt,
    ]
}

func messageJSON(_ id: Int, conversation: Int = 1, sender: String, body: String, createdAt: String? = nil, clientId: String? = nil) -> [String: Any] {
    var m: [String: Any] = [
        "id": String(id), "conversationId": String(conversation), "senderId": sender, "body": body,
        "createdAt": createdAt ?? "2026-01-01T00:00:\(String(format: "%02d", id % 60)).000Z",
        "editedAt": NSNull(), "deleted": false, "imageUrl": NSNull(), "audioUrl": NSNull(), "audioDurationSec": NSNull(), "replyTo": NSNull(),
    ]
    if let clientId { m["clientId"] = clientId }
    return m
}
