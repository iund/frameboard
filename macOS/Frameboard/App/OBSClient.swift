import Foundation
import CryptoKit

struct OBSError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Authenticated OBS WebSocket v5 client; one reader dispatches concurrent replies.
actor OBSClient {
    private var socket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var reader: Task<Void, Never>?
    private var pending: [String: CheckedContinuation<[String: Any], Error>] = [:]

    func connect(port: UInt16, password: String) async throws {
        close()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        let session = URLSession(configuration: configuration); self.session = session
        let ws = session.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)")!)
        ws.maximumMessageSize = 4 * 1024 * 1024; socket = ws; ws.resume()
        let watchdog = Task {
            do { try await Task.sleep(nanoseconds: 6_000_000_000); ws.cancel(with: .goingAway, reason: nil) } catch {}
        }
        defer { watchdog.cancel() }
        let hello = try await Self.decode(ws.receive())
        guard hello["op"] as? Int == 0, let data = hello["d"] as? [String: Any] else { throw OBSError(message: "OBS sent an unexpected handshake.") }
        var identify: [String: Any] = ["rpcVersion": 1, "eventSubscriptions": 0]
        if let auth = data["authentication"] as? [String: String], let salt = auth["salt"], let challenge = auth["challenge"] {
            identify["authentication"] = Self.authentication(password: password, salt: salt, challenge: challenge)
        }
        try await send(["op": 1, "d": identify], on: ws)
        let response = try await Self.decode(ws.receive())
        guard response["op"] as? Int == 2 else { throw OBSError(message: "OBS did not accept the control connection.") }
        reader = Task { [weak self] in await self?.readResponses(ws) }
    }
    static func authentication(password: String, salt: String, challenge: String) -> String {
        let secret = Data(SHA256.hash(data: Data((password + salt).utf8))).base64EncodedString()
        return Data(SHA256.hash(data: Data((secret + challenge).utf8))).base64EncodedString()
    }
    private static func decode(_ message: URLSessionWebSocketTask.Message) throws -> [String: Any] {
        let bytes: Data
        switch message { case .data(let data): bytes = data; case .string(let text): bytes = Data(text.utf8); @unknown default: throw OBSError(message: "Unknown OBS message.") }
        guard let json = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw OBSError(message: "Invalid OBS message.") }
        return json
    }
    private func send(_ json: [String: Any], on ws: URLSessionWebSocketTask) async throws {
        let data = try JSONSerialization.data(withJSONObject: json)
        try await ws.send(.string(String(decoding: data, as: UTF8.self)))
    }
    func request(_ type: String, _ data: [String: Any] = [:]) async throws -> [String: Any] {
        guard let ws = socket else { throw OBSError(message: "OBS is not connected.") }
        let id = UUID().uuidString
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            Task {
                do { try await send(["op": 6, "d": ["requestType": type, "requestId": id, "requestData": data]], on: ws) }
                catch { fail(id, error) }
            }
            Task {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                fail(id, OBSError(message: "OBS did not finish \(type). Check for a macOS camera-extension approval prompt, then retry."))
            }
        }
    }
    private func fail(_ id: String, _ error: Error) { pending.removeValue(forKey: id)?.resume(throwing: error) }
    private func readResponses(_ ws: URLSessionWebSocketTask) async {
        do {
            while !Task.isCancelled {
                let json = try await Self.decode(ws.receive())
                guard json["op"] as? Int == 7, let data = json["d"] as? [String: Any], let id = data["requestId"] as? String,
                      let continuation = pending.removeValue(forKey: id) else { continue }
                let status = data["requestStatus"] as? [String: Any] ?? [:]
                if status["result"] as? Bool == true { continuation.resume(returning: data["responseData"] as? [String: Any] ?? [:]) }
                else { continuation.resume(throwing: OBSError(message: status["comment"] as? String ?? "OBS rejected the request.")) }
            }
        } catch {
            guard socket === ws else { return }
            for continuation in pending.values { continuation.resume(throwing: error) }; pending.removeAll()
        }
    }
    func close() {
        reader?.cancel(); reader = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        session?.invalidateAndCancel(); session = nil
        for continuation in pending.values { continuation.resume(throwing: CancellationError()) }; pending.removeAll()
    }
}
