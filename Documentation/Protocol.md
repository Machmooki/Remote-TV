# Connection audit and implementation

Reference: [tronikos/androidtvremote2](https://github.com/tronikos/androidtvremote2/tree/e664a8e1f14ee458b14c646bfb3ea46f10367051), pinned commit `e664a8e1f14ee458b14c646bfb3ea46f10367051`. The schemas and Apache 2.0 license are preserved in `ProtocolReference/`. The Swift implementation follows `pairing.py`, `remote.py` and `base.py`; it implements a bounded protobuf subset of those schemas, without adding speculative fields. Google Polo's original protocol reference is linked in that repository's pairing implementation.

## Root cause before this change

- `RemoteViewModel.inspect(_:)` called only `ConnectionDiagnostics.run(for:)`. It replaced the transport but never called `RemoteControlService.connect(to:)`.
- `AndroidTVRemoteTransport.connect(to:)` and `send(_:)` in `Services/RemoteControlService.swift` always threw `compatibilityUnverified`; `isConnected` was permanently false and command capabilities were empty.
- `PairingService.pair(with:report:)` always threw the same error. No TLS connection, client certificate, pairing proof or remote protocol session existed. `ConnectionManager` and `PairingManager` did not exist.
- `DiagnosticReport.protocolVerified` is intentionally false because that report contains TCP-only evidence. It must never authorize control.
- The original discovery was real `NetServiceBrowser`/`NetService`, and TCP probes were real `NWConnection`. `MockRemoteTransport` was used only by explicit Demo mode. The UI was not the cause of the connection failure.
- The actual app target already referenced `Remote-TV/Info.plist` in Debug and Release, declaring Local Network usage and `_androidtvremote2._tcp`. Permissions were not missing from the source configuration.

## Production connection path now

| File | Responsible entry points |
|---|---|
| `Services/DeviceDiscoveryService.swift` | `search()` starts retained `NWBrowser`; `process(_:)` processes Bonjour endpoints; retained `NetService` resolves SRV/A/AAAA; `netServiceDidResolveAddress(_:)` publishes devices; `stop()` cancels scanning/resolvers. Search stays alive until stopped or screen/background lifecycle closes it. |
| `Services/ConnectionDiagnostics.swift` | `ConnectionDiagnostics.run(for:)` concurrently checks only selected host ports 6466/6467 using `TCPPortChecker.check` and `TCPProbe.run`; timeout, cancellation and Local Network denial are distinct from authentication. |
| `ViewModels/RemoteViewModel.swift` | `inspect` selects/saves a device and runs TCP diagnostics; `inspectManual` validates numeric IPv4/IPv6; `connectSelected` explicitly enters the real connection pipeline. `send`/`launch` await real writes; `suspend` stops network work on background. |
| `Services/ConnectionManager.swift` | `connect` loads client identity and saved peer certificate; otherwise starts protocol qualification/pairing. `submit` verifies the TV code and persists the confirmed peer in Keychain. `openRemote` injects the pinned TLS channel into the real transport, then invokes `RemoteControlService.connect`. Handles cancellation, failures and live session loss. |
| `Services/ClientIdentity.swift` | `loadOrCreate` retains a 2048-bit RSA private key in device-only Keychain; `DER.certificate` creates/signs a self-signed X.509 certificate, stored in Keychain and matched with the key by `SecIdentityCreate`. No exported private-key files. |
| `Services/AndroidTVTLSChannel.swift` | `open` uses `NWConnection`/TLS 1.2+ with client identity; obtains the actual peer certificate from `SecTrust`. `send`, `next`, `receive` implement bounded length-delimited protobuf, write completion, response deadlines and cancellation. |
| `Services/PairingManager.swift` | `start` requires version 2 / status 200 request/options/configuration acknowledgements and compatible hex encoding. `finish` computes certificate-bound PIN proof and waits for secret acknowledgement. Wrong versions/statuses stop pairing. |
| `Services/AndroidTVWire.swift` | `Proto`, `ProtoFrames` encode/decode schema field numbers and varint framing, including fragmented/coalesced TCP reads. `PairingProof.secret` hashes unsigned client RSA modulus/exponent + server modulus/exponent + final two PIN bytes, then validates the PIN's first byte. |
| `Services/AndroidTVRemoteTransport.swift` | `connect` requires pinned TLS, remote configure/features, active negotiation and remote start before `isConnected=true`. `handle` answers server pings and surfaces remote errors. `send` writes actual Android keycodes; `launch` writes app-link requests; failed writes/disconnects disable controls. |
| `Services/RemoteControlService.swift` | `CommandDispatcher` checks connected state and negotiated capabilities; service forwards actual writes. Recording transports now live only in the unit-test target; production Demo was removed. `UnverifiedBluetoothTransport` remains disabled. |
| `Services/SecureCredentialStore.swift` | Generic-password Keychain storage for public client certificate and confirmed peer certificate, `WhenUnlockedThisDeviceOnly`. RSA private key is a separate Keychain key item. Forget removes the selected peer pairing; it retains the client identity used by other pairings. |
| `Views/DevicesView.swift` | Existing Devices sheet now exposes network status, service type, discovered/manual devices, TCP reports, connect/re-pair, secure code entry, active state, TLS/pairing/protocol/write errors and shareable combined diagnostics. |

Dependency injection: `RemoteViewModel` still accepts `RemoteControlService`, `ConnectionDiagnostics` and `UserDefaults`; diagnostics accepts `PortChecking`; `AndroidTVRemoteTransport` accepts a channel factory; `PairingManager` accepts `ATVChannel`. Production `ConnectionManager` creates only real `AndroidTVTLSChannel` instances. Tests use scripted channels without replacing production behavior.

## Trust and state boundaries

Initial pairing must allow the TV's self-signed TLS certificate before it is trusted. That temporary channel can exchange pairing messages only. A user-entered code binds the client and server RSA certificates, and the TV must acknowledge the proof before the peer certificate is saved. Remote TLS connections pin that saved certificate exactly. A changed certificate fails with an actionable re-pair instruction; there is no silent fallback to unpinned remote control.

TCP open, TLS ready, pairing negotiated, pairing completed and remote session connected are separate states. The UI labels Connected only after the remote configure/active/start exchange over the paired TLS channel. Remote v2 has no per-key acknowledgement; a completed Network.framework write is labelled “transmitted”, never proof that the TV performed the action. Netflix/YouTube use app links and depend on the installed app/link handlers.

Session pings are answered with the received counter. The 20-second inactivity watchdog now observes BOTH received messages and completed command/app-link writes, following the reference's activity model. Established reads have no per-read deadline; pairing/negotiation retain bounded response deadlines. TCP keepalive also detects dead connections. See [disconnect diagnosis and recovery](ConnectionRecovery.md).

Paired sessions reconnect automatically with delays 1, 2, 4, 8, 16 and at most 30 seconds between attempts, while foregrounded and enabled. Repeated short-lived sessions retain the increasing backoff; a session lasting at least 30 seconds resets it after a later loss. Network path recovery wakes the retry policy. Backgrounding releases tasks/connections; foregrounding reuses the saved pairing. Launch restores the last successfully connected device, with migration from existing saved paired devices. Explicit Disconnect pauses automatic restoration across launches until manual Connect; Settings can disable automatic connection/reconnection.

Automatic attempts never initiate pairing or replay commands. Certificate changes, permission denial, TLS authorization rejection, malformed protocol messages and unsupported protocol features stop retries with a visible error. Session IDs/generation checks prevent stale callbacks from changing a newer session.

Phone typing additionally negotiates IME feature `4`, tracks the server's batch-edit counters and sends real field-21 text edits. Search writes text followed by keycode 66 on the same session; failures and session replacement prevent submission to a replacement transport. See [touchpad/keyboard implementation and limits](TouchpadKeyboard.md).

## Logging

OSLog subsystem `Mach.Remote-TV`, category `Connection`: `DISCOVERY_STARTED`, `DEVICE_FOUND`, `DEVICE_RESOLVED`, `TCP_CONNECT_SUCCESS`, `TCP_CONNECT_FAILED`, `TLS_HANDSHAKE_SUCCESS`, `TLS_HANDSHAKE_FAILED`, `PAIRING_REQUIRED`, `PAIRING_SUCCESS`, `PAIRING_FAILED`, `REMOTE_SESSION_CONNECTED`, `REMOTE_COMMAND_SENT`, `REMOTE_COMMAND_FAILED`, `REMOTE_PING_REPLIED`, `REMOTE_SESSION_IDLE_TIMEOUT`, `REMOTE_SESSION_DISCONNECTED`, `REMOTE_RECONNECT_SCHEDULED`. Only event names, service type, ports, outcomes and command names are public. PINs, proofs, private keys, credentials and protobuf payloads are not logged.

## Permissions

`Remote-TV/Info.plist` is applied by both app configurations. The single browsed service is `_androidtvremote2._tcp`, matching `NSBonjourServices`. Starting discovery or a selected-host connection initiates real local network access. Browser-ready is reported as no denial observed, not a fabricated permission grant; DNS policy denial and `NWPath.unsatisfiedReason.localNetworkDenied` produce Settings instructions. Empty results/timeouts can also mean Wi-Fi isolation or a missing service. No Bluetooth usage description, multicast entitlement or ATS exception was added.
