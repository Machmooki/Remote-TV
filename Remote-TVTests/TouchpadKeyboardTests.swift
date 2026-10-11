import Foundation
import Testing
@testable import Remote_TV

@MainActor
struct TouchpadKeyboardTests {
    @Test func swipePreservesRemainderAndReversesWithoutDiagonalDrift() {
        var pad = TouchpadInterpreter(threshold: 20)
        #expect(pad.move(x: 29, y: 8) == .right)
        #expect(pad.move(x: 41, y: 12) == .right) // Old anchor reset lost this step.
        #expect(pad.move(x: 19, y: 13) == .left)
        #expect(pad.end() == nil)
        for x in stride(from: 21.0, through: 105, by: 21) {
            #expect(pad.move(x: x, y: x * 0.35) == .right)
        }
        #expect(pad.end() == nil)
    }
    @Test func flickDoesNotAccumulateUnboundedStepsOrTurnIntoTap() {
        var pad = TouchpadInterpreter(threshold: 20)
        #expect(pad.move(x: 800, y: 0) == .right)
        for _ in 0..<100 { #expect(pad.move(x: 800, y: 0) == nil) }
        #expect(pad.end() == nil)
        #expect(pad.end() == .select)
        _ = pad.move(x: 30, y: 0)
        pad.reset()
        #expect(pad.move(x: 1, y: 2) == nil)
        #expect(pad.end() == .select)
    }
    @Test func navigationQueueBoundsBurstAndSerializesWrites() async throws {
        let queue = TouchpadCommandQueue(interval: .milliseconds(5))
        var commands: [RemoteCommand] = []
        var concurrent = 0
        var maximum = 0
        let send: @MainActor (RemoteCommand) async -> Bool = { command in
            concurrent += 1; maximum = max(maximum, concurrent)
            commands.append(command)
            try? await Task.sleep(for: .milliseconds(5))
            concurrent -= 1
            return true
        }
        for _ in 0..<100 { queue.enqueue(.right, send: send) }
        try await Task.sleep(for: .milliseconds(80))
        #expect(commands == [.right, .right])
        #expect(maximum == 1)
        queue.cancel()
    }
    @Test func cancellationAndDirectionChangeDiscardStaleNavigation() async throws {
        let queue = TouchpadCommandQueue(interval: .milliseconds(5))
        var firstStarted = false
        var first: CheckedContinuation<Void, Never>?
        var commands: [RemoteCommand] = []
        queue.enqueue(.up) { command in
            firstStarted = true; commands.append(command)
            await withCheckedContinuation { first = $0 }
            return true
        }
        for _ in 0..<60 { if firstStarted { break }; await Task.yield() }
        #expect(firstStarted)
        queue.enqueue(.up) { commands.append($0); return true }
        queue.cancel()
        queue.enqueue(.left) { commands.append($0); return true }
        queue.enqueue(.right) { commands.append($0); return true }
        // An old completion must not clear the replacement worker or its queue.
        first?.resume(); first = nil
        try await Task.sleep(for: .milliseconds(40))
        #expect(commands == [.up, .right])
        queue.cancel()
    }
    @Test func failedNavigationDoesNotDrainPendingKeys() async throws {
        let queue = TouchpadCommandQueue(interval: .milliseconds(1))
        var sent = 0
        let fail: @MainActor (RemoteCommand) async -> Bool = { _ in sent += 1; return false }
        queue.enqueue(.right, send: fail)
        queue.enqueue(.right, send: fail)
        try await Task.sleep(for: .milliseconds(20))
        #expect(sent == 1)
        queue.cancel()
    }
    @Test func phoneTypingRequiresAuthenticatedSession() async {
        let model = RemoteViewModel(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        #expect(!model.canType)
        #expect(!(await model.sendText("cat", submit: true)))
        #expect(model.errorMessage != nil)
        model.errorMessage = nil
        model.disconnect()
        #expect(!model.canType)
    }
    @Test func holdSendsOneLongOKAndNeverSelectsOnRelease() {
        var pad = TouchpadInterpreter()
        #expect(pad.move(x: 3, y: -2) == nil)
        #expect(pad.hold() == .longSelect)
        #expect(pad.hold() == nil)
        #expect(pad.move(x: 80, y: 0) == nil)
        #expect(pad.end() == nil)
        #expect(pad.move(x: 2, y: 1) == nil)
        #expect(pad.end() == .select)
    }
    @Test func movementAndCancellationDisqualifyHold() {
        var pad = TouchpadInterpreter()
        #expect(pad.move(x: 11, y: 0) == nil)
        #expect(!pad.canHold)
        #expect(pad.move(x: 0, y: 0) == nil)
        #expect(pad.hold() == nil) // Returning to the start must not restore eligibility.
        #expect(pad.end() == nil)
        #expect(pad.move(x: 40, y: 0) == .right)
        #expect(pad.hold() == nil)
        pad.reset()
        #expect(pad.move(x: 1, y: 0) == nil)
        #expect(pad.canHold)
        #expect(pad.end() == .select)
    }
    @Test func legacyDemoCannotBeSelectedOrRestored() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let real = try TVDevice.manual("192.168.1.130")
        defaults.set(try JSONEncoder().encode([TVDevice.demo, real]), forKey: "savedDevices")
        defaults.set(try JSONEncoder().encode(TVDevice.demo), forKey: "lastConnectedDevice")
        let model = RemoteViewModel(defaults: defaults)
        #expect(model.savedDevices == [real])
        model.inspect(.demo)
        model.resume()
        #expect(model.selectedDevice == nil)
        #expect(!model.isConnected && !model.canNavigate && !model.canType)
        model.stopConnection()
    }
}
