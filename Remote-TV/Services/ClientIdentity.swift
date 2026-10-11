import Foundation
import Security

// Minimal DER writer for a self-signed RSA client certificate (RFC 5280).
// Private keys never leave Keychain. SecIdentityCreate verifies the certificate/key match.
enum DER {
    static func item(_ tag: UInt8, _ body: Data) -> Data {
        var length = Data()
        if body.count < 128 { length.append(UInt8(body.count)) }
        else {
            var size = body.count; var bytes = [UInt8]()
            while size > 0 { bytes.insert(UInt8(size & 255), at: 0); size >>= 8 }
            length.append(0x80 | UInt8(bytes.count)); length.append(contentsOf: bytes)
        }
        return Data([tag]) + length + body
    }
    static func sequence(_ body: Data) -> Data { item(0x30, body) }
    static let rsaAlgorithm = sequence(Data([0x06,0x09,0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x01,0x01,0x05,0x00]))
    static let signatureAlgorithm = sequence(Data([0x06,0x09,0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x01,0x0b,0x05,0x00]))
    static func certificate(key: SecKey, now: Date = Date()) throws -> Data {
        guard let publicKey = SecKeyCopyPublicKey(key), let publicDER = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else {
            throw ATVError.message("Cannot read client public key.")
        }
        let name = sequence(item(0x31, sequence(Data([0x06,0x03,0x55,0x04,0x03]) + item(0x0c, Data("AISRemote".utf8)))))
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyMMddHHmmss'Z'"
        let validity = sequence(item(0x17, Data(formatter.string(from: now.addingTimeInterval(-86400)).utf8))
            + item(0x17, Data(formatter.string(from: now.addingTimeInterval(10 * 365 * 86400)).utf8)))
        var serial = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, serial.count, &serial) == errSecSuccess else { throw ATVError.message("Secure random generation failed.") }
        serial[0] &= 0x7f; serial[0] |= 1
        let tbs = sequence(item(0xa0, item(0x02, Data([2]))) + item(0x02, Data(serial))
            + signatureAlgorithm + name + validity + name
            + sequence(rsaAlgorithm + item(0x03, Data([0]) + publicDER)))
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, tbs as CFData, &error) as Data? else {
            throw ATVError.message("Cannot sign the client certificate.")
        }
        return sequence(tbs + signatureAlgorithm + item(0x03, Data([0]) + signature))
    }
}

struct DERReader {
    let data: [UInt8]
    var index = 0
    init(_ data: Data) { self.data = Array(data) }
    mutating func read(_ tag: UInt8) throws -> Data {
        guard index + 2 <= data.count, data[index] == tag else { throw ATVError.message("Invalid certificate DER.") }
        index += 1
        var length = Int(data[index]); index += 1
        if length & 128 != 0 {
            let count = length & 127
            guard count > 0, count <= 4, index + count <= data.count else { throw ATVError.message("Invalid DER length.") }
            length = 0
            for _ in 0..<count { length = length << 8 | Int(data[index]); index += 1 }
        }
        guard length <= data.count - index else { throw ATVError.message("Truncated certificate DER.") }
        defer { index += length }
        return Data(data[index..<index + length])
    }
}

@MainActor
struct ClientIdentity {
    let identity: SecIdentity
    let certificate: SecCertificate
    static func loadOrCreate(store: SecureCredentialStore = SecureCredentialStore()) throws -> ClientIdentity {
        let tag = Data("Mach.Remote-TV.client-rsa-v1".utf8)
        let query: [String: Any] = [kSecClass as String: kSecClassKey, kSecAttrApplicationTag as String: tag,
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecReturnRef as String: true]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        let key: SecKey
        if status == errSecSuccess, let result { key = (result as! SecKey) }
        else if status == errSecItemNotFound {
            let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048,
                kSecPrivateKeyAttrs as String: [kSecAttrIsPermanent as String: true, kSecAttrApplicationTag as String: tag,
                    kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]]
            var error: Unmanaged<CFError>?
            guard let created = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else { throw ATVError.message("Cannot create a secure client identity. Unlock your iPhone and retry.") }
            key = created
        } else { throw RemoteError.keychain(status) }
        let data: Data
        if let stored = try store.load(for: "client-certificate-v1") { data = stored }
        else { data = try DER.certificate(key: key); try store.save(data, for: "client-certificate-v1") }
        guard let certificate = SecCertificateCreateWithData(nil, data as CFData),
              let identity = SecIdentityCreate(nil, certificate, key) else {
            throw ATVError.message("Stored client identity is invalid. Do not reset it until existing TV pairings can be renewed.")
        }
        return ClientIdentity(identity: identity, certificate: certificate)
    }
}
