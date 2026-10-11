import SwiftUI

struct KeyboardView: View {
    let model: RemoteViewModel
    @State private var text = ""
    @State private var sending = false
    @State private var transmission: Task<Void, Never>?
    @State private var notice: String?
    @FocusState private var focused: Bool

    private var canSend: Bool { model.canType && !sending && (1...2048).contains(text.unicodeScalars.count) }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Open a search or text field on your TV, then type here.")
                .font(.subheadline).foregroundStyle(.secondary)
            TextField("Type on your TV", text: $text)
                .textFieldStyle(.plain).padding(16)
                .background(RemoteStyle.surface, in: RoundedRectangle(cornerRadius: 16))
                .focused($focused).submitLabel(.search)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .disabled(!model.canType || sending).privacySensitive()
                .accessibilityIdentifier("tvKeyboardInput")
                .onSubmit { transmit(submit: true) }
            HStack(spacing: 12) {
                Button { transmit(submit: false) } label: {
                    Label("Send text", systemImage: "paperplane").frame(maxWidth: .infinity, minHeight: 34)
                }.buttonStyle(.bordered).disabled(!canSend).accessibilityIdentifier("sendTVText")
                Button { transmit(submit: true) } label: {
                    Label("Search", systemImage: "magnifyingglass").frame(maxWidth: .infinity, minHeight: 34)
                }.buttonStyle(.borderedProminent).disabled(!canSend).accessibilityIdentifier("searchTVText")
            }
            if sending { ProgressView("Transmitting…") }
            if let notice { Text(notice).font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("keyboardNotice") }
            if !model.isConnected {
                Text("Connect your PLAYBOX to use phone typing.").font(.footnote).foregroundStyle(.secondary)
            } else if !model.canType {
                Text(RemoteError.unsupportedText.localizedDescription).font(.footnote).foregroundStyle(.secondary)
            } else {
                Text("Send text inserts your draft into the focused TV field. Search also sends Enter. Check the TV for the result; some apps use their own keyboard.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if text.unicodeScalars.count > 2048 {
                Text("Please shorten the text to 2,048 characters.").font(.footnote).foregroundStyle(.red)
            }
            Spacer(minLength: 0)
        }
        .padding(24).background(RemoteStyle.background).navigationTitle("TV keyboard")
        .task { focused = model.canType }
        .onChange(of: model.isConnected) { _, _ in cancelTransmission() }
        .onChange(of: model.navigationSessionID) { _, _ in cancelTransmission() }
        .onDisappear { cancelTransmission(); text = "" }
    }

    private func transmit(submit: Bool) {
        guard canSend else { return }
        let draft = text
        sending = true; notice = nil
        transmission = Task { @MainActor in
            let sent = await model.sendText(draft, submit: submit)
            guard !Task.isCancelled else { return }
            sending = false; transmission = nil
            if sent {
                text = ""
                notice = "\(submit ? "Text and Enter" : "Text") transmitted. Check your TV."
            }
        }
    }
    private func cancelTransmission() {
        transmission?.cancel(); transmission = nil; sending = false; notice = nil
    }
}
