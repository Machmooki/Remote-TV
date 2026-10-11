import Testing
import Foundation
import Network
@testable import Remote_TV

@MainActor
struct Remote_TVTests {
    @Test func touchpadDistinguishesTapFromJitterAndSwipes() {
        var pad = TouchpadInterpreter()
        #expect(pad.move(x: 3, y: -2) == nil)
        #expect(pad.end() == .select)
        #expect(pad.move(x: 15, y: 0) == nil)
        #expect(pad.end() == nil)
        #expect(pad.move(x: 40, y: 4) == .right)
        #expect(pad.move(x: 45, y: 4) == nil)
        #expect(pad.move(x: 80, y: 4) == .right)
        #expect(pad.move(x: 38, y: 4) == .left)
        #expect(pad.end() == nil)
        #expect(pad.move(x: 5, y: -40) == .up)
        #expect(pad.end() == nil)
        #expect(pad.move(x: 5, y: 40) == .down)
        #expect(pad.end() == nil)
        // An out-and-back movement must never accidentally select an item.
        #expect(pad.move(x: 20, y: 0) == nil)
        #expect(pad.move(x: 0, y: 0) == nil)
        #expect(pad.end() == nil)
    }

    @Test func shortcutsRespectTransportCapabilities() async throws {
        let dispatcher = CommandDispatcher()
        let real = AndroidTVRemoteTransport()
        #expect(real.supportedApps.isEmpty)
        await #expect(throws: RemoteError.self) { try await dispatcher.launch(.netflix, through: real) }
        let mock = MockRemoteTransport()
        await #expect(throws: RemoteError.self) { try await dispatcher.launch(.youtube, through: mock) }
        try await mock.connect(to: .demo)
        try await dispatcher.launch(.netflix, through: mock)
        try await dispatcher.launch(.youtube, through: mock)
        #expect(mock.launchedApps == [.netflix, .youtube])
        #expect(mock.commands.isEmpty)
        mock.disconnect()
        await #expect(throws: RemoteError.self) { try await dispatcher.launch(.netflix, through: mock) }
    }

    @Test func touchpadSensitivityPersistsAndIsClamped() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set(200.0, forKey: "touchpadSensitivity")
        let model = RemoteViewModel(defaults: defaults)
        #expect(model.touchpadSensitivity == 60)
        model.touchpadSensitivity = 24
        #expect(RemoteViewModel(defaults: defaults).touchpadSensitivity == 24)
    }

    @Test func manualAddressesAcceptOnlyIPAddresses() throws {
        #expect(try TVDevice.manual(" 192.168.1.20 ").host == "192.168.1.20")
        #expect(try TVDevice.manual("2001:db8::1").addresses == ["2001:db8::1"])
        for input in ["", "999.1.1.1", "192.168.1.20:6466", "http://192.168.1.20", "some-host", "192.168.1"] {
            #expect(throws: RemoteError.self) { try TVDevice.manual(input) }
        }
    }

    @Test func openPortsNeverAuthorizePairingOrCommands() async throws {
        let device = try TVDevice.manual("192.168.1.20")
        let report = await ConnectionDiagnostics(checker: OpenPortChecker()).run(for: device)
        #expect(report.ports.map(\.port) == [6466, 6467])
        #expect(report.ports.allSatisfy { $0.outcome == .open })
        #expect(!report.protocolVerified)
        #expect(report.text.contains("UNVERIFIED"))
        let transport = AndroidTVRemoteTransport()
        await #expect(throws: ATVError.self) { try await transport.connect(to: device) }
        await #expect(throws: RemoteError.self) { try await transport.send(.power) }
        #expect(!transport.isConnected)
        #expect(transport.supportedCommands.isEmpty)
    }

    @Test func mockTransportCannotConnectToRealDevice() async throws {
        let mock = MockRemoteTransport()
        await #expect(throws: RemoteError.self) { try await mock.connect(to: TVDevice.manual("192.168.1.20")) }
        await #expect(throws: RemoteError.self) { try await CommandDispatcher().dispatch(.home, through: mock) }
        try await mock.connect(to: .demo)
        try await CommandDispatcher().dispatch(.home, through: mock)
        #expect(mock.commands == [.home])
        mock.disconnect()
        await #expect(throws: RemoteError.self) { try await mock.send(.home) }
    }

    @Test func bluetoothNeverClaimsSupport() async {
        let bluetooth = UnverifiedBluetoothTransport()
        #expect(!bluetooth.feasibilityVerified)
        #expect(bluetooth.supportedCommands.isEmpty)
        await #expect(throws: RemoteError.self) { try await bluetooth.connect(to: .demo) }
    }

    @Test func inspectionNeverAuthorizesRealCommands() async throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let model = RemoteViewModel(diagnostics: ConnectionDiagnostics(checker: OpenPortChecker()), defaults: defaults)
        #expect(!model.isConnected)
        model.inspect(try TVDevice.manual("192.168.1.20"))
        #expect(!model.isConnected)
        #expect(!model.supports(.home))
        #expect(model.savedDevices.count == 1)
        model.cancelDiagnostics()
        #expect(!model.isChecking)
        let reloaded = RemoteViewModel(defaults: defaults)
        #expect(reloaded.savedDevices.count == 1)
        #expect(!reloaded.isConnected)
        #expect(reloaded.selectedDevice == nil)
    }

    @Test func cancelledTCPProbeCompletes() async {
        let checker = TCPPortChecker(timeout: .seconds(1))
        let task = Task { await checker.check(host: "127.0.0.1", port: 9) }
        task.cancel()
        let result = await task.value
        #expect(result.outcome == .cancelled)
    }

    @Test func tcpProbeDetectsListenerWithoutSendingCommands() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        let ready = await withCheckedContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: continuation.resume(returning: true)
                case .failed: continuation.resume(returning: false)
                default: break
                }
            }
            listener.newConnectionHandler = { connection in connection.cancel() }
            listener.start(queue: .main)
        }
        defer { listener.cancel() }
        #expect(ready)
        let port = try #require(listener.port?.rawValue)
        let result = await TCPPortChecker().check(host: "127.0.0.1", port: port)
        #expect(result.outcome == .open)
    }
}

@MainActor
private final class OpenPortChecker: PortChecking {
    func check(host: String, port: UInt16) async -> PortDiagnostic {
        PortDiagnostic(port: port, outcome: .open, detail: "Test fixture")
    }
}
