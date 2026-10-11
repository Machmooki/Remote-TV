import Foundation
import Observation
import Darwin
import Network

@MainActor
@Observable
final class DeviceDiscoveryService: NSObject, @preconcurrency NetServiceDelegate {
    static let serviceType = "_androidtvremote2._tcp"
    private(set) var devices: [TVDevice] = []
    private(set) var isSearching = false
    private(set) var message = "Find your PLAYBOX on the same Wi-Fi network."
    private(set) var networkStatus = "Not checked · start discovery or a connection"
    private var browser: NWBrowser?
    private var scanID = UUID()
    private var services: [String: NetService] = [:]
    private var searchTask: Task<Void, Never>?

    func search() {
        stop()
        devices = []
        message = "Looking for Android TV remote services…"
        isSearching = true
        scanID = UUID()
        let scanID = self.scanID
        let browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: "local."), using: .tcp)
        self.browser = browser
        ConnectionLog.event("DISCOVERY_STARTED", Self.serviceType)
        networkStatus = "Requesting local network discovery"
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self, self.scanID == scanID else { return }
                switch state {
                case .ready:
                    self.networkStatus = "Browser ready · no permission denial reported"
                case .waiting(let error), .failed(let error):
                    if case .dns(let code) = error, code == -65570 {
                        self.networkStatus = "Local Network access denied or restricted"
                        self.message = "Enable Local Network in Settings → Privacy & Security → Local Network → Remote TV, then search again."
                    } else {
                        self.networkStatus = "Discovery unavailable: \(error.localizedDescription)"
                        self.message = "Check Wi-Fi and local network settings, or enter the box IP manually."
                    }
                default: break
                }
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor [weak self] in
                guard let self, self.scanID == scanID else { return }
                self.process(results)
            }
        }
        browser.start(queue: .main)
        searchTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(12)) } catch { return }
            guard let self else { return }
            self.message = self.devices.isEmpty
                ? "No services yet. Scanning continues; check Local Network access and Wi-Fi, or enter the box IP address."
                : "Services found. Scanning continues until you stop or close this screen."
        }
    }
    func stop() {
        searchTask?.cancel()
        searchTask = nil
        scanID = UUID()
        browser?.stateUpdateHandler = nil
        browser?.browseResultsChangedHandler = nil
        browser?.cancel()
        browser = nil
        for service in services.values { service.stop(); service.delegate = nil }
        services = [:]
        isSearching = false
    }
    private func key(_ service: NetService) -> String { "\(service.domain)|\(service.type)|\(service.name)" }
    private func process(_ results: Set<NWBrowser.Result>) {
        var found = Set<String>()
        for result in results {
            guard case let .service(name, type, domain, _) = result.endpoint else { continue }
            // NetService resolves SRV + A/AAAA records without requiring the TCP port to be open.
            let service = NetService(domain: domain, type: type, name: name)
            let id = key(service); found.insert(id)
            guard services[id] == nil else { continue }
            services[id] = service
            service.delegate = self
            service.resolve(withTimeout: 5)
            ConnectionLog.event("DEVICE_FOUND")
        }
        for id in Array(services.keys) where !found.contains(id) {
            services[id]?.stop(); services[id]?.delegate = nil; services[id] = nil
            devices.removeAll { $0.id == id }
        }
    }
    func netServiceDidResolveAddress(_ sender: NetService) {
        let id = key(sender)
        guard services[id] === sender else { return }
        let addresses = (sender.addresses ?? []).compactMap(Self.numericAddress)
        guard let host = sender.hostName, !addresses.isEmpty else {
            message = "Service found, but its address could not be resolved. Try manual IP entry."
            return
        }
        let device = TVDevice(id: id, name: sender.name, host: host,
                              addresses: Array(Set(addresses)).sorted(), advertisedService: Self.serviceType)
        devices.removeAll { $0.id == id }
        devices.append(device)
        devices.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        networkStatus = "Bonjour result resolved · local network access observed"
        ConnectionLog.event("DEVICE_RESOLVED")
        message = "Found \(devices.count) service(s). Compatibility is not yet verified."
    }
    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        guard services[key(sender)] === sender else { return }
        message = "Could not resolve \(sender.name). Try its IP address or search again."
    }
    private static func numericAddress(_ data: Data) -> String? {
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress, buffer.count >= MemoryLayout<sockaddr>.size else { return nil }
            let address = base.assumingMemoryBound(to: sockaddr.self)
            guard address.pointee.sa_family == AF_INET || address.pointee.sa_family == AF_INET6 else { return nil }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(buffer.count), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
            return String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
    }
}
