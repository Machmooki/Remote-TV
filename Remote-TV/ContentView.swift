import SwiftUI

struct ContentView: View {
    @State private var model = RemoteViewModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack { RemoteView(model: model) }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { model.suspend() }
                else if phase == .active { model.resume() }
            }
            .task { if scenePhase == .active { model.resume() } }
            .tint(RemoteStyle.accent)
            .preferredColorScheme(model.appearance == "light" ? .light : model.appearance == "dark" ? .dark : nil)
            .sheet(item: $model.activeSheet) { destination in
                NavigationStack {
                    Group {
                        switch destination {
                        case .devices: DevicesView(model: model)
                        case .settings: SettingsView(model: model)
                        case .keyboard: KeyboardView(model: model)
                        }
                    }
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { model.activeSheet = nil }.accessibilityIdentifier("dismissSheet")
                        }
                    }
                }
                .modifier(RemoteErrorAlert(model: model))
            }
            .modifier(RemoteErrorAlert(model: model, active: model.activeSheet == nil))
    }
}

private struct RemoteErrorAlert: ViewModifier {
    @Bindable var model: RemoteViewModel
    var active = true
    func body(content: Content) -> some View {
        content.alert("Unable to continue", isPresented: Binding(
            get: { active && model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }
}

#Preview { ContentView() }
