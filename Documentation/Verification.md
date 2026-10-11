# Verification and physical-device procedure

Existing project: `Remote-TV.xcodeproj`, scheme `Remote-TV`, bundle `Mach.Remote-TV`, signing team `4K48W37UB7`, automatic signing retained. No new project, no runtime package dependencies, no Bluetooth or multicast entitlements.

## Automated verification

- Debug Simulator build and unit/UI tests are run with Xcode 27.0 and Swift 6 on iPhone 17 / iOS 27.0.
- Release iOS build is compiled with signing disabled for verification. This proves compilation, not installation or successful physical pairing.
- Tests exercise all frame split positions, coalesced messages, malformed/oversized input, schema wire fields, keycode mapping, certificate signature/key matching, persistent Keychain identity, certificate-bound code proof, pairing negotiation rejection, feature negotiation, ping response, real command/app-link writes through injected channels, rejected writes, unauthenticated-start rejection, real loopback TCP/TLS, TLS peer pin mismatch, cancellation, production Bonjour discovery/resolution and UI behavior.
- Scripted protocol peers are test-only. Production connection uses Apple Network.framework and real Keychain exclusively. Demo has now been removed from production; recording transports exist only in the unit-test target.
- The final test summary is saved in `TestResults.json`; local xcresult/build artifact locations and final totals are recorded below after execution.

## Actual PLAYBOX protocol probe

The selected endpoint `192.168.1.130` accepted TCP 6466/6467. Its Bonjour TXT Bluetooth identifier matched the user's MAC address. A development-Mac probe using the app's production `AndroidTVTLSChannel` and `PairingManager` completed TLS 6467 and protocol request/options/configuration acknowledgements. This verified the pairing negotiation, without sending a PIN proof, persisting a pairing or sending controls. See `Compatibility.md`.

Optional repeat (this requests a temporary code on the TV; no control commands or Keychain writes):

```sh
swiftc -swift-version 6 -parse-as-library \
  Remote-TV/Models/RemoteModels.swift \
  Remote-TV/Services/{SecureCredentialStore,AndroidTVWire,ClientIdentity,AndroidTVTLSChannel,PairingManager}.swift \
  Tools/ProbePLAYBOX.swift -o /tmp/AISRemote-ProbePLAYBOX
/tmp/AISRemote-ProbePLAYBOX 192.168.1.130
```

## Test on the physical iPhone and PLAYBOX

1. Keep PLAYBOX powered on and its HDMI input visible. Connect the iPhone and box to the same LAN; avoid guest Wi-Fi/client isolation. The physical remote being Bluetooth does not affect this IP protocol.
2. In Xcode open the existing project, select the existing `Remote-TV` scheme and your physical iPhone, then Run with your existing signing settings.
3. Open the device selector → Search for devices. Accept Local Network access. The real service type displayed must be `_androidtvremote2._tcp`. If denied, enable the app in Settings → Privacy & Security → Local Network, return and search again. iOS offers no general Boolean permission query: the screen reports actual browser/access evidence and explicit denial separately.
4. Choose the discovered box. Alternatively type **192.168.1.130** → **Check this address**. Confirm ports 6466 and 6467. A timeout/refusal is a network/service problem, not a bad pairing code. Recheck the current IP on the box if it changed.
5. Scroll to **Secure connection** → **Connect to …**. On first connection, the app opens TLS 6467 and verifies the pairing exchange. Only then should **Six-character TV code** appear. Enter the six hexadecimal characters currently displayed on the TV and tap **Verify code and connect**. **B8:59:CE:5E:1D:06 is a MAC address and cannot be used as the code.** Do not share the code or Keychain data in logs.
6. Expect pairing success followed by TLS 6466 and **Connected · authenticated Android TV Remote v2**. If a code expires or the service closes, use **Restart pairing** and the new TV code. If a saved certificate changed, confirm the IP/device before explicitly re-pairing. TCP-open or TLS-completed alone must not enable controls.
7. Close the Devices sheet. Swipe up/down on the touchpad, tap OK, then test Back, Home and volume ±. Check the actual TV after each command. Feedback says **transmitted** only after the Network.framework write completes; this protocol does not acknowledge each individual key's effect. Volume may control PLAYBOX output and depends on its audio/HDMI-CEC settings; Panasonic television volume is not guaranteed.
8. Test Netflix/YouTube. These are real app-link requests, enabled only when the server advertises APP_LINK support; installation/link handling determines the result.
9. With **Auto connect & reconnect** enabled, background and reopen the app: it should reuse the same Keychain client identity and confirmed peer certificate automatically without a new code. Power off the box while connected: controls must disable when the connection fails or the 20-second bidirectional activity deadline expires. The app retries in the foreground with increasing delays, without replaying commands. Explicit Disconnect/Cancel stops retries; manual Connect enables them again. See `ConnectionRecovery.md` for extended tests.
10. If a step fails, use **Share connection diagnostics** in the Devices sheet. Include the failing step and visible TV behavior. In macOS Console select the connected iPhone and filter subsystem `Mach.Remote-TV` / category `Connection`. Event names identify discovery, TCP, TLS, pairing, session and command-write stages. No secret/private-key data is logged.

The user subsequently reported that physical iPhone connection succeeds, followed by short-lived disconnections. The recovery fix is tested below; extended physical-device stability, reconnection and individual command/HDMI effects still need confirmation on the user's devices.

## Initial connection implementation results — 2026-10-11

- **24/24 tests passed**, 0 failed/skipped: 20 unit/integration tests and 4 UI tests on iPhone 17, iOS 27.0. Runtime warnings in xcresult: none. Bundle: `/tmp/AISRemote-complete.xcresult`; log: `/tmp/AISRemote-complete.log`.
- Debug Simulator compilation passed as part of the final test action. Derived data: `/tmp/AISRemote-network-build`.
- **Release generic iOS build passed**, signing disabled only on the verification command. Derived data: `/tmp/AISRemote-network-release`; log: `/tmp/AISRemote-network-release.log`. No Swift compiler/concurrency errors. Xcode emits an AppIntents metadata-extraction notice because this app does not use AppIntents.
- Inspected the built Release app's actual `Info.plist`: bundle `Mach.Remote-TV`, minimum iOS 17.0, `NSLocalNetworkUsageDescription` present, `NSBonjourServices = ["_androidtvremote2._tcp"]`. Actual app Sources phase contains all 19 Swift files, including the six added protocol/identity/connection files.
- Production Bonjour integration test publishes a test service and verifies that the actual `DeviceDiscoveryService` resolves its host and numeric addresses while scanning remains active.
- Real TLS loopback test verifies a framed write/read, exact peer certificate pin, rejection of a different pin and cancellation. UI test verifies manual-IP connection failure is visible and never enables remote controls.
- Actual selected PLAYBOX Bonjour hostname resolved to `192.168.1.130` as well as IPv6 addresses; the TXT MAC matched the user's identifier. Live Mac probe reached TLS/Polo pairing qualification only. Physical iPhone pairing and command effects are still pending.


## Connection recovery update — 2026-10-11

- **30 unit/integration tests passed** and **4 UI tests passed**, 34 distinct tests verified; zero failures/skips. The full run passed 29 unit/integration + 4 UI; the subsequent unit run added a real TLS server that stays silent during key traffic and passed all 30 unit/integration tests. Production source was unchanged between these runs.
- Full-run bundle `/tmp/AISRemote-reconnect-tests.xcresult`, log `/tmp/AISRemote-reconnect-tests.log`; latest unit/integration bundle `/tmp/AISRemote-reconnect-integration.xcresult`, log `/tmp/AISRemote-reconnect-integration.log`. Both summaries are preserved in `ConnectionRecoveryTestResults.json`.
- **Debug Simulator and Release iOS builds passed**, with no Swift compiler/concurrency errors or warnings. Release signing disabled only for the verification command. Derived data `/tmp/AISRemote-reconnect-build` and `/tmp/AISRemote-reconnect-release`; Release log `/tmp/AISRemote-reconnect-release.log`. The only build warning is Xcode's unused AppIntents metadata notice.
- Verified built Release plist still has bundle `Mach.Remote-TV`, minimum iOS 17.0, Local Network description and the single browsed Bonjour service. Bundle/signing and entitlements were not changed.
- Added tests cover command activity beyond the former receive deadline, real quiet TLS sessions, exact ping replies, actual inactivity detection, saved-pairing reconnect without key replay, increasing backoff, stale callbacks, fatal identity/permission/authorization failures, cancel during retry, background/foreground, auto-off, migration/restoration and persisted user stop.
- The user confirms the previous app connects to the physical PLAYBOX. This update has not yet undergone extended testing on their iPhone/PLAYBOX; use `ConnectionRecovery.md` for the two-minute active/idle and network-loss procedure.


## Touchpad and phone keyboard update — 2026-10-11

- **45/45 tests passed**, 0 failed/skipped: 40 unit/integration and 5 UI on iPhone 17 / iOS 27.0 Simulator. No xcresult runtime warnings. Bundle `/tmp/AISRemote-touchpad-tests.xcresult`; log `/tmp/AISRemote-touchpad-tests.log`; summary `TouchpadKeyboardTestResults.json`.
- **Debug Simulator and unsigned Release iOS builds passed**, with no Swift compiler/concurrency errors. Release log `/tmp/AISRemote-touchpad-release.log`; only the existing unused AppIntents metadata notice remains. Derived data `/tmp/AISRemote-touchpad-build` and `/tmp/AISRemote-touchpad-release`.
- Verified built Release plist retains bundle `Mach.Remote-TV`, minimum iOS 17.0, Local Network description and `_androidtvremote2._tcp`; app Sources includes all 20 Swift files, including `KeyboardView.swift`. Signing and entitlements are unchanged.
- Golden IME bytes were checked independently against the pinned Python protobuf schema. Tests cover current field counters, Thai/emoji, capability gates, ordered text/Enter, failed writes and replacement-session isolation. Existing connection recovery, quiet real TLS, discovery and UI regressions still pass. Exported keyboard/remote screenshots were visually inspected.
- [Usage, implementation details and physical checks](TouchpadKeyboard.md). The iPhone keyboard UI is automated in explicit Demo; real protocol writes are tested with scripted peers. The user's PLAYBOX search behavior and pointer accessory hover have not been physically verified.


## Hold/menu, animation and Demo removal — 2026-10-11

- **49/49 tests passed**, zero failures/skips: 43 unit/integration and 6 UI. No xcresult runtime warnings. Final bundle `/tmp/AISRemote-hold-final.xcresult`; log `/tmp/AISRemote-hold-final.log`; summary `TestResults.json`.
- **Debug Simulator and unsigned Release iOS builds passed**, no Swift compiler/concurrency errors. Release log `/tmp/AISRemote-hold-release-final.log`. The existing unused AppIntents metadata notice remains. All 20 app Swift files remain explicitly included in Sources; the recording transport is only in the synchronized unit-test group.
- Hold tests verify exactly one Menu command, no OK on release, no navigation after recognition, permanent disqualification after movement and clean next-gesture behavior. Real protocol tests include Menu keycode 82. Migration tests ensure legacy demo devices cannot be selected/restored. UI tests verify Demo is absent, disconnected holding/typing cannot claim transmission, light/dark appearance, settings and actual manual-network failure behavior. Existing recovery/IME tests still pass.
- Inspected exported final UI screenshots: [Light](Screenshots/Minimal-light.png) and [Dark](Screenshots/Minimal-dark.png). Shortcut labels fit after removing the unnecessary arrow. Screenshots show the disconnected app, without simulated device state.
- Physical check: connect the PLAYBOX, focus an item, hold still on the touchpad for at least 0.55 seconds. The progress ring should complete and the app should report Menu transmitted after the actual network write. Release must not select the item. Dragging before recognition must navigate without opening a menu. Repeat while opening a sheet/backgrounding or interrupting Wi-Fi; no stale action may run on reconnect. Verify the actual app's response on the TV: Remote v2 Menu is not a universal mouse-right-button event. Physical PLAYBOX context behavior has not been verified here.


## YouTube long-OK correction — 2026-10-11

- Touchpad hold now sends actual long DPAD_CENTER/OK, keycode 23 with START_LONG then END_LONG, replacing the earlier short Menu mapping. The separate Menu button still sends 82. No visual/layout changes. See [usage and protocol details](YouTubeHold.md).
- **55 test methods passed**, zero failures/skips: 49 unit/integration and 6 UI; 56 executions including a two-value parameterized failure test. Full bundle `/tmp/AISRemote-long-ok-tests.xcresult`; log `/tmp/AISRemote-long-ok-tests.log`. A final pre-key-down cancellation/session guard was validated by all 49 unit/integration methods again in `/tmp/AISRemote-long-ok-final-unit.xcresult`; log `/tmp/AISRemote-long-ok-final-unit.log`. UI code/layout was unchanged by that final transport guard. Current summaries are in `TestResults.json`; the prior 49-test Menu/UI record is archived in `HoldUITestResults.json`.
- Debug Simulator and unsigned Release iOS builds passed; Release log `/tmp/AISRemote-long-ok-release-final.log`. No Swift compiler/concurrency errors or xcresult runtime warnings; the existing unused AppIntents notice remains.
- New tests cover literal key-down/key-up bytes and elapsed hold duration, no short OK/Menu substitution, bounded release despite gesture-worker cancellation, command ordering after release, disconnect/replacement isolation, failures at both write stages and cancellation before any key is sent.
- Physical YouTube thumbnail-popup behavior is unverified. Focus a video thumbnail on the browsing screen and hold the touchpad still about 1.5 seconds, then check the actual TV. The app reports transmission, not popup success.
