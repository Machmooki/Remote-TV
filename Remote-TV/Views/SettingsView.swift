import SwiftUI

struct SettingsView: View {
    @Bindable var model: RemoteViewModel
    var body: some View {
        Form {
            Section("Make it yours") {
                Picker("Appearance", selection: $model.appearance) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                Toggle("Button haptics", isOn: $model.haptics)
            }
            Section("Touchpad") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Swipe distance")
                    Slider(value: $model.touchpadSensitivity, in: 20...60, step: 2)
                        .accessibilityLabel("Swipe distance")
                    HStack { Text("Short"); Spacer(); Text("Long") }.font(.caption).foregroundStyle(.secondary)
                }
                Text("Swipe to move between items. Tap to select; hold still to open the TV menu. Touch and hold Play for more media controls.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Connection") {
                Toggle("Auto connect & reconnect", isOn: $model.automaticConnection)
                    .accessibilityIdentifier("automaticConnection")
                Text("Reconnect to your paired PLAYBOX when the app opens or the connection drops. Disconnect pauses automatic connections until you connect again.")
                    .font(.footnote).foregroundStyle(.secondary)
                LabeledContent("Transport", value: model.connection.state)
                LabeledContent("Android TV Remote v2", value: model.connection.pairingState)
                LabeledContent("Bluetooth", value: "Unverified")
                if model.selectedDevice != nil {
                    Button("Disconnect / clear selection", role: .destructive) { model.disconnect() }
                }
            }
            Section("Your PLAYBOX") {
                LabeledContent("Manufacturer", value: "ZTE")
                LabeledContent("Hardware", value: "STBAZA-A")
                LabeledContent("Firmware", value: "V8754920")
                Text("These identifiers do not confirm an Android TV remote protocol or iOS Bluetooth compatibility.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("About") {
                LabeledContent("Remote TV", value: "1.0")
                Text("Designed for a quieter kind of control.").foregroundStyle(.secondary)
                Text("Power and volume support depend on the box and HDMI-CEC configuration. Panasonic TV control has not been verified.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }.navigationTitle("Settings")
    }
}
