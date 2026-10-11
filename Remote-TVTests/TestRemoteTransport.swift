import Foundation
@testable import Remote_TV

extension TVDevice {
    static let demo = TVDevice(id: "demo", name: "Test peer", host: "Test fixture", addresses: [], advertisedService: nil)
}

// Test-only recording transport; never compiled into the application target.
@MainActor
final class MockRemoteTransport: RemoteTransport {
    var supportsTextInput: Bool { isConnected }
    private(set) var textTransmissionCount = 0
    let supportedCommands = Set(RemoteCommand.allCases)
    let supportedApps = Set(TVAppShortcut.allCases)
    private(set) var launchedApps: [TVAppShortcut] = []
    private(set) var isConnected = false
    private(set) var commands: [RemoteCommand] = []
    func connect(to device: TVDevice) async throws {
        guard device.isLegacyDemo else { throw RemoteError.compatibilityUnverified }
        isConnected = true
    }
    func send(_ command: RemoteCommand) async throws {
        guard isConnected else { throw RemoteError.disconnected }
        commands.append(command)
        if commands.count > 100 { commands.removeFirst() }
    }
    func launch(_ app: TVAppShortcut) async throws {
        guard isConnected else { throw RemoteError.disconnected }
        launchedApps.append(app)
        if launchedApps.count > 100 { launchedApps.removeFirst() }
    }
    func disconnect() { isConnected = false }
    func sendText(_ text: String) async throws {
        guard isConnected else { throw RemoteError.disconnected }
        guard (1...2048).contains(text.unicodeScalars.count) else { throw RemoteError.invalidText }
        textTransmissionCount += 1 // Deliberately don't retain the user's search text.
    }
}

