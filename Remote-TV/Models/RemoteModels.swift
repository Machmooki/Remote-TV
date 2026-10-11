import Foundation
import Darwin

struct TVDevice: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var name: String
    var host: String
    var addresses: [String]
    var advertisedService: String?

    // Discard the retired local-only device when reading older saved preferences.
    var isLegacyDemo: Bool { id == "demo" }

    static func manual(_ input: String) throws -> TVDevice {
        let host = input.trimmingCharacters(in: .whitespacesAndNewlines)
        var v4 = in_addr()
        var v6 = in6_addr()
        guard inet_pton(AF_INET, host, &v4) == 1 || inet_pton(AF_INET6, host, &v6) == 1 else {
            throw RemoteError.invalidAddress
        }
        return TVDevice(id: "ip:\(host)", name: "AIS PLAYBOX", host: host, addresses: [host], advertisedService: nil)
    }
}

enum RemoteCommand: String, CaseIterable, Sendable {
    case up, down, left, right, select, back, home, menu, longSelect
    case volumeUp, volumeDown, mute, channelUp, channelDown
    case playPause, rewind, fastForward, power, enter

    var label: String {
        switch self {
        case .select: "OK"
        case .longSelect: "Hold OK"
        case .enter: "Enter"
        case .volumeUp: "Volume up"
        case .volumeDown: "Volume down"
        case .channelUp: "Channel up"
        case .channelDown: "Channel down"
        case .playPause: "Play or pause"
        case .fastForward: "Fast forward"
        default: rawValue.capitalized
        }
    }
}

enum RemoteError: LocalizedError {
    case invalidAddress, compatibilityUnverified, bluetoothUnverified, disconnected, unsupportedCommand, unsupportedApp
    case unsupportedText, invalidText
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidAddress: "Enter a valid IPv4 or IPv6 address from your PLAYBOX network settings."
        case .compatibilityUnverified: "Protocol compatibility has not been verified for this PLAYBOX. Open ports alone do not confirm support."
        case .bluetoothUnverified: "Bluetooth remote support is unverified. The original Bluetooth remote does not confirm iOS HID emulation support."
        case .disconnected: "Select and connect a supported device first."
        case .unsupportedApp: "App shortcuts are not supported by this transport yet."
        case .unsupportedCommand: "This device does not support this command."
        case .unsupportedText: "This TV session does not support phone typing. Open a search field on the TV and reconnect. Check that Android TV Remote Service is enabled and up to date."
        case .invalidText: "Enter between 1 and 2,048 Unicode characters to send to the TV."
        case .keychain(let status): "Secure storage failed (\(status))."
        }
    }
}

struct PortDiagnostic: Identifiable, Sendable, Equatable {
    enum Outcome: String, Sendable { case open, unavailable, timedOut, cancelled }
    var id: UInt16 { port }
    let port: UInt16
    let outcome: Outcome
    let detail: String
}

struct DiagnosticReport: Identifiable, Sendable {
    let id = UUID()
    let device: TVDevice
    let date: Date
    let ports: [PortDiagnostic]
    // A TCP connection and Bonjour advertisement are evidence, never a verified handshake.
    var protocolVerified: Bool { false }
    var summary: String {
        if ports.allSatisfy({ $0.outcome == .open }) && ports.count == 2 {
            return "Both TCP ports are reachable. These checks do not evaluate TLS, pairing or remote authentication."
        }
        return "Check the network, device power and remote service. These TCP checks do not evaluate protocol compatibility."
    }
    var text: String {
        """
        AIS PLAYBOX compatibility diagnostics
        Date: \(date.formatted(.iso8601))
        Device: \(device.name)
        Host: \(device.host)
        Resolved addresses: \(device.addresses.joined(separator: ", "))
        Bonjour: \(device.advertisedService ?? "Not advertised / manual entry")
        \(ports.map { "TCP \($0.port): \($0.outcome.rawValue) — \($0.detail)" }.joined(separator: "\n"))
        Protocol: UNVERIFIED — no TLS or Protobuf handshake performed.
        Bluetooth: UNVERIFIED — no HID emulation implemented.
        Hardware supplied by user: ZTE STBAZA-A, firmware V8754920.
        \(summary)
        """
    }
}
