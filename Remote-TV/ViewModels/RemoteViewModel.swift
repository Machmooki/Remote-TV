import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class RemoteViewModel {
    let discovery = DeviceDiscoveryService()
    private let service: RemoteControlService
    let connection: ConnectionManager
    private let diagnostics: ConnectionDiagnostics
    private let defaults: UserDefaults
    private var restoredConnection = false
    private var diagnosticTask: Task<Void, Never>?
    private let navigationQueue = TouchpadCommandQueue()
    private(set) var selectedDevice: TVDevice?
    private(set) var savedDevices: [TVDevice] = []
    private(set) var report: DiagnosticReport?
    private(set) var isChecking = false
    private(set) var feedback = "Ready when you are"
    var errorMessage: String?
    var activeSheet: RemoteSheet?
    var touchpadSensitivity: Double {
        didSet { defaults.set(touchpadSensitivity, forKey: "touchpadSensitivity") }
    }
    var haptics: Bool {
        didSet { defaults.set(haptics, forKey: "haptics") }
    }
    var automaticConnection: Bool {
        didSet {
            defaults.set(automaticConnection, forKey: "automaticConnection")
            connection.automaticReconnect = automaticConnection
            if automaticConnection {
                defaults.set(false, forKey: "autoConnectPaused")
                restoredConnection = false
                resume()
            }
        }
    }
    var appearance: String {
        didSet { defaults.set(appearance, forKey: "appearance") }
    }
    var isConnected: Bool { connection.connected }
    var status: String { isChecking ? "Checking TCP reachability…" : connection.state }

    init(service: RemoteControlService = RemoteControlService(), diagnostics: ConnectionDiagnostics = ConnectionDiagnostics(), defaults: UserDefaults = .standard, connectionManager: ConnectionManager? = nil) {
        self.service = service
        self.connection = connectionManager ?? ConnectionManager(service: service)
        self.diagnostics = diagnostics
        self.defaults = defaults
        automaticConnection = defaults.object(forKey: "automaticConnection") as? Bool ?? true
        let storedSensitivity = defaults.object(forKey: "touchpadSensitivity") as? Double ?? 36
        touchpadSensitivity = min(60, max(20, storedSensitivity))
        haptics = defaults.object(forKey: "haptics") as? Bool ?? true
        appearance = defaults.string(forKey: "appearance") ?? "system"
        if let data = defaults.data(forKey: "savedDevices"), let devices = try? JSONDecoder().decode([TVDevice].self, from: data) {
            savedDevices = devices.filter { !$0.isLegacyDemo }
        }
        connection.automaticReconnect = automaticConnection
        connection.onConnected = { [weak self] device in
            guard let self else { return }
            if let data = try? JSONEncoder().encode(device) { self.defaults.set(data, forKey: "lastConnectedDevice") }
        }
    }
    var displayFeedback: String {
        guard selectedDevice != nil else { return feedback }
        if isConnected && feedback.hasSuffix("transmitted") { return feedback }
        return isChecking ? "Checking selected device" : connection.state
    }
    var networkAccessStatus: String {
        if report?.ports.contains(where: { $0.detail.contains("access denied") }) == true { return "Local Network access denied or restricted" }
        if report?.ports.contains(where: { $0.outcome == .open }) == true { return "Local TCP access observed · authentication separate" }
        return discovery.networkStatus
    }
    func supports(_ app: TVAppShortcut) -> Bool { isConnected && service.supportedApps.contains(app) }
    var canNavigate: Bool { [.up, .down, .left, .right, .select].allSatisfy { supports($0) } }
    var canType: Bool { isConnected && service.supportsTextInput }
    var navigationSessionID: UUID { service.sessionID }
    func cancelNavigation() { navigationQueue.cancel() }
    func navigate(_ command: RemoteCommand) {
        guard canNavigate else { return }
        let session = service.sessionID
        navigationQueue.enqueue(command) { [weak self] command in
            guard !Task.isCancelled, let self, self.canNavigate, self.service.sessionID == session else { return false }
            return await self.transmit(command, session: session)
        }
    }
    func sendText(_ text: String, submit: Bool) async -> Bool {
        let session = service.sessionID
        do {
            try await service.sendText(text, submit: submit)
            guard !Task.isCancelled, service.sessionID == session, isConnected else { return false }
            feedback = "\(submit ? "Text and Enter" : "Text") transmitted"
            return true
        } catch is CancellationError { return false }
        catch {
            guard service.sessionID == session else { return false }
            connection.recordCommandFailure(error); errorMessage = error.localizedDescription
            return false
        }
    }
    func launch(_ app: TVAppShortcut) async {
        do {
            try await service.launch(app)
            if haptics { UIImpactFeedbackGenerator(style: .soft).impactOccurred() }
            feedback = "\(app.title) request transmitted"
        } catch { connection.recordCommandFailure(error); errorMessage = error.localizedDescription }
    }
    func supports(_ command: RemoteCommand) -> Bool { isConnected && service.supportedCommands.contains(command) }
    func inspect(_ device: TVDevice) {
        cancelNavigation()
        guard !device.isLegacyDemo else { return }
        restoredConnection = true
        diagnosticTask?.cancel()
        connection.cancel()
        service.replaceTransport(AndroidTVRemoteTransport())
        selectedDevice = device
        report = nil
        isChecking = true
        feedback = "Checking selected device"
        if !savedDevices.contains(where: { $0.id == device.id }) { savedDevices.append(device) }
        persistDevices()
        diagnosticTask = Task { [weak self, diagnostics] in
            let report = await diagnostics.run(for: device)
            guard !Task.isCancelled, let self else { return }
            self.report = report
            self.isChecking = false
            self.feedback = "Compatibility needs verification"
            self.diagnosticTask = nil
        }
    }
    func inspectManual(_ host: String) {
        do { inspect(try TVDevice.manual(host)) } catch { errorMessage = error.localizedDescription }
    }
    func cancelDiagnostics() {
        let wasChecking = isChecking
        diagnosticTask?.cancel()
        diagnosticTask = nil
        isChecking = false
        if wasChecking { feedback = "Check cancelled" }
    }
    func disconnect() {
        cancelDiagnostics()
        stopConnection()
        service.disconnect()
        selectedDevice = nil
        report = nil
        feedback = "Ready when you are"
    }
    func send(_ command: RemoteCommand) async {
        _ = await transmit(command, session: service.sessionID)
    }
    private func transmit(_ command: RemoteCommand, session: UUID) async -> Bool {
        do {
            try await service.send(command)
            guard !Task.isCancelled, service.sessionID == session, isConnected else { return false }
            if haptics { UIImpactFeedbackGenerator(style: .soft).impactOccurred() }
            feedback = "\(command.label) transmitted"
            return true
        } catch is CancellationError { return false }
        catch {
            guard service.sessionID == session else { return false }
            connection.recordCommandFailure(error); errorMessage = error.localizedDescription
            return false
        }
    }
    func connectSelected(pairAgain: Bool = false) {
        guard let selectedDevice, !selectedDevice.isLegacyDemo else { return }
        cancelDiagnostics()
        restoredConnection = true
        defaults.set(false, forKey: "autoConnectPaused")
        connection.connect(selectedDevice, pairAgain: pairAgain)
    }
    func stopConnection() {
        cancelNavigation()
        restoredConnection = true
        defaults.set(true, forKey: "autoConnectPaused")
        connection.cancel()
    }
    func suspend() { cancelNavigation(); discovery.stop(); cancelDiagnostics(); connection.suspend() }
    func resume() {
        connection.resume()
        guard automaticConnection, !restoredConnection else { return }
        restoredConnection = true
        guard !defaults.bool(forKey: "autoConnectPaused"), selectedDevice == nil else { return }
        let last = defaults.data(forKey: "lastConnectedDevice").flatMap { try? JSONDecoder().decode(TVDevice.self, from: $0) }
        // Migrate existing successful pairings: older versions saved peers but no last-device record.
        let candidate = last.flatMap { connection.hasPairing(for: $0) ? $0 : nil }
            ?? savedDevices.first(where: { connection.hasPairing(for: $0) })
        guard let candidate, !candidate.isLegacyDemo else { return }
        selectedDevice = candidate
        feedback = "Connecting to saved PLAYBOX"
        connection.connectKnown(candidate)
    }
    func rename(_ device: TVDevice, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = savedDevices.firstIndex(where: { $0.id == device.id }) else { return }
        savedDevices[index].name = String(name.prefix(60))
        if selectedDevice?.id == device.id { selectedDevice?.name = savedDevices[index].name }
        persistDevices()
    }
    func forget(_ device: TVDevice) {
        do { try SecureCredentialStore().delete(for: device.id) }
        catch { errorMessage = error.localizedDescription; return }
        savedDevices.removeAll { $0.id == device.id }
        if let data = defaults.data(forKey: "lastConnectedDevice"),
           let last = try? JSONDecoder().decode(TVDevice.self, from: data), last.id == device.id {
            defaults.removeObject(forKey: "lastConnectedDevice")
        }
        if selectedDevice?.id == device.id { disconnect() }
        persistDevices()
    }
    private func persistDevices() {
        if let data = try? JSONEncoder().encode(savedDevices) { defaults.set(data, forKey: "savedDevices") }
    }
    static func preview() -> RemoteViewModel {
        RemoteViewModel(defaults: UserDefaults(suiteName: "Remote-TV.preview")!)
    }
}
