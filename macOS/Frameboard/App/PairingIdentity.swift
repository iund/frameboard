import AppKit
import CoreImage
import CryptoKit
import Foundation
import Security

struct PairingCode {
    let image: NSImage
    let fingerprint: String
}

final class PairingIdentity {
    private let key: P256.Signing.PrivateKey
    private static let service = "FrameboardPairingIdentity"
    private static let account = "P256-v1"

    private init(key:P256.Signing.PrivateKey) { self.key=key }
    static func loadOrCreate() -> PairingIdentity? {
        let query:[String:Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,
                                  kSecAttrAccount as String:account,kSecReturnData as String:true]
        var item:CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary,&item)==errSecSuccess, let data=item as? Data,
           let key=try? P256.Signing.PrivateKey(rawRepresentation:data) { return PairingIdentity(key:key) }
        let key=P256.Signing.PrivateKey()
        let add:[String:Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,
                                kSecAttrAccount as String:account,kSecValueData as String:key.rawRepresentation,
                                kSecAttrAccessible as String:kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        guard SecItemAdd(add as CFDictionary,nil)==errSecSuccess else { return nil }
        return PairingIdentity(key:key)
    }
    func code(host:String,port:UInt16,secret:String) -> PairingCode? {
        let publicKey=key.publicKey.x963Representation, identity=Self.base64URL(publicKey)
        let canonical=Self.canonical(host:host,port:port,secret:secret,identity:identity)
        guard let signature=try? key.signature(for:Data(canonical.utf8)) else { return nil }
        var components=URLComponents();components.scheme="frameboard";components.host="pair"
        components.queryItems=[URLQueryItem(name:"v",value:"2"),URLQueryItem(name:"host",value:host),
                               URLQueryItem(name:"port",value:String(port)),URLQueryItem(name:"secret",value:secret),
                               URLQueryItem(name:"identity",value:identity),
                               URLQueryItem(name:"signature",value:Self.base64URL(signature.derRepresentation))]
        guard let payload=components.string?.data(using:.utf8),let filter=CIFilter(name:"CIQRCodeGenerator") else{return nil}
        filter.setValue(payload,forKey:"inputMessage");filter.setValue("M",forKey:"inputCorrectionLevel")
        guard let output=filter.outputImage?.transformed(by:CGAffineTransform(scaleX:7,y:7)) else{return nil}
        let rep=NSCIImageRep(ciImage:output),image=NSImage(size:rep.size);image.addRepresentation(rep)
        let digest=SHA256.hash(data:publicKey).prefix(6).map{String(format:"%02X",$0)}.joined()
        return PairingCode(image:image,fingerprint:String(digest.prefix(4))+"-"+String(digest.dropFirst(4).prefix(4))+"-"+String(digest.dropFirst(8)))
    }
    private static func canonical(host:String,port:UInt16,secret:String,identity:String)->String {
        "frameboard-pair-v2\n\(host)\n\(port)\n\(secret)\n\(identity)"
    }
    private static func base64URL(_ data:Data)->String {
        data.base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"")
    }
}
