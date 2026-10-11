import Foundation

/// Converts relative finger movement into discrete TV navigation, never cursor coordinates.
struct TouchpadInterpreter {
    var threshold: Double = 36
    private var anchorX: Double = 0
    private var anchorY: Double = 0
    private var moved = false
    private var maximumDistance: Double = 0
    private var lastX: Double = 0
    private var lastY: Double = 0
    private var held = false
    var canHold: Bool { !held && !moved && maximumDistance < 10 }

    mutating func hold() -> RemoteCommand? {
        guard canHold else { return nil }
        held = true
        return .longSelect
    }

    mutating func move(x: Double, y: Double) -> RemoteCommand? {
        maximumDistance = max(maximumDistance, hypot(x, y))
        guard !held else { return nil }
        guard x != lastX || y != lastY else { return nil }
        // Reverse immediately instead of first consuming the previous direction's remainder.
        if (x - lastX) * (lastX - anchorX) < 0 { anchorX = lastX }
        if (y - lastY) * (lastY - anchorY) < 0 { anchorY = lastY }
        lastX = x; lastY = y
        let dx = x - anchorX
        let dy = y - anchorY
        let step = max(1, threshold)
        guard max(abs(dx), abs(dy)) >= step else { return nil }
        // Retain the sub-step distance instead of losing it at every event. Discard
        // the perpendicular component so a slightly diagonal swipe doesn't drift.
        // Cap backlog to one step: a fast flick must not keep moving after release.
        if abs(dx) > abs(dy) {
            anchorX = x - min(step, max(0, abs(dx) - step)) * (dx > 0 ? 1 : -1)
            anchorY = y
        } else {
            anchorY = y - min(step, max(0, abs(dy) - step)) * (dy > 0 ? 1 : -1)
            anchorX = x
        }
        moved = true
        if abs(dx) > abs(dy) { return dx > 0 ? .right : .left }
        return dy > 0 ? .down : .up
    }

    mutating func end() -> RemoteCommand? {
        let isTap = !held && !moved && maximumDistance < 10
        reset()
        return isTap ? .select : nil
    }

    mutating func reset() {
        anchorX = 0
        anchorY = 0
        maximumDistance = 0
        lastX = 0; lastY = 0
        moved = false
        held = false
    }
}

enum TVAppShortcut: String, CaseIterable, Identifiable, Sendable {
    case netflix, youtube
    var id: Self { self }
    var title: String { self == .netflix ? "Netflix" : "YouTube" }
}

enum RemoteSheet: String, Identifiable {
    case devices, settings, keyboard
    var id: Self { self }
}

/// Serial, paced navigation with a small bounded queue. Cancellation invalidates
/// the old worker even if its current network write completes after cancellation.
@MainActor
final class TouchpadCommandQueue {
    private var pending: [RemoteCommand] = []
    private var worker: Task<Void, Never>?
    private var generation = UUID()
    private let interval: Duration
    init(interval: Duration = .milliseconds(80)) { self.interval = interval }

    func enqueue(_ command: RemoteCommand, send: @escaping @MainActor (RemoteCommand) async -> Bool) {
        if pending.last != command { pending.removeAll() }
        if pending.count < 2 { pending.append(command) }
        guard worker == nil else { return }
        let token = generation
        worker = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, self.generation == token, !self.pending.isEmpty {
                let next = self.pending.removeFirst()
                guard await send(next) else { break }
                do { try await Task.sleep(for: self.interval) } catch { break }
            }
            guard self.generation == token else { return }
            self.pending.removeAll()
            self.worker = nil
        }
    }

    func cancel() {
        generation = UUID()
        pending.removeAll()
        worker?.cancel(); worker = nil
    }
}
