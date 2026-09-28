import CryptoKit
import Foundation

enum FrameboardCryptoError: Error { case invalidMessage, invalidSequence }

/// Frameboard protocol v2 authentication and ordered AES-GCM record protection.
final class SecureChannel {
    static let nonceBytes = 32
    private static let clientLabel = Data("frameboard-client-v2".utf8)
    private static let serverLabel = Data("frameboard-server-v2".utf8)
    private static let sessionInfo = Data("frameboard-session-v2".utf8)
    private static let c2sLabel = Data("frameboard-c2s-v2".utf8)
    private static let s2cLabel = Data("frameboard-s2c-v2".utf8)
    private let sendKey: SymmetricKey
    private let receiveKey: SymmetricKey
    private var sendSequence: UInt64 = 0
    private var receiveSequence: UInt64 = 0

    private init(sendKey: SymmetricKey, receiveKey: SymmetricKey) {
        self.sendKey = sendKey; self.receiveKey = receiveKey
    }
    static func randomNonce() -> Data {
        var bytes = [UInt8](repeating: 0, count: nonceBytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
    }
    static func clientProof(secret: String, serverNonce: Data, clientNonce: Data) -> Data {
        hmac(secretKey(secret), clientLabel + serverNonce + clientNonce)
    }
    static func serverProof(secret: String, serverNonce: Data, clientNonce: Data) -> Data {
        hmac(secretKey(secret), serverLabel + serverNonce + clientNonce)
    }
    static func server(secret: String, serverNonce: Data, clientNonce: Data) -> SecureChannel {
        let key = secretKey(secret)
        let material = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: key), salt: serverNonce + clientNonce,
                                              info: sessionInfo, outputByteCount: 64)
        let bytes = material.withUnsafeBytes { Data($0) }
        return SecureChannel(sendKey: SymmetricKey(data: bytes.prefix(32)), receiveKey: SymmetricKey(data: bytes.suffix(32)))
    }
    static func validClientProof(_ proof: Data, secret: String, serverNonce: Data, clientNonce: Data) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: clientLabel + serverNonce + clientNonce,
                                               using: SymmetricKey(data: secretKey(secret)))
    }
    func seal(_ message: [String: Any]) throws -> [String: Any] {
        let clear = try JSONSerialization.data(withJSONObject: message)
        let sequence = sendSequence; sendSequence += 1
        let count = Self.counter(sequence)
        let sealed = try AES.GCM.seal(clear, using: sendKey, nonce: Self.nonce(sequence), authenticating: Self.s2cLabel + count)
        return ["sequence": sequence, "ciphertext": (sealed.ciphertext + sealed.tag).base64EncodedString()]
    }
    func open(_ envelope: [String: Any]) throws -> [String: Any] {
        guard let number = envelope["sequence"] as? NSNumber, number.uint64Value == receiveSequence,
              let encoded = envelope["ciphertext"] as? String, encoded.count <= 3_000_000,
              let sealed = Data(base64Encoded: encoded), sealed.count >= 16 else { throw FrameboardCryptoError.invalidSequence }
        let sequence = receiveSequence, count = Self.counter(sequence)
        let box = try AES.GCM.SealedBox(nonce: Self.nonce(sequence), ciphertext: sealed.dropLast(16), tag: sealed.suffix(16))
        let clear = try AES.GCM.open(box, using: receiveKey, authenticating: Self.c2sLabel + count)
        guard let message = try JSONSerialization.jsonObject(with: clear) as? [String: Any] else { throw FrameboardCryptoError.invalidMessage }
        receiveSequence += 1
        return message
    }
    private static func secretKey(_ secret: String) -> Data {
        Data(SHA256.hash(data: Data("frameboard-pairing-v2\0".utf8) + Data(secret.utf8)))
    }
    private static func hmac(_ key: Data, _ data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }
    private static func counter(_ value: UInt64) -> Data {
        var big = value.bigEndian; return Data(bytes: &big, count: MemoryLayout<UInt64>.size)
    }
    private static func nonce(_ sequence: UInt64) throws -> AES.GCM.Nonce {
        try AES.GCM.Nonce(data: Data([0x46, 0x42, 0x56, 0x32]) + counter(sequence))
    }
}
