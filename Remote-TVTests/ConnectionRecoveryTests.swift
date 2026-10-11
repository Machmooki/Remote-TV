import Testing
import Foundation
import Security
@testable import Remote_TV

@MainActor
struct ConnectionRecoveryTests {
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<150 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition(), "Asynchronous connection state did not settle")
    }
    @Test func sendingCommandsKeepsQuietSessionAliveThenRealIdleDropsIt() async throws {
        let channel = RecoveryChannel()
        let transport = AndroidTVRemoteTransport(idleTimeout: .milliseconds(150), channelFactory: { _ in channel })
        var reason: Error?
        transport.onDisconnect = { reason = $0 }
        defer { transport.disconnect() }
        try await transport.connect(to: TVDevice.manual("127.0.0.1"))
        // No server messages after start: the old receive-only deadline would expire here.
        for _ in 0..<12 {
            try await Task.sleep(for: .milliseconds(35))
            try await transport.send(.up)
            #expect(transport.isConnected)
        }
        #expect(transport.sentCommands == 12)
        #expect(channel.timeouts.last! == nil)
        try await wait { !transport.isConnected }
        #expect(reason as? ATVError != nil)
        #expect(reason?.localizedDescription.contains("Remote session became inactive") == true)
        #expect(reason?.localizedDescription.contains("handshake") == false)
    }
    @Test func repeatedIdlePingsAreAnsweredWithoutAnyCommand() async throws {
        let channel = RecoveryChannel()
        let transport = AndroidTVRemoteTransport(idleTimeout: .milliseconds(150), channelFactory: { _ in channel })
        defer { transport.disconnect() }
        try await transport.connect(to: TVDevice.manual("127.0.0.1"))
        for counter in 1...8 {
            try await Task.sleep(for: .milliseconds(35))
            channel.deliver(Proto.blob(8, Proto.int(1, UInt64(counter))))
            try await wait { transport.answeredPings == counter }
            #expect(transport.isConnected)
            #expect(channel.sent.last == Proto.blob(9, Proto.int(1,UInt64(counter))))
        }
        #expect(transport.sentCommands == 0)
    }
    @Test func transientDisconnectReconnectsWithoutReplayingACommand() async throws {
        let harness = try RecoveryHarness()
        defer { harness.stop() }
        harness.manager.connectKnown(harness.device)
        try await wait { harness.manager.connected }
        try await harness.service.send(.home)
        let old = harness.transports[0]
        harness.channels[0].fail(ATVError.network("Fixture Wi-Fi interruption"))
        try await wait { harness.channels.count == 2 && harness.manager.connected }
        #expect(harness.transports[1].sentCommands == 0)
        #expect(harness.channels[1].sent.allSatisfy { (try? Proto($0).bytes[10]) == nil })
        #expect(harness.manager.tlsResult.contains("paired peer verified"))
        old.onDisconnect?(ATVError.network("Stale callback from old session"))
        #expect(harness.manager.connected)
        #expect(harness.channels.count == 2)
    }
    @Test func retryBackoffGrowsAndOnlyPairedConnectionsRetry() async throws {
        let harness = try RecoveryHarness()
        defer { harness.stop() }
        harness.failures = [ATVError.network("First failure"), ATVError.network("Second failure")]
        harness.manager.connectKnown(harness.device)
        try await wait { harness.manager.connected }
        #expect(harness.channels.count == 3)
        #expect(harness.attempts == [1,2])
        #expect(harness.manager.reconnectAttempt == 2)
        let unpaired = try TVDevice.manual("127.0.0.2")
        harness.manager.cancel()
        harness.manager.connectKnown(unpaired)
        try await Task.sleep(for: .milliseconds(50))
        #expect(harness.channels.count == 3)
        #expect(!harness.manager.awaitingCode)
    }
    @Test func certificateOrPermissionFailureStopsAutomaticRetries() async throws {
        for error: ATVError in [.identityChanged, .accessDenied, .tlsRejected("Fixture rejected client certificate") ] {
            let harness = try RecoveryHarness()
            defer { harness.stop() }
            harness.failures = [error]
            harness.manager.connectKnown(harness.device)
            try await wait { !harness.manager.busy && harness.channels.count == 1 }
            try await Task.sleep(for: .milliseconds(60))
            #expect(harness.channels.count == 1)
            #expect(!harness.manager.connected)
            #expect(!harness.manager.awaitingCode)
            #expect(harness.manager.protocolError == error.localizedDescription)
            harness.manager.suspend(); harness.manager.resume()
            try await Task.sleep(for: .milliseconds(50))
            #expect(harness.channels.count == 1)
        }
    }
    @Test func backgroundResumeReconnectsButExplicitCancelAndAutoOffDoNot() async throws {
        let harness = try RecoveryHarness()
        defer { harness.stop() }
        harness.manager.connectKnown(harness.device)
        try await wait { harness.manager.connected }
        harness.manager.suspend()
        #expect(!harness.manager.connected)
        #expect(harness.manager.state == "Paused in background")
        try await Task.sleep(for: .milliseconds(60))
        #expect(harness.channels.count == 1)
        harness.manager.resume()
        try await wait { harness.channels.count == 2 && harness.manager.connected }
        harness.manager.automaticReconnect = false
        harness.channels[1].fail(ATVError.network("Fixture disconnect"))
        try await wait { !harness.manager.connected }
        try await Task.sleep(for: .milliseconds(60))
        #expect(harness.channels.count == 2)
        harness.manager.automaticReconnect = true
        try await wait { harness.channels.count == 3 && harness.manager.connected }
        harness.manager.cancel(); harness.manager.suspend(); harness.manager.resume()
        try await Task.sleep(for: .milliseconds(60))
        #expect(harness.channels.count == 3)
    }
    @Test func cancellingPendingRetryStopsAllFurtherAttempts() async throws {
        let harness = try RecoveryHarness(delay: .seconds(1))
        defer { harness.stop() }
        harness.failures = [ATVError.network("Fixture offline")]
        harness.manager.connectKnown(harness.device)
        try await wait { harness.manager.reconnectAttempt == 1 }
        harness.manager.cancel()
        try await Task.sleep(for: .milliseconds(80))
        #expect(harness.channels.count == 1)
        #expect(harness.manager.reconnectAttempt == 0)
    }
    @Test func launchRestoresExistingPairingAndSavesLastSuccessfulDevice() async throws {
        let harness = try RecoveryHarness()
        defer { harness.stop() }
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set(try JSONEncoder().encode([harness.device]), forKey: "savedDevices")
        let model = RemoteViewModel(service: harness.service, defaults: defaults, connectionManager: harness.manager)
        model.resume()
        try await wait { model.isConnected }
        #expect(model.selectedDevice == harness.device)
        #expect(defaults.data(forKey: "lastConnectedDevice") != nil)
        model.stopConnection()
        model.suspend(); model.resume()
        try await Task.sleep(for: .milliseconds(60))
        #expect(harness.channels.count == 1)
        #expect(defaults.bool(forKey: "autoConnectPaused"))
        let next = try RecoveryHarness(store: harness.store)
        defer { next.stop() }
        let relaunched = RemoteViewModel(service: next.service, defaults: defaults, connectionManager: next.manager)
        relaunched.resume()
        #expect(relaunched.selectedDevice == nil)
        #expect(next.channels.isEmpty)
    }
    @Test func disablingAutomaticConnectionPersistsAcrossLaunch() async throws {
        let harness = try RecoveryHarness()
        defer { harness.stop() }
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set(try JSONEncoder().encode([harness.device]), forKey: "savedDevices")
        let model = RemoteViewModel(service: harness.service, defaults: defaults, connectionManager: harness.manager)
        model.automaticConnection = false
        model.resume()
        #expect(harness.channels.isEmpty)
        #expect(defaults.object(forKey: "automaticConnection") as? Bool == false)
        #expect(!RemoteViewModel(defaults: defaults).automaticConnection)
    }
}

@MainActor
private final class RecoveryHarness {
    let device: TVDevice
    let service = RemoteControlService()
    let store: SecureCredentialStore
    var channels: [RecoveryChannel] = []
    var transports: [AndroidTVRemoteTransport] = []
    var failures: [Error] = []
    var attempts: [Int] = []
    var manager: ConnectionManager!
    init(store: SecureCredentialStore? = nil, delay: Duration = .milliseconds(15)) throws {
        self.store = store ?? SecureCredentialStore(service: "AISRemote.tests." + UUID().uuidString)
        device = try TVDevice.manual("127.0.0.1")
        try self.store.save(Data([1]), for: device.id)
        manager = ConnectionManager(service: service, store: self.store, observesNetwork: false, retryDelay: { [weak self] attempt in
            self?.attempts.append(attempt); return delay
        }, transportFactory: { [weak self] _, _, _, _ in
            let channel = RecoveryChannel()
            if let self, !self.failures.isEmpty { channel.openError = self.failures.removeFirst() }
            let transport = AndroidTVRemoteTransport(channelFactory: { _ in channel })
            self?.channels.append(channel); self?.transports.append(transport)
            return transport
        })
    }
    func stop() { manager.cancel(); try? store.delete(for: device.id) }
}

@MainActor
private final class RecoveryChannel: ATVChannel {
    var peerCertificate: SecCertificate? { nil }
    var sent: [Data] = []
    var timeouts: [Duration?] = []
    var openError: Error?
    private var messages = [Proto.blob(1,Proto.int(1,611)), Proto.blob(2,Proto.int(1,611)), Proto.blob(40,Proto.int(1,1))]
    private var waiter: CheckedContinuation<Data, Error>?
    private var failure: Error?
    func open() async throws { if let openError { throw openError } }
    func send(_ message: Data) async throws {
        if let failure { throw failure }
        sent.append(message)
    }
    func next(timeout: Duration?) async throws -> Data {
        timeouts.append(timeout)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            if let failure { throw failure }
            if !messages.isEmpty { return messages.removeFirst() }
            return try await withCheckedThrowingContinuation { waiter = $0 }
        } onCancel: { Task { @MainActor [weak self] in self?.close() } }
    }
    func deliver(_ data: Data) {
        if let waiter { self.waiter = nil; waiter.resume(returning: data) }
        else { messages.append(data) }
    }
    func fail(_ error: Error) { failure = error; waiter?.resume(throwing: error); waiter = nil }
    func close() { fail(CancellationError()) }
}

import Network

@MainActor
struct QuietTLSRemoteTests {
    @Test func realTLSCommandTrafficSurvivesIdleDeadlineWithNoServerReplies() async throws {
        let attrs: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048]
        let key = try #require(SecKeyCreateRandomKey(attrs as CFDictionary, nil))
        let cert = try #require(SecCertificateCreateWithData(nil, try DER.certificate(key: key) as CFData))
        let identity = try #require(SecIdentityCreate(nil, cert, key))
        let peer = try QuietTLSRemote(identity: identity)
        try await peer.start()
        let port = try #require(peer.listener.port?.rawValue)
        let transport = AndroidTVRemoteTransport(idleTimeout: .milliseconds(350)) { _ in
            AndroidTVTLSChannel(host: "127.0.0.1", port: port, identity: identity,
                pinnedCertificate: SecCertificateCopyData(cert) as Data, onTLS: { _ in })
        }
        defer { transport.disconnect(); peer.stop() }
        try await transport.connect(to: TVDevice.manual("127.0.0.1"))
        for _ in 0..<10 {
            try await Task.sleep(for: .milliseconds(70))
            try await transport.send(.up)
            #expect(transport.isConnected)
        }
        #expect(transport.sentCommands == 10)
        #expect(transport.receivedMessages == 0)
        for _ in 0..<50 {
            if peer.receivedKeys == 10 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(peer.receivedKeys == 10)
        try await Task.sleep(for: .milliseconds(450))
        #expect(!transport.isConnected)
    }
}

@MainActor
private final class QuietTLSRemote {
    let listener: NWListener
    private var connection: NWConnection?
    private var waiter: CheckedContinuation<Void, Error>?
    private var frames = ProtoFrames()
    private(set) var receivedKeys = 0
    init(identity: SecIdentity) throws {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, sec_identity_create(identity)!)
        listener = try NWListener(using: NWParameters(tls: tls, tcp: NWProtocolTCP.Options()), on: .any)
    }
    func start() async throws {
        try await withCheckedThrowingContinuation { waiter = $0
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    switch state {
                    case .ready: self.waiter?.resume(); self.waiter = nil
                    case .failed(let error): self.waiter?.resume(throwing: error); self.waiter = nil
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor [weak self] in
                    guard let self else { connection.cancel(); return }
                    self.connection = connection
                    connection.stateUpdateHandler = { [weak self] state in
                        if case .ready = state {
                            Task { @MainActor [weak self] in
                                self?.send(Proto.blob(1, Proto.int(1,611)))
                                self?.receive()
                            }
                        }
                    }
                    connection.start(queue: .main)
                }
            }
            listener.start(queue: .main)
        }
    }
    private func send(_ data: Data) {
        connection?.send(content: ProtoFrames.encode(data), completion: .contentProcessed { _ in })
    }
    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    if let data {
                        for frame in try self.frames.append(data) {
                            let message = try Proto(frame)
                            if message.bytes[1] != nil { self.send(Proto.blob(2,Proto.int(1,611))) }
                            if message.bytes[2] != nil { self.send(Proto.blob(40,Proto.int(1,1))) }
                            if message.bytes[10] != nil { self.receivedKeys += 1 }
                        }
                    }
                    if !complete && error == nil { self.receive() }
                } catch { self.stop() }
            }
        }
    }
    func stop() { connection?.cancel(); listener.cancel() }
}
