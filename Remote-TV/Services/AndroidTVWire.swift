import Foundation
import CryptoKit
import Security
import OSLog
import Network

// Field numbers and handshake from tronikos/androidtvremote2 (see Documentation/Protocol.md).
// A bounded protobuf subset: unknown fields are skipped; no guessed protocol fields.
enum ATVError: LocalizedError {
    case message(String), network(String), responseTimeout, sessionIdle
    case identityChanged, accessDenied, tlsRejected(String)
    var errorDescription: String? {
        switch self {
        case .message(let text), .network(let text), .tlsRejected(let text): text
        case .responseTimeout: "Pairing or remote negotiation response timed out. Check the PLAYBOX and remote service."
        case .sessionIdle: "Remote session became inactive: no received messages or completed command writes before the activity deadline."
        case .identityChanged: "TLS peer identity changed. Confirm the box IP, then restart pairing only if you trust this device."
        case .accessDenied: "Local Network access denied. Enable it in Settings → Privacy & Security → Local Network → Remote TV, then retry."
        }
    }
    static func canRetry(_ error: Error) -> Bool {
        if let error = error as? ATVError {
            switch error {
            case .network, .responseTimeout, .sessionIdle: return true
            default: return false
            }
        }
        return error is NWError
    }
}

enum ConnectionLog {
    static let logger = Logger(subsystem: "Mach.Remote-TV", category: "Connection")
    static func event(_ name: String, _ detail: String = "") {
        logger.info("\(name, privacy: .public) \(detail, privacy: .public)")
    }
}

struct Proto {
    var integers: [Int: UInt64] = [:]
    var bytes: [Int: [Data]] = [:]
    init(_ data: Data) throws {
        let input = Array(data)
        var index = 0
        while index < input.count {
            let tag = try Self.varint(input, &index)
            let field = Int(tag >> 3)
            guard field > 0 else { throw ATVError.message("Protocol: invalid protobuf field.") }
            switch tag & 7 {
            case 0: integers[field] = try Self.varint(input, &index)
            case 2:
                let size = try Self.varint(input, &index)
                guard size <= 1_048_576, size <= input.count - index else { throw ATVError.message("Protocol: truncated or oversized field.") }
                let end = index + Int(size)
                bytes[field, default: []].append(Data(input[index..<end])); index = end
            case 1, 5:
                index += tag & 7 == 1 ? 8 : 4
                guard index <= input.count else { throw ATVError.message("Protocol: truncated fixed field.") }
            default: throw ATVError.message("Protocol: unsupported protobuf wire type.")
            }
        }
    }
    func nested(_ field: Int) throws -> Proto {
        guard let data = bytes[field]?.first else { throw ATVError.message("Protocol: missing expected field \(field).") }
        return try Proto(data)
    }
    static func varint(_ input: [UInt8], _ index: inout Int) throws -> UInt64 {
        var value: UInt64 = 0
        for shift in stride(from: 0, through: 63, by: 7) {
            guard index < input.count else { throw ATVError.message("Protocol: incomplete varint.") }
            let byte = input[index]; index += 1
            guard shift < 63 || byte <= 1 else { throw ATVError.message("Protocol: varint overflow.") }
            value |= UInt64(byte & 127) << shift
            if byte & 128 == 0 { return value }
        }
        throw ATVError.message("Protocol: varint overflow.")
    }
    static func varint(_ number: UInt64) -> Data {
        var value = number; var data = Data()
        repeat {
            var byte = UInt8(value & 127); value >>= 7
            if value != 0 { byte |= 128 }; data.append(byte)
        } while value != 0
        return data
    }
    static func int(_ field: Int, _ value: UInt64) -> Data { varint(UInt64(field << 3)) + varint(value) }
    static func blob(_ field: Int, _ data: Data) -> Data { varint(UInt64(field << 3 | 2)) + varint(UInt64(data.count)) + data }
    static func string(_ field: Int, _ value: String) -> Data { blob(field, Data(value.utf8)) }
    static func polo(_ field: Int, _ payload: Data) -> Data { int(1, 2) + int(2, 200) + blob(field, payload) }
    func checkPolo(_ field: Int) throws {
        guard integers[1] == 2, integers[2] == 200, bytes[field]?.count == 1 else {
            throw ATVError.message("Pairing protocol rejected or unsupported (version \(integers[1] ?? 0), status \(integers[2] ?? 0), expected field \(field)). Check Android TV Remote Service on the box.")
        }
    }
}

struct ProtoFrames {
    private var buffer = Data()
    mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var result: [Data] = []
        while !buffer.isEmpty {
            let input = Array(buffer.prefix(10)); var index = 0
            // Partial prefixes must survive until the next receive callback.
            guard let last = input.firstIndex(where: { $0 & 128 == 0 }) else {
                if input.count == 10 { throw ATVError.message("Protocol: invalid frame length.") }; break
            }
            _ = last
            let size = try Proto.varint(input, &index)
            guard size > 0, size <= 1_048_576 else { throw ATVError.message("Protocol: invalid or oversized frame.") }
            guard buffer.count >= index + Int(size) else { break }
            result.append(Data(buffer.dropFirst(index).prefix(Int(size))))
            buffer.removeFirst(index + Int(size))
        }
        guard buffer.count <= 1_048_586 else { throw ATVError.message("Protocol receive buffer exceeded limit.") }
        return result
    }
    static func encode(_ data: Data) -> Data { Proto.varint(UInt64(data.count)) + data }
}

enum PairingProof {
    static func secret(code: String, client: SecCertificate, server: SecCertificate) throws -> Data {
        let pin = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard pin.utf8.count == 6, pin.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else {
            throw ATVError.message("Enter the six hexadecimal characters displayed on the TV (0–9, A–F). A MAC address is not a pairing code.")
        }
        let values = stride(from: 0, to: 6, by: 2).map { offset -> UInt8 in
            let start = pin.index(pin.startIndex, offsetBy: offset)
            return UInt8(pin[start..<pin.index(start, offsetBy: 2)], radix: 16)!
        }
        let clientRSA = try rsa(client); let serverRSA = try rsa(server)
        let hash = Data(SHA256.hash(data: clientRSA.0 + clientRSA.1 + serverRSA.0 + serverRSA.1 + Data(values.suffix(2))))
        guard hash.first == values[0] else { throw ATVError.message("Pairing code does not match this TLS peer. Check the code on the selected TV and retry; do not use the MAC address.") }
        return hash
    }
    static func rsa(_ certificate: SecCertificate) throws -> (Data, Data) {
        guard let key = SecCertificateCopyKey(certificate),
              let attributes = SecKeyCopyAttributes(key) as? [String: Any],
              attributes[kSecAttrKeyType as String] as? String == kSecAttrKeyTypeRSA as String,
              let external = SecKeyCopyExternalRepresentation(key, nil) as Data? else {
            throw ATVError.message("Pairing requires an RSA certificate; this peer is incompatible.")
        }
        var outer = DERReader(external)
        var sequence = DERReader(try outer.read(0x30))
        let modulus = try sequence.read(0x02); let exponent = try sequence.read(0x02)
        return (Data(modulus.drop(while: { $0 == 0 })), Data(exponent.drop(while: { $0 == 0 })))
    }
}
