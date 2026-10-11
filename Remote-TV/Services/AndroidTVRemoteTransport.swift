import Foundation

@MainActor
final class AndroidTVRemoteTransport: RemoteTransport {
    private(set) var isConnected = false
    private var features: UInt64 = 0
    private var imeCounter: UInt64 = 0
    private var imeFieldCounter: UInt64 = 0
    private var channel: (any ATVChannel)?
    private var receiveTask: Task<Void, Never>?
    private var idleTask: Task<Void, Never>?
    private var lastActivity = ContinuousClock.now
    private let idleTimeout: Duration
    private let longPressDuration: Duration
    private var longPressTask: Task<Void, Error>?
    private var session = UUID()
    private(set) var receivedMessages = 0
    private(set) var sentCommands = 0
    private(set) var answeredPings = 0
    var onActivity: ((Int, Int, Int) -> Void)?
    var onDisconnect: ((Error) -> Void)?
    var onProtocolError: ((String) -> Void)?
    private let channelFactory: ((TVDevice) throws -> any ATVChannel)?
    init(idleTimeout: Duration = .seconds(20), longPressDuration: Duration = .milliseconds(800), channelFactory: ((TVDevice) throws -> any ATVChannel)? = nil) {
        self.idleTimeout = idleTimeout; self.longPressDuration = longPressDuration; self.channelFactory = channelFactory
    }
    var supportedCommands: Set<RemoteCommand> {
        guard isConnected, features & 2 != 0 else { return [] }
        var commands = Set(RemoteCommand.allCases)
        if features & 32 == 0 { commands.remove(.power) }
        if features & 64 == 0 { commands.subtract([.volumeUp, .volumeDown, .mute]) }
        return commands
    }
    var supportedApps: Set<TVAppShortcut> { isConnected && features & 512 != 0 ? Set(TVAppShortcut.allCases) : [] }
    var supportsTextInput: Bool { isConnected && features & 4 != 0 }
    func connect(to device: TVDevice) async throws {
        disconnect()
        receivedMessages = 0; sentCommands = 0; answeredPings = 0
        guard !device.isLegacyDemo, let channelFactory else { throw ATVError.message("Pair this device before opening its authenticated remote session.") }
        let channel = try channelFactory(device); self.channel = channel
        do {
            try await channel.open()
            var configured = false; var active = false
            let deadline = ContinuousClock.now.advanced(by: .seconds(15))
            while ContinuousClock.now < deadline {
                let message = try Proto(await channel.next(timeout: .seconds(10)))
                if message.bytes[40] != nil {
                    guard configured, active, features & 2 != 0 else { throw ATVError.message("Remote session started without a supported key-control handshake.") }
                    isConnected = true
                    lastActivity = .now
                    idleTask = Task { [weak self] in await self?.watchActivity() }
                    ConnectionLog.event("REMOTE_SESSION_CONNECTED")
                    receiveTask = Task { [weak self] in await self?.receiveLoop(channel) }
                    return
                }
                if message.bytes[1] != nil { configured = true }
                if message.bytes[2] != nil { active = true }
                try await handle(message, channel: channel)
            }
            throw ATVError.message("Remote session negotiation timed out; TLS alone is not authentication.")
        } catch { disconnect(); throw error }
    }
    private func handle(_ message: Proto, channel: any ATVChannel) async throws {
        if message.bytes[3] != nil {
            let text = "PLAYBOX rejected a remote protocol message. Check Android TV Remote Service and retry pairing."
            onProtocolError?(text)
            throw ATVError.message(text)
        }
        if message.bytes[1] != nil {
            features = try message.nested(1).integers[1, default: 0] & 615 // PING | KEY | IME | POWER | VOLUME | APP_LINK
            guard features & 2 != 0 else { throw ATVError.message("Remote service does not advertise key control support.") }
            let info = Proto.int(3, 1) + Proto.string(4, "1") + Proto.string(5, "atvremote") + Proto.string(6, "1.0.0")
            try await channel.send(Proto.blob(1, Proto.int(1, features) + Proto.blob(2, info)))
        }
        if message.bytes[2] != nil { try await channel.send(Proto.blob(2, Proto.int(1, features))) }
        if message.bytes[21] != nil {
            let batch = try message.nested(21)
            imeCounter = batch.integers[1, default: 0]
            imeFieldCounter = batch.integers[2, default: 0]
        }
        if message.bytes[8] != nil {
            let value = try message.nested(8).integers[1, default: 0]
            try await channel.send(Proto.blob(9, Proto.int(1, value)))
            answeredPings += 1
            lastActivity = .now
            onActivity?(receivedMessages, sentCommands, answeredPings)
            ConnectionLog.event("REMOTE_PING_REPLIED")
        }
    }
    private func receiveLoop(_ channel: any ATVChannel) async {
        do {
            while !Task.isCancelled {
                // Established sessions wait continuously. A separate watchdog observes BOTH
                // received messages and completed writes; command traffic can suppress TV pings.
                let data = try await channel.next(timeout: nil)
                lastActivity = .now; receivedMessages += 1
                try await handle(Proto(data), channel: channel)
                onActivity?(receivedMessages, sentCommands, answeredPings)
            }
        } catch {
            guard !Task.isCancelled else { return }
            sessionFailed(error)
        }
    }
    private func watchActivity() async {
        while !Task.isCancelled && isConnected {
            let remaining = idleTimeout - lastActivity.duration(to: .now)
            if remaining <= .zero {
                ConnectionLog.event("REMOTE_SESSION_IDLE_TIMEOUT", "rx=\(receivedMessages) tx=\(sentCommands) pings=\(answeredPings)")
                sessionFailed(ATVError.sessionIdle)
                return
            }
            do { try await Task.sleep(for: remaining) } catch { return }
        }
    }
    private func sessionFailed(_ error: Error) {
        guard isConnected else { return }
        disconnect()
        ConnectionLog.event("REMOTE_SESSION_DISCONNECTED", "retryable=\(ATVError.canRetry(error))")
        onDisconnect?(error)
    }
    private func commandCompleted() {
        lastActivity = .now; sentCommands += 1
        onActivity?(receivedMessages, sentCommands, answeredPings)
    }
    func send(_ command: RemoteCommand) async throws {
        let channel = try await commandChannel()
        guard supportedCommands.contains(command) else { throw RemoteError.unsupportedCommand }
        if command == .longSelect {
            let token = session
            // Once key-down is sent, finish the bounded press/release even if the
            // gesture worker is cancelled. Disconnect still cancels/closes it.
            let press = Task { @MainActor [weak self] in
                guard let self else { throw RemoteError.disconnected }
                defer { if self.session == token { self.longPressTask = nil } }
                do {
                    try Task.checkCancellation()
                    guard self.isConnected, self.session == token else { throw RemoteError.disconnected }
                    try await channel.send(Proto.blob(10, Proto.int(1, 23) + Proto.int(2, 1))) // START_LONG
                    guard self.isConnected, self.session == token else { throw RemoteError.disconnected }
                    self.lastActivity = .now
                    try await Task.sleep(for: self.longPressDuration)
                    guard self.isConnected, self.session == token else { throw RemoteError.disconnected }
                    try await channel.send(Proto.blob(10, Proto.int(1, 23) + Proto.int(2, 2))) // END_LONG
                    guard self.session == token else { throw RemoteError.disconnected }
                    self.commandCompleted()
                    ConnectionLog.event("REMOTE_COMMAND_SENT", "longSelect")
                } catch {
                    if self.session == token {
                        ConnectionLog.event("REMOTE_COMMAND_FAILED", "longSelect")
                        // Don't reuse a failed session with an unfinished press;
                        // no release or stale callback is sent to a newer session.
                        self.commandFailed(error)
                    }
                    throw error
                }
            }
            longPressTask = press
            try await press.value
            return
        }
        do {
            try await channel.send(Proto.blob(10, Proto.int(1, command.androidKeyCode) + Proto.int(2, 3)))
            commandCompleted()
            ConnectionLog.event("REMOTE_COMMAND_SENT", command.rawValue)
        } catch { ConnectionLog.event("REMOTE_COMMAND_FAILED", command.rawValue); commandFailed(error); throw error }
    }
    func launch(_ app: TVAppShortcut) async throws {
        let channel = try await commandChannel()
        guard supportedApps.contains(app) else { throw RemoteError.unsupportedApp }
        let link = app == .netflix ? "https://www.netflix.com" : "https://www.youtube.com"
        do { try await channel.send(Proto.blob(90, Proto.string(1, link))); commandCompleted(); ConnectionLog.event("REMOTE_COMMAND_SENT", app.rawValue) }
        catch { ConnectionLog.event("REMOTE_COMMAND_FAILED", app.rawValue); commandFailed(error); throw error }
    }
    func sendText(_ text: String) async throws {
        let channel = try await commandChannel()
        guard supportsTextInput else { throw RemoteError.unsupportedText }
        let count = text.unicodeScalars.count // Matches Python len(text) in the pinned reference.
        guard (1...2048).contains(count) else { throw RemoteError.invalidText }
        let position = UInt64(count - 1)
        let object = Proto.int(1, position) + Proto.int(2, position) + Proto.string(3, text)
        let edit = Proto.int(1, 1) + Proto.blob(2, object)
        let batch = Proto.int(1, imeCounter) + Proto.int(2, imeFieldCounter) + Proto.blob(3, edit)
        do {
            try await channel.send(Proto.blob(21, batch))
            commandCompleted()
            ConnectionLog.event("REMOTE_COMMAND_SENT", "IME text")
        } catch {
            ConnectionLog.event("REMOTE_COMMAND_FAILED", "IME text")
            commandFailed(error); throw error
        }
    }
    private func commandFailed(_ error: Error) {
        sessionFailed(error)
    }
    private func commandChannel() async throws -> any ATVChannel {
        let token = session
        if let press = longPressTask { try await press.value }
        try Task.checkCancellation()
        guard session == token, isConnected, let channel else { throw RemoteError.disconnected }
        return channel
    }
    func disconnect() {
        session = UUID()
        longPressTask?.cancel(); longPressTask = nil
        receiveTask?.cancel(); receiveTask = nil
        idleTask?.cancel(); idleTask = nil
        channel?.close(); channel = nil
        features = 0; imeCounter = 0; imeFieldCounter = 0; isConnected = false
    }
}

extension RemoteCommand {
    var androidKeyCode: UInt64 {
        switch self {
        case .up: 19; case .down: 20; case .left: 21; case .right: 22; case .select, .longSelect: 23
        case .back: 4; case .home: 3; case .menu: 82; case .volumeUp: 24; case .volumeDown: 25
        case .mute: 164; case .channelUp: 166; case .channelDown: 167; case .playPause: 85
        case .rewind: 89; case .fastForward: 90; case .power: 26; case .enter: 66
        }
    }
}
