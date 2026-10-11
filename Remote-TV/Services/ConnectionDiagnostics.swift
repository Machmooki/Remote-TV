import Foundation
import Network

@MainActor
protocol PortChecking: Sendable {
    func check(host: String, port: UInt16) async -> PortDiagnostic
}

@MainActor
final class TCPPortChecker: PortChecking {
    private let timeout: Duration
    init(timeout: Duration = .seconds(4)) { self.timeout = timeout }

    func check(host: String, port: UInt16) async -> PortDiagnostic {
        let probe = TCPProbe(host: host, port: port, timeout: timeout)
        return await withTaskCancellationHandler {
            await probe.run()
        } onCancel: {
            Task { @MainActor in probe.cancel() }
        }
    }
}

@MainActor
private final class TCPProbe {
    let port: UInt16
    let connection: NWConnection
    let timeout: Duration
    var continuation: CheckedContinuation<PortDiagnostic, Never>?
    var timeoutTask: Task<Void, Never>?
    var completed = false
    var cancelled = false

    init(host: String, port: UInt16, timeout: Duration) {
        self.port = port
        self.timeout = timeout
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    }
    func run() async -> PortDiagnostic {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            guard !cancelled && !Task.isCancelled else { cancel(); return }
            connection.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    switch state {
                    case .ready: self.finish(.open, "TCP connection accepted; no protocol handshake attempted.")
                    case .failed(let error): self.finish(.unavailable, error.localizedDescription)
                    case .waiting(let error):
                        if self.connection.currentPath?.unsatisfiedReason == .localNetworkDenied {
                            self.finish(.unavailable, "Local Network access denied. Enable it in Settings → Privacy & Security → Local Network → Remote TV, then retry.")
                        } else if case .dns(let code) = error, code == -65570 {
                            self.finish(.unavailable, "Local Network access denied. Enable it in Settings → Privacy & Security → Local Network → Remote TV, then retry.")
                        } else if case .posix(let code) = error, code == .ECONNREFUSED {
                            self.finish(.unavailable, error.localizedDescription)
                        }
                    case .cancelled: self.finish(.cancelled, "Check cancelled.")
                    default: break
                    }
                }
            }
            timeoutTask = Task { [weak self, timeout] in
                do { try await Task.sleep(for: timeout) } catch { return }
                self?.finish(.timedOut, "No connection before the timeout. Check Local Network access, Wi-Fi, and device power.")
            }
            connection.start(queue: .main)
        }
    }
    func cancel() {
        cancelled = true
        finish(.cancelled, "Check cancelled.")
    }
    func finish(_ outcome: PortDiagnostic.Outcome, _ detail: String) {
        guard !completed, let continuation else { return }
        ConnectionLog.event(outcome == .open ? "TCP_CONNECT_SUCCESS" : "TCP_CONNECT_FAILED", "port=\(port) outcome=\(outcome.rawValue)")
        completed = true
        self.continuation = nil
        timeoutTask?.cancel()
        connection.stateUpdateHandler = nil
        connection.cancel()
        continuation.resume(returning: PortDiagnostic(port: port, outcome: outcome, detail: detail))
    }
}

@MainActor
final class ConnectionDiagnostics {
    private let checker: any PortChecking
    init(checker: any PortChecking = TCPPortChecker()) { self.checker = checker }
    func run(for device: TVDevice) async -> DiagnosticReport {
        // Only these two ports on the explicitly selected device. Never scan a subnet.
        async let control = checker.check(host: device.host, port: 6466)
        async let pairing = checker.check(host: device.host, port: 6467)
        return await DiagnosticReport(device: device, date: Date(), ports: [control, pairing])
    }
}
