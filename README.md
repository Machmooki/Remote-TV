# Remote TV / AISRemote

Existing native SwiftUI iOS/iPadOS 17+ project, Swift 6, scheme **Remote-TV**. Open `Remote-TV.xcodeproj`; bundle ID and signing are preserved. The minimal touchpad UI, settings and Netflix/YouTube shortcuts are retained. Demo mode has been removed from the app; recording transports exist only in the unit-test target.

Real connections now use Bonjour discovery, manual IPv4/IPv6, TCP diagnostics, mutual TLS client identity, certificate-bound Android TV Remote v2 pairing, Keychain persistence and an authenticated remote session. Runtime protocol responses determine compatibility. A reachable port does not authorize control.

On your iPhone: choose Devices → enter PLAYBOX IP → Check this address → Connect → enter the six-character code displayed on the TV. The supplied `B8:59:CE:5E:1D:06` is a MAC address, not that code. Controls enable only after the paired remote session starts.

Auto connect/reconnect is enabled by default for previously paired boxes. It restores your last successful device on launch and reconnects after transient network loss or returning from background. Settings → **Auto connect & reconnect** controls this behavior. Explicit Disconnect pauses it until you connect manually. Commands are never replayed. See [disconnect fix and recovery behavior](Documentation/ConnectionRecovery.md).

[Root cause and exact connection methods](Documentation/Protocol.md) · [Observed PLAYBOX evidence](Documentation/Compatibility.md) · [Build and physical test instructions](Documentation/Verification.md) · [Checklist](Documentation/TODO.md)

Touchpad swipes retain movement distance and send bounded, paced navigation. Hold still to recognize a long OK action (550 ms recognition followed by an 800 ms remote press/release). In YouTube, focus a video thumbnail and hold about 1.5 seconds to try its additional actions. There is no extra short OK on release; the TV app decides how to handle long OK. See [YouTube hold behavior](Documentation/YouTubeHold.md). Soft surface gradients, spring button feedback and staggered appearance transitions respect Reduce Motion. The local indicator follows touch and supports pointer hover on compatible hardware. For phone typing: focus a TV search field → **Keyboard** below the touchpad → type → **Send text** or **Search** (text followed by Enter). This uses the real negotiated IME protocol. See [touchpad, hover and keyboard behavior](Documentation/TouchpadKeyboard.md).

Source folders: `Models`, `ViewModels`, `Services`, `Views`; unit and UI tests remain in the existing targets. New files have explicit app Compile Sources membership. There are no external runtime dependencies. Reference schemas and license are retained under `Documentation/ProtocolReference`.

```sh
xcodebuild -project Remote-TV.xcodeproj -scheme Remote-TV \
  -destination 'generic/platform=iOS Simulator' build
xcodebuild -project Remote-TV.xcodeproj -scheme Remote-TV \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=27.0' \
  -parallel-testing-enabled NO -collect-test-diagnostics never test
```

Diagnostics include network access observations, actual service type, resolved devices, TCP ports, TLS result, pairing state, session state, protocol errors and command write errors. OSLog: subsystem `Mach.Remote-TV`, category `Connection`. Private keys, pairing codes and proofs are never logged. A successful write means transmitted; verify the action on the TV.
