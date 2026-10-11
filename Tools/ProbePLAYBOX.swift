// Build from the app's production protocol sources; no Keychain writes and no commands.
import Foundation
import Security

@main
struct ProbePLAYBOX {
    @MainActor static func main() async {
        guard CommandLine.arguments.count == 2 else { print("Usage: ProbePLAYBOX <IP>"); return }
        do {
            let device = try TVDevice.manual(CommandLine.arguments[1])
            let attrs: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048]
            guard let key = SecKeyCreateRandomKey(attrs as CFDictionary, nil),
                  let cert = SecCertificateCreateWithData(nil, try DER.certificate(key: key) as CFData),
                  let identity = SecIdentityCreate(nil, cert, key) else { throw ATVError.message("Ephemeral identity creation failed") }
            let channel = AndroidTVTLSChannel(host: device.host, port: 6467, identity: identity, pinnedCertificate: nil) { print($0) }
            let pairing = PairingManager(channel: channel, clientCertificate: cert)
            defer { pairing.cancel() }
            try await pairing.start()
            print("VERIFIED: TLS 6467 + Polo v2 request/options/configuration acknowledgements. TV code requested; pairing NOT completed. No commands transmitted.")
        } catch { print("PROBE FAILED: \(error.localizedDescription)") }
    }
}
