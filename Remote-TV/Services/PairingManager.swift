import Foundation
import Security

@MainActor
final class PairingManager {
    private let channel: any ATVChannel
    private let clientCertificate: SecCertificate
    private(set) var awaitingCode = false
    init(channel: any ATVChannel, clientCertificate: SecCertificate) {
        self.channel = channel; self.clientCertificate = clientCertificate
    }
    func start() async throws {
        try await channel.open()
        try await channel.send(Proto.polo(10, Proto.string(1, "atvremote") + Proto.string(2, "AISRemote")))
        try await expect(11)
        let encoding = Proto.int(1, 3) + Proto.int(2, 6)
        try await channel.send(Proto.polo(20, Proto.blob(1, encoding) + Proto.int(3, 1)))
        let options = try await expect(20).nested(20)
        let offers = options.bytes[2] ?? []
        guard try offers.contains(where: { let value = try Proto($0); return value.integers[1] == 3 && value.integers[2] == 6 }) else {
            throw ATVError.message("Device does not offer the six-character hexadecimal pairing display required by this client.")
        }
        try await channel.send(Proto.polo(30, Proto.blob(1, encoding) + Proto.int(2, 1)))
        try await expect(31)
        awaitingCode = true
        ConnectionLog.event("PAIRING_REQUIRED")
    }
    func finish(code: String) async throws -> Data {
        guard awaitingCode, let peer = channel.peerCertificate else { throw ATVError.message("Start pairing first and wait for a code on the TV.") }
        let proof = try PairingProof.secret(code: code, client: clientCertificate, server: peer)
        do {
            try await channel.send(Proto.polo(40, Proto.blob(1, proof)))
            try await expect(41)
        } catch { awaitingCode = false; channel.close(); throw error }
        awaitingCode = false
        ConnectionLog.event("PAIRING_SUCCESS")
        return SecCertificateCopyData(peer) as Data
    }
    @discardableResult private func expect(_ field: Int) async throws -> Proto {
        let message = try Proto(await channel.next(timeout: .seconds(10)))
        try message.checkPolo(field)
        return message
    }
    func cancel() { awaitingCode = false; channel.close() }
}
