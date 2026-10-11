`import SwiftUI

struct TouchpadView: View {
    let model: RemoteViewModel
    @GestureState private var isTouching = false
    @State private var interpreter = TouchpadInterpreter()
    @State private var finger: CGPoint?
    @State private var hover: CGPoint?
    @State private var gestureID = UUID()
    @State private var holdTask: Task<Void, Never>?
    @State private var holdProgress: CGFloat = 0
    @State private var held = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        GeometryReader { geometry in
            surface(size: geometry.size)
            .overlay(RoundedRectangle(cornerRadius: 30).strokeBorder(RemoteStyle.accent.opacity(finger == nil ? 0.08 : 0.3), lineWidth: 1))
            .shadow(color: .black.opacity(0.025), radius: 16, x: 0, y: 8)
            .scaleEffect(finger != nil && !reduceMotion ? 0.992 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85), value: finger != nil)
            .contentShape(RoundedRectangle(cornerRadius: 30))
            .highPriorityGesture(navigationGesture, including: model.canNavigate ? .all : .none)
            .onContinuousHover { phase in
                switch phase {
                case .active(let location): hover = model.canNavigate ? location : nil
                case .ended: hover = nil
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Touchpad")
            .accessibilityValue(model.canNavigate ? "Ready" : "Not connected")
            .accessibilityHint("Swipe to navigate. Tap to select. Hold still to open the TV menu.")
            .accessibilityIdentifier("touchpad")
            .accessibilityAction { if model.supports(.select) { send(.select) } }
            .accessibilityAction(named: "Up") { if model.supports(.up) { send(.up) } }
            .accessibilityAction(named: "Down") { if model.supports(.down) { send(.down) } }
            .accessibilityAction(named: "Left") { if model.supports(.left) { send(.left) } }
            .accessibilityAction(named: "Right") { if model.supports(.right) { send(.right) } }
            .accessibilityAction(named: "Open TV menu") { if model.supports(.longSelect) { send(.longSelect) } }
            .onChange(of: isTouching) { _, active in
                touchingChanged(active)
            }
            .onChange(of: model.isConnected) { _, _ in resetInteraction() }
            .onChange(of: model.navigationSessionID) { _, _ in resetInteraction() }
            .onChange(of: model.activeSheet) { _, _ in resetInteraction() }
            .onChange(of: scenePhase) { _, phase in if phase != .active { resetInteraction() } }
            .onDisappear { resetInteraction() }
        }
    }
    private var navigationGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($isTouching) { _, active, _ in active = true }
            .onChanged { value in
                guard model.canNavigate else { return }
                if finger == nil {
                    gestureID = UUID(); interpreter.reset(); model.cancelNavigation(); held = false
                    startHold()
                }
                interpreter.threshold = model.touchpadSensitivity
                finger = value.location
                if let command = interpreter.move(x: value.translation.width, y: value.translation.height) { send(command) }
                if !interpreter.canHold && !held { cancelHold() }
            }
            .onEnded { value in
                defer { cancelHold(); gestureID = UUID(); finger = nil; held = false; interpreter.reset() }
                guard model.canNavigate else { return }
                // Capture a final fast swipe even if no intermediate sample crossed the threshold.
                if let command = interpreter.move(x: value.translation.width, y: value.translation.height) { send(command) }
                if let command = interpreter.end() { send(command) }
            }
    }
    private func surface(size: CGSize) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 30).fill(LinearGradient(colors: [RemoteStyle.surface, RemoteStyle.touchpad], startPoint: .topLeading, endPoint: .bottomTrailing))
            dots.padding(24).allowsHitTesting(false)
            VStack(spacing: 12) {
                Image(systemName: "hand.draw").font(.system(size: 28, weight: .ultraLight))
                Text("Swipe to navigate").font(.subheadline.weight(.medium))
                Text("Tap to select · Hold for menu").font(.caption)
            }.foregroundStyle(.secondary).opacity(finger == nil && hover == nil ? 1 : 0)
                .allowsHitTesting(false)
            // Keep the indicator mounted so the hold ring can animate from zero.
            touchIndicator
                .position(x: min(max(34, (finger ?? hover)?.x ?? size.width / 2), size.width - 34),
                          y: min(max(34, (finger ?? hover)?.y ?? size.height / 2), size.height - 34))
                .transaction { $0.animation = nil }
                .opacity(finger != nil || hover != nil ? 1 : 0).allowsHitTesting(false)
        }
    }
    private var touchIndicator: some View {
        ZStack {
            Circle().fill(RemoteStyle.accent.opacity(finger == nil ? 0.08 : 0.12)).frame(width: 56, height: 56)
            Circle().trim(from: 0, to: holdProgress)
                .stroke(RemoteStyle.accent.opacity(0.7), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90)).frame(width: 64, height: 64)
                .animation(reduceMotion ? nil : (holdProgress == 1 ? .linear(duration: 0.55) : .easeOut(duration: 0.12)), value: holdProgress)
            if held {
                Image(systemName: "ellipsis").font(.system(size: 18, weight: .semibold)).foregroundStyle(RemoteStyle.accent)
            } else {
                Circle().fill(RemoteStyle.accent).frame(width: finger == nil ? 5 : 8, height: finger == nil ? 5 : 8)
            }
        }.frame(width: 68, height: 68)
    }
    private func startHold() {
        cancelHold()
        guard model.supports(.longSelect) else { return }
        let gesture = gestureID
        let session = model.navigationSessionID
        holdProgress = 1
        holdTask = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(550)) } catch { return }
            guard !Task.isCancelled, gestureID == gesture, isTouching, finger != nil,
                  model.navigationSessionID == session, model.canNavigate, model.supports(.longSelect),
                  let command = interpreter.hold() else { return }
            held = true
            send(command)
        }
    }
    private func cancelHold() {
        holdTask?.cancel(); holdTask = nil; holdProgress = 0
    }
    private var dots: some View {
        Canvas { context, size in
            for row in 0..<7 {
                for column in 0..<11 {
                    let x = size.width * CGFloat(column + 1) / 12
                    let y = size.height * CGFloat(row + 1) / 8
                    context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1.5, height: 1.5)), with: .color(.primary.opacity(0.055)))
                }
            }
        }
    }
    private func touchingChanged(_ active: Bool) {
        guard !active else { return }
        let endedGesture = gestureID
        Task<Void, Never> { @MainActor in
            // Let onEnded consume the final sample before cleaning up cancellation.
            await Task.yield()
            guard !isTouching, gestureID == endedGesture, finger != nil else { return }
            resetInteraction()
        }
    }
    private func resetInteraction() {
        cancelHold(); held = false
        gestureID = UUID(); finger = nil; hover = nil; interpreter.reset(); model.cancelNavigation()
    }
    private func send(_ command: RemoteCommand) { model.navigate(command) }
}
