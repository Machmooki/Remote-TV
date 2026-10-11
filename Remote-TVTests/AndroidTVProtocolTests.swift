import Testing
import Foundation
import Security
import CryptoKit
@testable import Remote_TV

@MainActor
struct AndroidTVProtocolTests {
    private func certificate() throws -> SecCertificate {
        let attrs: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048]
        let key = try #require(SecKeyCreateRandomKey(attrs as CFDictionary, nil))
        let data = try DER.certificate(key: key)
        let certificate = try #require(SecCertificateCreateWithData(nil, data as CFData))
        #expect(SecIdentityCreate(nil, certificate, key) != nil)
        // Verify the actual X.509 signature against its public key independently of the writer.
        var outer = DERReader(data)
        var sequence = DERReader(try outer.read(0x30))
        let tbs = try sequence.read(0x30)
        _ = try sequence.read(0x30)
        let signature = try sequence.read(0x03).dropFirst()
        #expect(SecKeyVerifySignature(SecKeyCopyPublicKey(key)!, .rsaSignatureMessagePKCS1v15SHA256,
            DER.sequence(tbs) as CFData, Data(signature) as CFData, nil))
        return certificate
    }
    @Test func framingSurvivesEverySplitAndMultipleFrames() throws {
        let payload = Data(repeating: 0x42, count: 256)
        let wire = ProtoFrames.encode(payload) + ProtoFrames.encode(Data([8,2]))
        for split in 0...wire.count {
            var decoder = ProtoFrames()
            let first = try decoder.append(Data(wire.prefix(split)))
            let second = try decoder.append(Data(wire.dropFirst(split)))
            #expect(first + second == [payload, Data([8,2])])
        }
        var decoder = ProtoFrames()
        #expect(throws: ATVError.self) { try decoder.append(Data(repeating: 0xff, count: 10)) }
        var oversized = ProtoFrames()
        #expect(throws: ATVError.self) { try oversized.append(Proto.varint(1_048_577)) }
        #expect(throws: ATVError.self) { try Proto(Data([0x80])) }
        #expect(throws: ATVError.self) { try Proto(Data([0x0a,0x05,0x01])) }
        #expect(throws: ATVError.self) { try Proto(Data([0x00,0x00])) }
    }
    @Test func referenceWireFieldsAndAndroidKeyCodes() throws {
        // Literal golden bytes from polo.proto / remotemessage.proto, including varint tag 40.
        #expect(Proto.polo(31, Data()) == Data([8,2,16,200,1,250,1,0]))
        #expect(Proto.blob(10, Proto.int(1,19) + Proto.int(2,3)) == Data([82,4,8,19,16,3]))
        #expect(RemoteCommand.up.androidKeyCode == 19)
        #expect(RemoteCommand.down.androidKeyCode == 20)
        #expect(RemoteCommand.select.androidKeyCode == 23)
        #expect(RemoteCommand.back.androidKeyCode == 4)
        #expect(RemoteCommand.home.androidKeyCode == 3)
        #expect(RemoteCommand.menu.androidKeyCode == 82)
        #expect(RemoteCommand.volumeUp.androidKeyCode == 24)
        #expect(RemoteCommand.volumeDown.androidKeyCode == 25)
    }
    @Test func identityPersistsInKeychain() throws {
        let first = try ClientIdentity.loadOrCreate()
        let second = try ClientIdentity.loadOrCreate()
        #expect(SecCertificateCopyData(first.certificate) == SecCertificateCopyData(second.certificate))
        #expect(try PairingProof.rsa(first.certificate).0.count == 256)
        #expect(try PairingProof.rsa(first.certificate).1 == Data([1,0,1]))
    }
    @Test func pairingRequiresNegotiatedProtocolAndCertificateBoundCode() async throws {
        let client = try certificate(); let server = try certificate()
        let encoding = Proto.int(1,3) + Proto.int(2,6)
        let channel = ScriptedChannel(peer: server, responses: [Proto.polo(11, Data()),
            Proto.polo(20, Proto.blob(2,encoding) + Proto.int(3,2)), Proto.polo(31,Data()), Proto.polo(41, Proto.blob(1,Data()))])
        let manager = PairingManager(channel: channel, clientCertificate: client)
        try await manager.start()
        #expect(manager.awaitingCode)
        #expect(channel.sent.count == 3)
        #expect(try Proto(channel.sent[0]).nested(10).bytes[1]?.first == Data("atvremote".utf8))
        await #expect(throws: ATVError.self) { try await manager.finish(code: "B8:59:CE:5E:1D:06") }
        #expect(channel.sent.count == 3)
        let c = try PairingProof.rsa(client); let s = try PairingProof.rsa(server)
        let hash = Data(SHA256.hash(data: c.0 + c.1 + s.0 + s.1 + Data([0x12,0x34])))
        let code = String(format: "%02X1234", hash.first!)
        let pin = try await manager.finish(code: code)
        #expect(pin == SecCertificateCopyData(server) as Data)
        #expect(!manager.awaitingCode)
        #expect(try Proto(channel.sent.last!).nested(40).bytes[1]?.first == hash)
        channel.close()
    }
    @Test func unsupportedPairingReplyCannotRequestCode() async throws {
        let cert = try certificate()
        let channel = ScriptedChannel(peer: cert, responses: [Proto.int(1,2) + Proto.int(2,402)])
        let manager = PairingManager(channel: channel, clientCertificate: cert)
        await #expect(throws: ATVError.self) { try await manager.start() }
        #expect(!manager.awaitingCode)
        #expect(channel.sent.count == 1)
    }
    @Test func authenticatedSessionNegotiatesFeaturesAndWritesRealCommands() async throws {
        let channel = ScriptedChannel(responses: [Proto.blob(1,Proto.int(1,611)), Proto.blob(2,Proto.int(1,611)),
            Proto.blob(8,Proto.int(1,123)), Proto.blob(40,Proto.int(1,1))])
        let transport = AndroidTVRemoteTransport(channelFactory: { _ in channel })
        #expect(!transport.isConnected)
        try await transport.connect(to: TVDevice.manual("127.0.0.1"))
        #expect(transport.isConnected)
        #expect(channel.sent[2] == Proto.blob(9,Proto.int(1,123)))
        for command: RemoteCommand in [.up,.down,.select,.back,.home,.volumeUp,.volumeDown,.menu] {
            try await transport.send(command)
            #expect(try Proto(channel.sent.last!).nested(10).integers[1] == command.androidKeyCode)
        }
        try await transport.launch(.youtube)
        #expect(try Proto(channel.sent.last!).nested(90).bytes[1]?.first == Data("https://www.youtube.com".utf8))
        channel.failWrites = true
        await #expect(throws: ATVError.self) { try await transport.send(.up) }
        transport.disconnect()
        #expect(!transport.isConnected)
    }
    @Test func imeUsesReferenceWireBytesLatestCountersAndUnicodeScalars() async throws {
        let channel = ScriptedChannel(responses: [Proto.blob(1,Proto.int(1,615)), Proto.blob(2,Data()),
            Proto.blob(21,Proto.int(1,7) + Proto.int(2,12)), Proto.blob(40,Data()),
            Proto.blob(21,Proto.int(1,9) + Proto.int(2,21))])
        let transport = AndroidTVRemoteTransport(channelFactory: { _ in channel })
        try await transport.connect(to: TVDevice.manual("127.0.0.1"))
        defer { transport.disconnect() }
        #expect(transport.supportsTextInput)
        #expect(try Proto(channel.sent[0]).nested(1).integers[1] == 615)
        try await transport.sendText("cat")
        // Golden serialized RemoteMessage from the pinned reference Python protobuf.
        #expect(channel.sent.last == Data([0xaa,0x01,0x13,0x08,0x07,0x10,0x0c,0x1a,0x0d,0x08,0x01,0x12,0x09,0x08,0x02,0x10,0x02,0x1a,0x03,0x63,0x61,0x74]))
        for _ in 0..<60 {
            if transport.receivedMessages > 0 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let text = "ก้😀e\u{301}"
        try await transport.sendText(text)
        let batch = try Proto(channel.sent.last!).nested(21)
        #expect(batch.integers[1] == 9)
        #expect(batch.integers[2] == 21)
        let object = try batch.nested(3).nested(2)
        #expect(object.integers[1] == 4 && object.integers[2] == 4)
        #expect(object.bytes[3]?.first == Data(text.utf8))
        #expect(transport.sentCommands == 2)
    }
    @Test func keyboardSearchWritesTextThenEnterAndRejectsInvalidOrUnsupportedText() async throws {
        let channel = ScriptedChannel(responses: [Proto.blob(1,Proto.int(1,615)), Proto.blob(2,Data()), Proto.blob(40,Data())])
        let transport = AndroidTVRemoteTransport(channelFactory: { _ in channel })
        let service = RemoteControlService(transport: transport)
        try await service.connect(to: TVDevice.manual("127.0.0.1"))
        defer { service.disconnect() }
        try await service.sendText("ค้นหา", submit: true)
        #expect(try Proto(channel.sent[channel.sent.count - 2]).bytes[21] != nil)
        #expect(channel.sent.last == Data([82,4,8,66,16,3]))
        let written = channel.sent.count
        for text in ["", String(repeating: "a", count: 2049)] {
            await #expect(throws: RemoteError.self) { try await service.sendText(text, submit: true) }
        }
        #expect(channel.sent.count == written)
        let legacy = ScriptedChannel(responses: [Proto.blob(1,Proto.int(1,611)), Proto.blob(2,Data()), Proto.blob(40,Data())])
        let legacyTransport = AndroidTVRemoteTransport(channelFactory: { _ in legacy })
        try await legacyTransport.connect(to: TVDevice.manual("127.0.0.1"))
        defer { legacyTransport.disconnect() }
        #expect(!legacyTransport.supportsTextInput)
        await #expect(throws: RemoteError.self) { try await CommandDispatcher().sendText("cat", submit: true, through: legacyTransport) }
        #expect(legacy.sent.count == 2)
    }
    @Test func failedTextWriteNeverSubmitsEnter() async throws {
        let channel = ScriptedChannel(responses: [Proto.blob(1,Proto.int(1,615)), Proto.blob(2,Data()), Proto.blob(40,Data())])
        let transport = AndroidTVRemoteTransport(channelFactory: { _ in channel })
        let service = RemoteControlService(transport: transport)
        try await service.connect(to: TVDevice.manual("127.0.0.1"))
        channel.failWrites = true
        await #expect(throws: ATVError.self) { try await service.sendText("cat", submit: true) }
        #expect(channel.sent.count == 2)
        #expect(!transport.isConnected)
        #expect(!transport.supportsTextInput)
    }
    @Test func textSubmitNeverCrossesTransportReplacement() async throws {
        let channel = ScriptedChannel(responses: [Proto.blob(1,Proto.int(1,615)), Proto.blob(2,Data()), Proto.blob(40,Data())])
        let transport = AndroidTVRemoteTransport(channelFactory: { _ in channel })
        let service = RemoteControlService(transport: transport)
        let replacement = MockRemoteTransport()
        try await replacement.connect(to: .demo)
        try await service.connect(to: TVDevice.manual("127.0.0.1"))
        channel.onWrite = { data in
            if (try? Proto(data).bytes[21]) != nil { service.replaceTransport(replacement) }
        }
        await #expect(throws: RemoteError.self) { try await service.sendText("cat", submit: true) }
        #expect(channel.sent.count == 3)
        #expect(replacement.commands.isEmpty)
        #expect(replacement.textTransmissionCount == 0)
        service.disconnect()
    }
    private func longPressFixture(duration: Duration = .milliseconds(60)) async throws -> (AndroidTVRemoteTransport, ScriptedChannel) {
        let channel = ScriptedChannel(responses: [Proto.blob(1,Proto.int(1,615)), Proto.blob(2,Data()), Proto.blob(40,Data())])
        let transport = AndroidTVRemoteTransport(longPressDuration: duration, channelFactory: { _ in channel })
        try await transport.connect(to: TVDevice.manual("127.0.0.1"))
        return (transport, channel)
    }
    private func keyMessages(_ channel: ScriptedChannel) -> [Data] {
        channel.sent.filter { (try? Proto($0).bytes[10]) != nil }
    }
    private func waitForLongDown(_ channel: ScriptedChannel) async throws {
        for _ in 0..<100 {
            if !keyMessages(channel).isEmpty { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        Issue.record("Long OK key-down was not written")
    }
    @Test func longOKUsesStartAndEndRatherThanMenuOrShortSelect() async throws {
        let (transport, channel) = try await longPressFixture()
        defer { transport.disconnect() }
        let start = ContinuousClock.now
        try await transport.send(.longSelect)
        #expect(start.duration(to: .now) >= .milliseconds(60))
        #expect(keyMessages(channel) == [Data([82,4,8,23,16,1]), Data([82,4,8,23,16,2])])
        #expect(transport.sentCommands == 1)
        try await transport.send(.select)
        #expect(keyMessages(channel).last == Data([82,4,8,23,16,3]))
    }
    @Test func cancellingGestureWorkerStillReleasesRecognizedLongOK() async throws {
        let (transport, channel) = try await longPressFixture()
        defer { transport.disconnect() }
        let press = Task { try await transport.send(.longSelect) }
        try await waitForLongDown(channel)
        press.cancel()
        try await press.value
        #expect(keyMessages(channel) == [Data([82,4,8,23,16,1]), Data([82,4,8,23,16,2])])
        #expect(transport.isConnected)
    }
    @Test func nextCommandWaitsForLongOKRelease() async throws {
        let (transport, channel) = try await longPressFixture()
        defer { transport.disconnect() }
        let press = Task { try await transport.send(.longSelect) }
        try await waitForLongDown(channel)
        let next = Task { try await transport.send(.home) }
        try await press.value
        try await next.value
        #expect(keyMessages(channel) == [Data([82,4,8,23,16,1]), Data([82,4,8,23,16,2]), Data([82,4,8,3,16,3])])
    }
    @Test func disconnectDuringLongOKCannotReleaseOrFailReplacementSession() async throws {
        let first = ScriptedChannel(responses: [Proto.blob(1,Proto.int(1,615)), Proto.blob(2,Data()), Proto.blob(40,Data())])
        let second = ScriptedChannel(responses: first.responses)
        var attempts = 0
        let transport = AndroidTVRemoteTransport(longPressDuration: .seconds(1), channelFactory: { _ in
            attempts += 1; return attempts == 1 ? first : second
        })
        defer { transport.disconnect() }
        let device = try TVDevice.manual("127.0.0.1")
        try await transport.connect(to: device)
        let press = Task { try await transport.send(.longSelect) }
        try await waitForLongDown(first)
        transport.disconnect()
        try await transport.connect(to: device)
        await #expect(throws: (any Error).self) { try await press.value }
        #expect(transport.isConnected)
        #expect(keyMessages(first) == [Data([82,4,8,23,16,1])])
        #expect(keyMessages(second).isEmpty)
        #expect(transport.sentCommands == 0)
        try await transport.send(.home)
        #expect(keyMessages(second) == [Data([82,4,8,3,16,3])])
    }
    @Test(arguments: [true, false]) func failedLongOKWriteClosesSession(startFails: Bool) async throws {
        let (transport, channel) = try await longPressFixture()
        channel.failWrites = startFails
        channel.onWrite = { data in
            if (try? Proto(data).nested(10).integers[2]) == 1 { channel.failWrites = true }
        }
        await #expect(throws: ATVError.self) { try await transport.send(.longSelect) }
        #expect(!transport.isConnected)
        #expect(transport.sentCommands == 0)
        #expect(keyMessages(channel).count == (startFails ? 0 : 1))
    }
    @Test func cancelledUnrecognizedHoldWritesNoKeys() async throws {
        let (transport, channel) = try await longPressFixture()
        defer { transport.disconnect() }
        let press = Task { try await transport.send(.longSelect) }
        press.cancel()
        await #expect(throws: CancellationError.self) { try await press.value }
        #expect(keyMessages(channel).isEmpty)
        #expect(transport.isConnected)
    }
    @Test func tlsOrStartAloneNeverConnects() async throws {
        let channel = ScriptedChannel(responses: [Proto.blob(40,Proto.int(1,1))])
        let transport = AndroidTVRemoteTransport(channelFactory: { _ in channel })
        await #expect(throws: ATVError.self) { try await transport.connect(to: TVDevice.manual("127.0.0.1")) }
        #expect(!transport.isConnected)
        #expect(transport.supportedCommands.isEmpty)
    }
    @Test func unsupportedFeaturesAndProtocolErrorsRemainVisible() async throws {
        let channel = ScriptedChannel(responses: [Proto.blob(1,Proto.int(1,3)), Proto.blob(2,Proto.int(1,3)), Proto.blob(40,Data())])
        let transport = AndroidTVRemoteTransport(channelFactory: { _ in channel })
        try await transport.connect(to: TVDevice.manual("127.0.0.1"))
        #expect(transport.supportedApps.isEmpty)
        #expect(!transport.supportedCommands.contains(.volumeUp))
        await #expect(throws: RemoteError.self) { try await transport.send(.volumeUp) }
        transport.disconnect()
        let rejecting = ScriptedChannel(responses: [Proto.blob(3,Proto.int(1,1))])
        let rejected = AndroidTVRemoteTransport(channelFactory: { _ in rejecting })
        await #expect(throws: ATVError.self) { try await rejected.connect(to: TVDevice.manual("127.0.0.1")) }
        #expect(!rejected.isConnected)
    }
}

@MainActor
private final class ScriptedChannel: ATVChannel {
    var peerCertificate: SecCertificate?
    var responses: [Data]
    var sent: [Data] = []
    var failWrites = false
    var onWrite: ((Data) -> Void)?
    init(peer: SecCertificate? = nil, responses: [Data]) { peerCertificate = peer; self.responses = responses }
    func open() async throws {}
    func send(_ message: Data) async throws {
        if failWrites { throw ATVError.message("Fixture write failure") }
        sent.append(message)
        onWrite?(message)
    }
    func next(timeout: Duration?) async throws -> Data {
        if !responses.isEmpty { return responses.removeFirst() }
        try await Task.sleep(for: .seconds(3600))
        throw CancellationError()
    }
    func close() {}
}

@MainActor
struct AndroidTVTLSIntegrationTests {
    @Test func productionBrowserPublishesResolvedDevices() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        let name = "AISRemote-test-" + UUID().uuidString
        listener.service = NWListener.Service(name: name, type: DeviceDiscoveryService.serviceType, domain: "local.")
        listener.newConnectionHandler = { $0.cancel() }
        listener.start(queue: .main)
        let discovery = DeviceDiscoveryService()
        defer { discovery.stop(); listener.cancel() }
        discovery.search()
        for _ in 0..<60 {
            if discovery.devices.contains(where: { $0.name == name }) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let device = try #require(discovery.devices.first(where: { $0.name == name }))
        #expect(!device.host.isEmpty)
        #expect(!device.addresses.isEmpty)
        #expect(device.advertisedService == "_androidtvremote2._tcp")
        #expect(discovery.isSearching)
    }
    @Test func realTLSFramingPinningAndCancellation() async throws {
        let attrs: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048]
        let key = try #require(SecKeyCreateRandomKey(attrs as CFDictionary, nil))
        let cert = try #require(SecCertificateCreateWithData(nil, try DER.certificate(key: key) as CFData))
        let identity = try #require(SecIdentityCreate(nil, cert, key))
        let fixture = try TLSEchoFixture(identity: identity)
        try await fixture.start()
        defer { fixture.stop() }
        let port = try #require(fixture.listener.port?.rawValue)
        let channel = AndroidTVTLSChannel(host: "127.0.0.1", port: port, identity: identity,
            pinnedCertificate: SecCertificateCopyData(cert) as Data, onTLS: { _ in })
        try await channel.open()
        #expect(channel.peerCertificate != nil)
        let payload = Proto.blob(10, Proto.int(1,19) + Proto.int(2,3))
        try await channel.send(payload)
        #expect(try await channel.next(timeout: .seconds(3)) == payload)
        let read = Task { try await channel.next(timeout: .seconds(3)) }
        read.cancel()
        await #expect(throws: CancellationError.self) { try await read.value }
        channel.close()
        let wrongPin = AndroidTVTLSChannel(host: "127.0.0.1", port: port, identity: identity,
            pinnedCertificate: Data([0]), onTLS: { _ in })
        await #expect(throws: ATVError.self) { try await wrongPin.open() }
        wrongPin.close()
    }
}

import Network

@MainActor
private final class TLSEchoFixture {
    let listener: NWListener
    private var clients: [NWConnection] = []
    private var waiter: CheckedContinuation<Void, Error>?
    init(identity: SecIdentity) throws {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, sec_identity_create(identity)!)
        listener = try NWListener(using: NWParameters(tls: tls, tcp: NWProtocolTCP.Options()), on: .any)
    }
    func start() async throws {
        try await withCheckedThrowingContinuation { continuation in
            waiter = continuation
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
                    self.clients.append(connection)
                    connection.start(queue: .main)
                    self.echo(connection)
                }
            }
            listener.start(queue: .main)
        }
    }
    private func echo(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            if let data { connection.send(content: data, completion: .contentProcessed { _ in }) }
            if !complete && error == nil { Task { @MainActor [weak self] in self?.echo(connection) } }
        }
    }
    func stop() {
        listener.cancel()
        clients.forEach { $0.cancel() }
    }
}
