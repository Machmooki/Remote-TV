import Foundation
import Observation
import Network

@MainActor
@Observable
final class ConnectionManager {
    typealias TransportFactory = (TVDevice, ClientIdentity, Data, @escaping (String) -> Void) -> AndroidTVRemoteTransport
    private(set) var state = "Not connected"
    private(set) var tlsResult = "Not attempted"
    private(set) var pairingState = "Not paired"
    private(set) var protocolError = "None"
    private(set) var commandError = "None"
    private(set) var awaitingCode = false
    private(set) var busy = false
    private(set) var connected = false
    private(set) var reconnectAttempt = 0
    private(set) var sessionActivity = "No session activity"
    var onConnected: ((TVDevice) -> Void)?
    var automaticReconnect = true {
        didSet {
            if !automaticReconnect {
                retryTask?.cancel(); retryTask = nil
                if !connected && !busy && !awaitingCode { state = "Not connected · auto reconnect off" }
            }
            else if desired && !blocked && foreground && !connected && !busy && !awaitingCode { scheduleReconnect() }
        }
    }
    private var pairing: PairingManager?
    private var task: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var device: TVDevice?
    private var generation = UUID()
    private var sessionID = UUID()
    private var desired = false
    private var blocked = false
    private var foreground = true
    private var networkAvailable = true
    private var monitor: NWPathMonitor?
    private var connectedAt: ContinuousClock.Instant?
    private let store: SecureCredentialStore
    private let service: RemoteControlService
    private let transportFactory: TransportFactory
    private let retryDelay: (Int) -> Duration
    private let observesNetwork: Bool

    init(service: RemoteControlService, store: SecureCredentialStore = SecureCredentialStore(),
         observesNetwork: Bool = true, retryDelay: @escaping (Int) -> Duration = { attempt in
             .seconds(min(30, 1 << min(max(0, attempt - 1), 5)))
         }, transportFactory: @escaping TransportFactory = { device, identity, pin, onTLS in
             AndroidTVRemoteTransport { target in
                 AndroidTVTLSChannel(host: target.host, port: 6466, identity: identity.identity,
                                     pinnedCertificate: pin, onTLS: onTLS)
             }
         }) {
        self.service = service; self.store = store; self.observesNetwork = observesNetwork
        self.retryDelay = retryDelay; self.transportFactory = transportFactory
    }
    func connect(_ device: TVDevice, pairAgain: Bool = false) {
        cancel()
        self.device = device; desired = true
        startNetworkObservation()
        beginAttempt(pairAgain: pairAgain, allowPairing: true)
    }
    /// Automatic connections only reuse an existing trust record; never show unsolicited PINs.
    func connectKnown(_ device: TVDevice) {
        guard hasPairing(for: device), !device.isLegacyDemo else { return }
        cancel()
        self.device = device; desired = true
        startNetworkObservation()
        beginAttempt(allowPairing: false)
    }
    func hasPairing(for device: TVDevice) -> Bool { (try? store.load(for: device.id)) != nil }
    private func beginAttempt(pairAgain: Bool = false, allowPairing: Bool = false) {
        guard desired, foreground, !busy, let device else { return }
        retryTask?.cancel(); retryTask = nil
        let generation = self.generation
        busy = true; blocked = false; state = "Preparing secure identity"
        tlsResult = "Not attempted"; sessionActivity = "Negotiating session"
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let identity = try ClientIdentity.loadOrCreate()
                let pin = pairAgain ? nil : try store.load(for: device.id)
                if let pin {
                    pairingState = "Saved pairing identity"
                    try await openRemote(device, identity: identity, pin: pin)
                } else {
                    guard allowPairing else { throw ATVError.message("No saved pairing for this device. Connect manually to pair once.") }
                    state = "Checking pairing protocol on 6467"
                    pairingState = "Negotiating; compatibility unverified"
                    let channel = AndroidTVTLSChannel(host: device.host, port: 6467, identity: identity.identity, pinnedCertificate: nil) { [weak self] result in
                        guard let self, self.generation == generation else { return }; self.tlsResult = result
                    }
                    let manager = PairingManager(channel: channel, clientCertificate: identity.certificate)
                    pairing = manager
                    try await manager.start()
                    try Task.checkCancellation()
                    awaitingCode = true; pairingState = "Verified pairing protocol · waiting for TV code"
                    state = "Enter the code displayed on your TV"
                }
                guard generation == self.generation else { return }
                busy = false; task = nil
                // A disconnect can arrive immediately after remote_start, before this task returns.
                if !connected && !awaitingCode { scheduleReconnect() }
            } catch {
                guard generation == self.generation else { return }
                attemptFailed(error, mayRetry: !allowPairing || hasPairing(for: device))
            }
        }
    }
    func submit(code: String) {
        guard awaitingCode, let pairing, let device, !busy else { return }
        busy = true
        let generation = self.generation
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let pin = try await pairing.finish(code: code)
                try Task.checkCancellation()
                try store.save(pin, for: device.id)
                pairing.cancel(); self.pairing = nil; awaitingCode = false
                pairingState = "Paired · saved in Keychain"
                try await openRemote(device, identity: ClientIdentity.loadOrCreate(), pin: pin)
                guard generation == self.generation else { return }
                busy = false; task = nil
                if !connected { scheduleReconnect() }
            } catch {
                guard generation == self.generation else { return }
                if pairing.awaitingCode {
                    ConnectionLog.event("PAIRING_FAILED")
                    protocolError = error.localizedDescription; busy = false; task = nil
                    state = "Pairing not completed · check code or restart pairing"
                } else { attemptFailed(error, mayRetry: self.pairing == nil && hasPairing(for: device)) }
            }
        }
    }
    private func openRemote(_ device: TVDevice, identity: ClientIdentity, pin: Data) async throws {
        state = "Authenticating remote session on 6466"
        let generation = self.generation
        sessionID = UUID()
        let sessionID = self.sessionID
        let transport = transportFactory(device, identity, pin) { [weak self] result in
            guard let self, self.generation == generation, self.sessionID == sessionID else { return }
            self.tlsResult = result
        }
        transport.onDisconnect = { [weak self] error in
            guard let self, self.generation == generation, self.sessionID == sessionID else { return }
            if let connectedAt, connectedAt.duration(to: .now) >= .seconds(30) { reconnectAttempt = 0 }
            connected = false; protocolError = error.localizedDescription
            state = "Disconnected"
            blocked = !ATVError.canRetry(error)
            if blocked { state = "Connection needs attention · automatic retry stopped" }
            else { scheduleReconnect() }
        }
        transport.onProtocolError = { [weak self] detail in
            guard let self, self.generation == generation, self.sessionID == sessionID else { return }
            self.protocolError = detail
        }
        transport.onActivity = { [weak self] received, sent, pings in
            guard let self, self.generation == generation, self.sessionID == sessionID else { return }
            self.sessionActivity = "Received \(received) · sent \(sent) · pings answered \(pings)"
        }
        service.replaceTransport(transport)
        try await service.connect(to: device)
        try Task.checkCancellation()
        guard generation == self.generation, sessionID == self.sessionID else { throw CancellationError() }
        guard service.isConnected else { return }
        connected = true; connectedAt = .now
        state = "Connected · authenticated Android TV Remote v2"
        tlsResult = "TLS 6466 completed · paired peer verified"
        pairingState = "Paired · authenticated session"
        protocolError = "None"
        onConnected?(device)
    }
    private func scheduleReconnect() {
        guard desired, automaticReconnect, foreground, !blocked, !busy, !awaitingCode, !connected, retryTask == nil,
              let device, hasPairing(for: device) else { return }
        if !networkAvailable { state = "Waiting for network · auto reconnect enabled"; return }
        reconnectAttempt += 1
        let delay = retryDelay(reconnectAttempt)
        let generation = self.generation
        state = "Reconnecting automatically · attempt \(reconnectAttempt)"
        ConnectionLog.event("REMOTE_RECONNECT_SCHEDULED", "attempt=\(reconnectAttempt)")
        retryTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, generation == self.generation else { return }
            retryTask = nil
            beginAttempt(allowPairing: false)
        }
    }
    private func attemptFailed(_ error: Error, mayRetry: Bool) {
        if pairing != nil { ConnectionLog.event("PAIRING_FAILED"); pairingState = "Pairing failed · restart required" }
        pairing?.cancel(); pairing = nil; service.disconnect()
        awaitingCode = false; busy = false; connected = false; task = nil
        protocolError = error.localizedDescription
        state = "Connection needs attention"
        blocked = !mayRetry || !ATVError.canRetry(error)
        if !blocked { scheduleReconnect() }
    }
    func recordCommandFailure(_ error: Error) {
        commandError = error.localizedDescription; ConnectionLog.event("REMOTE_COMMAND_FAILED")
    }
    private func stopWork() {
        generation = UUID(); sessionID = UUID()
        task?.cancel(); task = nil; retryTask?.cancel(); retryTask = nil
        pairing?.cancel(); pairing = nil; service.disconnect()
        busy = false; awaitingCode = false; connected = false; connectedAt = nil
        monitor?.cancel(); monitor = nil
    }
    /// Explicit disconnect opts out of subsequent retries and foreground resumption.
    func cancel() {
        desired = false; blocked = false; stopWork(); reconnectAttempt = 0
        state = "Not connected"; tlsResult = "Not attempted"
        pairingState = "Not paired / saved pairing checked on Connect"
        protocolError = "None"; commandError = "None"; sessionActivity = "No session activity"
    }
    func suspend() {
        foreground = false; stopWork()
        state = desired ? "Paused in background" : "Not connected"
    }
    func resume() {
        foreground = true; startNetworkObservation()
        guard desired, automaticReconnect, !blocked, !connected, !busy, !awaitingCode else { return }
        beginAttempt(allowPairing: false)
    }
    private func startNetworkObservation() {
        guard observesNetwork, foreground, desired, monitor == nil else { return }
        let monitor = NWPathMonitor(); self.monitor = monitor
        let generation = self.generation
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self, generation == self.generation else { return }
                let wasAvailable = self.networkAvailable
                self.networkAvailable = path.status == .satisfied
                if !self.networkAvailable {
                    self.retryTask?.cancel(); self.retryTask = nil
                    if !self.connected && !self.busy { self.state = "Waiting for network · auto reconnect enabled" }
                } else if !wasAvailable { self.scheduleReconnect() }
            }
        }
        monitor.start(queue: .main)
    }
    var diagnosticText: String {
        "State: \(state)\nTLS: \(tlsResult)\nPairing: \(pairingState)\nProtocol error: \(protocolError)\nCommand transmission error: \(commandError)\nAuto reconnect: \(automaticReconnect) · attempt \(reconnectAttempt)\nSession activity: \(sessionActivity)"
    }
}
