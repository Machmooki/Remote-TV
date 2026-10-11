import SwiftUI

struct DevicesView: View {
    @Bindable var model: RemoteViewModel
    @State private var manualIP = ""
    @State private var pairingCode = ""
    @FocusState private var isIPFocused: Bool
    @State private var renaming: TVDevice?
    @State private var deviceName = ""
    @Environment(\.openURL) private var openURL

    var body: some View {
        List {
            Section {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "wifi").font(.title2).foregroundStyle(RemoteStyle.accent)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Find your TV").font(.headline)
                        Text("Keep your PLAYBOX and this device on the same Wi-Fi network.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 8)
                Button { model.discovery.search() } label: {
                    HStack {
                        Label(model.discovery.isSearching ? "Search again" : "Search for devices", systemImage: "magnifyingglass")
                        Spacer()
                        if model.discovery.isSearching { ProgressView() }
                    }
                }.accessibilityIdentifier("searchDevices")
                if model.discovery.isSearching {
                    Button("Stop search", role: .cancel) { model.discovery.stop() }
                }
                LabeledContent("Network access", value: model.networkAccessStatus).font(.caption)
                Text("Service: \(DeviceDiscoveryService.serviceType)").font(.caption.monospaced())
                Text(model.discovery.message).font(.footnote).foregroundStyle(.secondary)
            } header: { Text("Nearby devices") }

            if !model.discovery.devices.isEmpty {
                Section("Discovered services") {
                    ForEach(model.discovery.devices) { device in deviceRow(device) }
                }
            }
            Section {
                TextField("e.g. 192.168.1.20", text: $manualIP)
                    .focused($isIPFocused)
                    .keyboardType(.numbersAndPunctuation).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityLabel("PLAYBOX IP address").accessibilityIdentifier("manualIP")
                    .onSubmit { checkManual() }
                Button("Check this address", systemImage: "network") { checkManual() }
                    .disabled(manualIP.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isChecking)
                    .accessibilityIdentifier("checkAddress")
            } header: { Text("Enter IP address") } footer: {
                Text("Find the IP in your PLAYBOX network settings. Only TCP ports 6466 and 6467 on this address are checked.")
            }
            if model.isChecking {
                Section("Diagnostics") {
                    HStack { ProgressView(); Text("Checking \(model.selectedDevice?.name ?? "device")…") }
                    Button("Cancel check", role: .cancel) { model.cancelDiagnostics() }
                }
            }
            if let report = model.report {
                Section("Connection diagnostics") {
                    DiagnosticsView(report: report, protocolStatus: model.connection.connected ? "Remote v2 session authenticated" : model.connection.awaitingCode ? "Pairing protocol verified" : "Compatibility unverified")
                    Button("Run checks again", systemImage: "arrow.clockwise") { model.inspect(report.device) }
                    ShareLink(item: report.text) { Label("Share diagnostics", systemImage: "square.and.arrow.up") }
                }
            }
            if let device = model.selectedDevice, !device.isLegacyDemo {
                Section("Secure connection") {
                    LabeledContent("Session", value: model.connection.state)
                    LabeledContent("TLS handshake", value: model.connection.tlsResult)
                    LabeledContent("Pairing", value: model.connection.pairingState)
                    LabeledContent("Auto reconnect", value: model.automaticConnection ? "Enabled" : "Off")
                    Text(model.connection.sessionActivity).font(.caption).foregroundStyle(.secondary)
                    if model.connection.busy { ProgressView("Waiting for remote service…") }
                    if model.connection.awaitingCode {
                        SecureField("Six-character TV code", text: $pairingCode)
                            .textInputAutocapitalization(.characters).autocorrectionDisabled()
                            .accessibilityIdentifier("pairingCode")
                        Button("Verify code and connect") {
                            let code = pairingCode; pairingCode = ""
                            model.connection.submit(code: code)
                        }.disabled(model.connection.busy || pairingCode.isEmpty)
                        Text("Use the code currently displayed on the TV, not its MAC address.").font(.caption)
                    }
                    Button("Connect to \(device.name)", systemImage: "link") { model.connectSelected() }
                        .disabled(model.connection.busy || model.connection.awaitingCode || model.isConnected)
                        .accessibilityIdentifier("connectDevice")
                    Button("Restart pairing") { pairingCode = ""; model.connectSelected(pairAgain: true) }
                        .disabled(model.connection.busy)
                    Button("Disconnect / cancel", role: .cancel) { model.stopConnection() }
                    if model.connection.protocolError != "None" {
                        Text(model.connection.protocolError).font(.footnote).foregroundStyle(.red).textSelection(.enabled)
                    }
                    LabeledContent("Command transmission error", value: model.connection.commandError).font(.caption)
                    Text("Connected requires a paired TLS peer and completed remote protocol negotiation. Transmitted commands have no per-key acknowledgement; check the TV for the actual result.").font(.caption).foregroundStyle(.secondary)
                    ShareLink(item: (model.report?.text ?? "Host: \(device.host)") + "\nNetwork: \(model.networkAccessStatus)\n" + model.connection.diagnosticText) {
                        Label("Share connection diagnostics", systemImage: "square.and.arrow.up")
                    }
                }
            }
            if !model.savedDevices.isEmpty {
                Section("Saved devices") {
                    ForEach(model.savedDevices) { device in
                        deviceRow(device)
                            .swipeActions {
                                Button("Forget", role: .destructive) { model.forget(device) }
                                Button("Rename") { deviceName = device.name; renaming = device }.tint(RemoteStyle.accent)
                            }
                            .contextMenu {
                                Button("Rename", systemImage: "pencil") { deviceName = device.name; renaming = device }
                                Button("Forget device", systemImage: "trash", role: .destructive) { model.forget(device) }
                            }
                    }
                }
            }
            Section {
                Label("Android TV Remote v2", systemImage: "shield.lefthalf.filled")
                    .font(.subheadline)
                Text("Select a device, then Connect. A compatible service will display a pairing code on the TV. Bluetooth control remains unverified.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("Open system settings", systemImage: "gearshape") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            } footer: { Text("ZTE · STBAZA-A · Firmware V8754920\nHardware details supplied by you; model compatibility not inferred.") }
        }
        .navigationTitle("Devices")
        .scrollDismissesKeyboard(.interactively)
        .onDisappear { model.discovery.stop() }
        .alert("Rename device", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Device name", text: $deviceName)
            Button("Save") { if let device = renaming { model.rename(device, to: deviceName) }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }
    private func checkManual() {
        isIPFocused = false
        model.inspectManual(manualIP)
    }
    private func deviceRow(_ device: TVDevice) -> some View {
        Button { model.inspect(device) } label: {
            HStack(spacing: 12) {
                Image(systemName: "tv").font(.title2).foregroundStyle(RemoteStyle.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text(device.name).font(.headline).foregroundStyle(.primary)
                    Text(device.addresses.first ?? device.host).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "stethoscope").foregroundStyle(.secondary)
            }.padding(.vertical, 6)
        }.accessibilityLabel("Check \(device.name), \(device.host)")
    }
}

struct DiagnosticsView: View {
    let report: DiagnosticReport
    let protocolStatus: String
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(report.device.name, systemImage: "tv").font(.headline)
            Text(report.device.host).font(.caption.monospaced()).textSelection(.enabled)
            ForEach(report.ports) { port in
                HStack(alignment: .top) {
                    Image(systemName: port.outcome == .open ? "checkmark.circle" : "exclamationmark.circle")
                        .foregroundStyle(port.outcome == .open ? RemoteStyle.accent : Color.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("TCP \(String(port.port)) · \(port.outcome.rawValue)").font(.subheadline.weight(.medium))
                        Text(port.detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Divider()
            Text(protocolStatus).font(.subheadline.weight(.semibold))
            Text(report.summary).font(.footnote).foregroundStyle(.secondary)
            Text("Bonjour: \(report.device.advertisedService ?? "Manual IP; no service advertisement")")
                .font(.caption).foregroundStyle(.secondary)
            if !report.device.addresses.isEmpty {
                Text("Addresses: \(report.device.addresses.joined(separator: ", "))")
                    .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Text(report.date.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.tertiary)
        }.padding(.vertical, 6).accessibilityIdentifier("diagnosticsReport")
    }
}
