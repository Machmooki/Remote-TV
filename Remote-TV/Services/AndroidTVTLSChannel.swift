import Foundation
import Network
import Security
import CryptoKit

@MainActor
protocol ATVChannel: AnyObject {
    var peerCertificate: SecCertificate? { get }
    func open() async throws
    func send(_ message: Data) async throws
    func next(timeout: Duration?) async throws -> Data
    func close()
}

/// Pairing accepts a self-signed peer temporarily; only the certificate-bound PIN proof
/// authorizes persistence. Remote sessions require the previously paired peer's pin.
@MainActor
final class AndroidTVTLSChannel: ATVChannel {
    private var connection: NWConnection!
    private var openWaiter: CheckedContinuation<Void, Error>?
    private var readWaiter: CheckedContinuation<Data, Error>?
    private var openTimer: Task<Void, Never>?
    private var readTimer: Task<Void, Never>?
    private var frames = ProtoFrames()
    private var messages: [Data] = []
    private var failure: Error?
    private var ready = false
    private(set) var peerCertificate: SecCertificate?
    private let port: UInt16
    private let onTLS: (String) -> Void

    init(host: String, port: UInt16, identity: SecIdentity, pinnedCertificate: Data?, onTLS: @escaping (String) -> Void) {
        self.port = port; self.onTLS = onTLS
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, sec_identity_create(identity)!)
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { [weak self] _, trust, complete in
            let trustRef = sec_trust_copy_ref(trust).takeRetainedValue()
            let chain = SecTrustCopyCertificateChain(trustRef) as? [SecCertificate]
            let certificate = chain?.first
            Task { @MainActor [weak self] in
                guard let self, let certificate else { complete(false); return }
                self.peerCertificate = certificate
                if let pinnedCertificate, SecCertificateCopyData(certificate) as Data != pinnedCertificate {
                    self.fail(ATVError.identityChanged)
                    complete(false)
                } else { complete(true) }
            }
        }, .main)
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 15
        tcp.keepaliveInterval = 5
        tcp.keepaliveCount = 3
        tcp.noDelay = true
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!,
                                  using: NWParameters(tls: tls, tcp: tcp))
    }
    func open() async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if let failure { continuation.resume(throwing: failure); return }
                openWaiter = continuation
                connection.stateUpdateHandler = { [weak self] state in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        switch state {
                        case .ready:
                            guard self.failure == nil, self.peerCertificate != nil else { return }
                            self.ready = true; self.openTimer?.cancel()
                            ConnectionLog.event("TLS_HANDSHAKE_SUCCESS", "port=\(self.port)")
                            self.onTLS("TLS \(self.port) completed; authentication pending")
                            self.openWaiter?.resume(); self.openWaiter = nil
                            self.receive()
                        case .failed(let error):
                            if self.connection.currentPath?.unsatisfiedReason == .localNetworkDenied { self.fail(ATVError.accessDenied) }
                            else if case .tls(let status) = error,
                                    ![errSSLClosedGraceful, errSSLClosedAbort, errSSLClosedNoNotify].contains(status) {
                                self.fail(ATVError.tlsRejected("TLS peer rejected the session (\(status)). Check the selected box and restart pairing if authorization was removed."))
                            } else { self.fail(ATVError.network("Connection \(self.port): \(error.localizedDescription). Check the PLAYBOX and Wi-Fi.")) }
                        case .waiting(let error):
                            if self.connection.currentPath?.unsatisfiedReason == .localNetworkDenied {
                                self.fail(ATVError.accessDenied)
                            } else if case .posix(let code) = error, code == .ECONNREFUSED {
                                self.fail(ATVError.network("TCP \(self.port) refused the TLS connection. Check the PLAYBOX IP, power and Android TV Remote Service."))
                            } else if case .dns(let code) = error, code == -65570 { self.fail(ATVError.accessDenied) }
                        case .cancelled: self.fail(CancellationError())
                        default: break
                        }
                    }
                }
                openTimer = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(8)) } catch { return }
                    self?.fail(ATVError.network("TLS handshake timed out. Check the remote service and same LAN."))
                }
                connection.start(queue: .main)
            }
        } onCancel: { Task { @MainActor [weak self] in self?.close() } }
    }
    func send(_ message: Data) async throws {
        guard ready, failure == nil else { throw failure ?? RemoteError.disconnected }
        try Task.checkCancellation()
        // A stalled write closes the channel so the contentProcessed callback also completes.
        let timer = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            self?.fail(ATVError.network("Command transmission timed out. Reconnecting to the PLAYBOX may be necessary."))
        }
        defer { timer.cancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.send(content: ProtoFrames.encode(message), completion: .contentProcessed { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                })
            }
            if let failure { throw failure }
        } onCancel: { Task { @MainActor [weak self] in self?.close() } }
    }
    func next(timeout: Duration? = .seconds(10)) async throws -> Data {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            if let failure { throw failure }
            if !messages.isEmpty { return messages.removeFirst() }
            guard readWaiter == nil else { throw ATVError.message("Internal error: concurrent protocol readers.") }
            return try await withCheckedThrowingContinuation { continuation in
                readWaiter = continuation
                if let timeout {
                    readTimer = Task { [weak self] in
                        do { try await Task.sleep(for: timeout) } catch { return }
                        self?.fail(ATVError.responseTimeout)
                    }
                }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.close() } }
    }
    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            Task { @MainActor [weak self] in
                guard let self, self.failure == nil else { return }
                do {
                    if let data {
                        self.messages.append(contentsOf: try self.frames.append(data))
                        guard self.messages.count <= 128 else { throw ATVError.message("Protocol queue exceeded limit.") }
                        if let waiter = self.readWaiter, !self.messages.isEmpty {
                            self.readWaiter = nil; self.readTimer?.cancel()
                            waiter.resume(returning: self.messages.removeFirst())
                        }
                    }
                    if let error { throw error }
                    if complete { throw ATVError.network("Remote service closed the connection. Check the PLAYBOX; restart pairing if authorization was removed.") }
                    self.receive()
                } catch { self.fail(error) }
            }
        }
    }
    private func fail(_ error: Error) {
        guard failure == nil else { return }
        failure = error; ready = false
        if openWaiter != nil {
            ConnectionLog.event("TLS_HANDSHAKE_FAILED", "port=\(port)")
            onTLS(error.localizedDescription)
        }
        openTimer?.cancel(); readTimer?.cancel()
        openWaiter?.resume(throwing: error); openWaiter = nil
        readWaiter?.resume(throwing: error); readWaiter = nil
        connection.stateUpdateHandler = nil; connection.cancel()
    }
    func close() { fail(CancellationError()) }
}
