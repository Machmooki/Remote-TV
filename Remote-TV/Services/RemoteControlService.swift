import Foundation

@MainActor
protocol RemoteTransport: AnyObject {
    var supportedCommands: Set<RemoteCommand> { get }
    var supportedApps: Set<TVAppShortcut> { get }
    var isConnected: Bool { get }
    var supportsTextInput: Bool { get }
    func connect(to device: TVDevice) async throws
    func send(_ command: RemoteCommand) async throws
    func launch(_ app: TVAppShortcut) async throws
    func sendText(_ text: String) async throws
    func disconnect()
}

extension RemoteTransport {
    var supportsTextInput: Bool { false }
    func sendText(_ text: String) async throws { throw RemoteError.unsupportedText }
    var supportedApps: Set<TVAppShortcut> { [] }
    func launch(_ app: TVAppShortcut) async throws { throw RemoteError.unsupportedApp }
}

@MainActor
protocol BluetoothRemoteTransport: RemoteTransport {
    var feasibilityVerified: Bool { get }
}

@MainActor
final class UnverifiedBluetoothTransport: BluetoothRemoteTransport {
    let feasibilityVerified = false
    let supportedCommands: Set<RemoteCommand> = []
    let isConnected = false
    func connect(to device: TVDevice) async throws { throw RemoteError.bluetoothUnverified }
    func send(_ command: RemoteCommand) async throws { throw RemoteError.bluetoothUnverified }
    func disconnect() {}
}

@MainActor
final class CommandDispatcher {
    func sendText(_ text: String, submit: Bool, through transport: any RemoteTransport) async throws {
        try Task.checkCancellation()
        guard transport.isConnected else { throw RemoteError.disconnected }
        guard transport.supportsTextInput else { throw RemoteError.unsupportedText }
        guard (1...2048).contains(text.unicodeScalars.count) else { throw RemoteError.invalidText }
        try await transport.sendText(text)
        try Task.checkCancellation()
        if submit { try await dispatch(.enter, through: transport) }
    }
    func launch(_ app: TVAppShortcut, through transport: any RemoteTransport) async throws {
        guard transport.isConnected else { throw RemoteError.disconnected }
        guard transport.supportedApps.contains(app) else { throw RemoteError.unsupportedApp }
        try await transport.launch(app)
    }

    func dispatch(_ command: RemoteCommand, through transport: any RemoteTransport) async throws {
        guard transport.isConnected else { throw RemoteError.disconnected }
        guard transport.supportedCommands.contains(command) else { throw RemoteError.unsupportedCommand }
        try await transport.send(command)
    }
}

@MainActor
final class RemoteControlService {
    private(set) var sessionID = UUID()
    private var transport: any RemoteTransport
    private let dispatcher = CommandDispatcher()
    init(transport: any RemoteTransport = AndroidTVRemoteTransport()) { self.transport = transport }
    var isConnected: Bool { transport.isConnected }
    var supportedCommands: Set<RemoteCommand> { transport.supportedCommands }
    var supportedApps: Set<TVAppShortcut> { transport.supportedApps }
    var supportsTextInput: Bool { transport.supportsTextInput }
    func sendText(_ text: String, submit: Bool = false) async throws {
        // Capture one transport for text AND Enter. Never submit to a replacement session.
        try await dispatcher.sendText(text, submit: submit, through: transport)
    }
    func launch(_ app: TVAppShortcut) async throws { try await dispatcher.launch(app, through: transport) }
    func replaceTransport(_ newTransport: any RemoteTransport) {
        sessionID = UUID()
        transport.disconnect()
        transport = newTransport
    }
    func connect(to device: TVDevice) async throws { sessionID = UUID(); try await transport.connect(to: device) }
    func send(_ command: RemoteCommand) async throws { try await dispatcher.dispatch(command, through: transport) }
    func disconnect() { sessionID = UUID(); transport.disconnect() }
}

