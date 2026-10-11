import SwiftUI

enum RemoteStyle {
    static let accent = Color("AccentColor")
    static let background = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.055, alpha: 1) : UIColor(red: 0.965, green: 0.97, blue: 0.965, alpha: 1) })
    static let surface = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.105, alpha: 1) : .white })
    static let touchpad = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.13, alpha: 1) : UIColor(red: 0.925, green: 0.945, blue: 0.935, alpha: 1) })
}

struct RemoteView: View {
    @Bindable var model: RemoteViewModel
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 18) {
                    header.modifier(RemoteReveal(visible: appeared, delay: 0))
                    shortcuts.modifier(RemoteReveal(visible: appeared, delay: 0.04))
                    VStack(spacing: 12) {
                        TouchpadView(model: model)
                            .frame(height: verticalSizeClass == .compact ? 190 : min(320, max(190, geometry.size.height * 0.29)))
                        HStack {
                            Text("SWIPE · TAP · HOLD").font(.system(size: 9, weight: .semibold)).tracking(2).foregroundStyle(.tertiary)
                            Spacer()
                            Button { model.cancelNavigation(); model.activeSheet = .keyboard } label: {
                                Label("Keyboard", systemImage: "keyboard").font(.caption.weight(.medium))
                                    .padding(.horizontal, 14).frame(minHeight: 44)
                                    .background(RemoteStyle.surface, in: Capsule())
                            }.buttonStyle(RemotePressStyle()).accessibilityIdentifier("openKeyboard")
                        }
                    }
                    .modifier(RemoteReveal(visible: appeared, delay: 0.08))
                    controls.modifier(RemoteReveal(visible: appeared, delay: 0.12))
                    connectionFooter.modifier(RemoteReveal(visible: appeared, delay: 0.16))
                }
                .frame(maxWidth: 560)
                .padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 24)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .center)
            }.scrollIndicators(.hidden)
        }
        .background(RemoteStyle.background)
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { appeared = true }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: model.isConnected)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Button { model.activeSheet = .settings } label: {
                Image(systemName: "gearshape").font(.system(size: 21, weight: .regular)).frame(width: 44, height: 44)
            }.buttonStyle(RemotePressStyle()).foregroundStyle(.secondary)
                .background(RemoteStyle.surface, in: Circle()).accessibilityLabel("Settings").accessibilityIdentifier("openSettings")
            Spacer(minLength: 0)
            Button { model.activeSheet = .devices } label: {
                VStack(spacing: 6) {
                    HStack(spacing: 8) {
                        Circle().fill(model.isConnected ? Color.green : Color.secondary.opacity(0.4)).frame(width: 7, height: 7)
                        Text(model.selectedDevice?.name ?? "My PLAYBOX").font(.system(size: 20, weight: .semibold, design: .rounded)).lineLimit(1)
                        Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                    }
                    Text(model.isConnected ? "Connected" : model.status)
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                        .contentTransition(.opacity)
                }
            }.buttonStyle(RemotePressStyle()).accessibilityLabel("Choose device").accessibilityIdentifier("chooseDevice")
            Spacer(minLength: 0)
            Button { Task { await model.send(.power) } } label: {
                Image(systemName: "power").font(.system(size: 22, weight: .medium)).frame(width: 44, height: 44)
            }.buttonStyle(RemotePressStyle())
                .background(Color.red.opacity(0.055), in: Circle())
                .foregroundStyle(model.supports(.power) ? Color.red : Color.secondary.opacity(0.35))
                .disabled(!model.supports(.power)).accessibilityLabel("Power")
                .accessibilityIdentifier("key_power")
        }.padding(.bottom, 2)
    }

    private var shortcuts: some View {
        HStack(spacing: 12) {
            ForEach(TVAppShortcut.allCases) { app in
                Button { Task { await model.launch(app) } } label: {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 11).fill(app == .netflix ? Color.black : Color.red)
                            if app == .netflix {
                                Text("N").font(.system(size: 26, weight: .black, design: .rounded)).foregroundStyle(.red)
                            } else {
                                Image(systemName: "play.fill").font(.system(size: 15)).foregroundStyle(.white)
                            }
                        }.frame(width: 40, height: 40)
                        Text(app.title).font(.subheadline.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
                        Spacer(minLength: 0)
                    }.padding(14).frame(maxWidth: .infinity)
                        .background(RemoteStyle.surface, in: RoundedRectangle(cornerRadius: 21))
                        .overlay(RoundedRectangle(cornerRadius: 21).strokeBorder(.primary.opacity(0.035), lineWidth: 1))
                        .opacity(model.supports(app) ? 1 : 0.48)
                }.buttonStyle(RemotePressStyle()).disabled(!model.supports(app))
                    .accessibilityLabel("Open \(app.title)").accessibilityIdentifier("shortcut_\(app.rawValue)")
            }
        }.frame(maxWidth: .infinity)
    }

    private var controls: some View {
        HStack(spacing: 14) {
            rocker(title: "VOL", up: .volumeUp, down: .volumeDown, upIcon: "plus", downIcon: "minus")
            VStack(spacing: 18) {
                HStack(spacing: 12) {
                    key(.home, icon: "house")
                    key(.select, icon: "checkmark", title: "OK")
                    key(.menu, icon: "line.3.horizontal")
                }
                HStack(spacing: 12) {
                    key(.mute, icon: "speaker.slash")
                    key(.playPause, icon: "playpause")
                        .contextMenu {
                            Button("Rewind", systemImage: "backward") { Task { await model.send(.rewind) } }.disabled(!model.supports(.rewind))
                            Button("Fast forward", systemImage: "forward") { Task { await model.send(.fastForward) } }.disabled(!model.supports(.fastForward))
                        }
                        .accessibilityHint("Touch and hold for rewind and fast forward")
                    key(.back, icon: "arrow.uturn.backward")
                }
            }.frame(maxWidth: .infinity)
            rocker(title: "CH", up: .channelUp, down: .channelDown, upIcon: "chevron.up", downIcon: "chevron.down")
        }
    }

    private func key(_ command: RemoteCommand, icon: String, title: String? = nil) -> some View {
        RemoteKey(model: model, command: command, icon: icon, title: title)
            .frame(maxWidth: .infinity)
    }

    private func rocker(title: String, up: RemoteCommand, down: RemoteCommand, upIcon: String, downIcon: String) -> some View {
        VStack(spacing: 4) {
            RemoteKey(model: model, command: up, icon: upIcon, size: 44, filled: false)
            VStack(spacing: 4) {
                Text(title).font(.system(size: 10, weight: .medium)).tracking(1)
            }.foregroundStyle(.secondary).frame(maxHeight: .infinity)
            RemoteKey(model: model, command: down, icon: downIcon, size: 44, filled: false)
        }.padding(.vertical, 8).frame(width: 56, height: 164)
            .background(RemoteStyle.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(.primary.opacity(0.035), lineWidth: 1))
    }

    private var connectionFooter: some View {
        VStack(spacing: 10) {
            Text(model.displayFeedback).font(.caption).foregroundStyle(.secondary)
                .contentTransition(.opacity)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: model.displayFeedback)
                .accessibilityIdentifier("remoteFeedback")
            Button { model.activeSheet = .devices } label: {
                Label(model.selectedDevice == nil ? "Connect your TV" : "Connection details", systemImage: model.isConnected ? "link" : "wifi")
                    .font(.caption.weight(.medium)).frame(minHeight: 44)
            }.buttonStyle(RemotePressStyle()).accessibilityIdentifier("findDevice")
        }.frame(minHeight: 68)
    }

}

struct RemoteKey: View {
    let model: RemoteViewModel
    let command: RemoteCommand
    let icon: String
    var title: String? = nil
    var size: CGFloat = 52
    var filled = true

    var body: some View {
        Button { Task { await model.send(command) } } label: {
            Group {
                if let title { Text(title).font(.system(size: 13, weight: .semibold)) }
                else { Image(systemName: icon).font(.system(size: 19, weight: .regular)) }
            }
            .frame(width: size, height: size)
            .foregroundStyle(model.supports(command) ? Color.primary : Color.secondary.opacity(0.45))
            .background(filled ? (command == .select ? RemoteStyle.accent.opacity(0.12) : RemoteStyle.surface) : Color.clear, in: Circle())
            .overlay(Circle().strokeBorder(.primary.opacity(filled ? 0.035 : 0), lineWidth: 1))
            .contentShape(Circle())
        }.buttonStyle(RemotePressStyle()).disabled(!model.supports(command))
            .accessibilityLabel(command.label).accessibilityIdentifier("key_\(command.rawValue)")
    }
}

struct RemotePressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.72), value: configuration.isPressed)
    }
}

#Preview("Touchpad · Light") {
    @Previewable @State var model = RemoteViewModel.preview()
    NavigationStack { RemoteView(model: model) }.tint(RemoteStyle.accent)
}
#Preview("Touchpad · Dark") {
    @Previewable @State var model = RemoteViewModel.preview()
    NavigationStack { RemoteView(model: model) }.tint(RemoteStyle.accent).preferredColorScheme(.dark)
}

private struct RemoteReveal: ViewModifier {
    let visible: Bool
    let delay: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content.opacity(visible ? 1 : 0)
            .offset(y: visible || reduceMotion ? 0 : 8)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.4).delay(delay), value: visible)
    }
}
