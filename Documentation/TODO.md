# AISRemote checklist

- [x] Preserve existing project, bundle/signing and minimal touchpad UI.
- [x] Audit real vs mock behavior and identify the always-rejecting transport/pairing stubs.
- [x] Replace the real transport/pairing stubs with verified-schema implementations.
- [x] Retained NWBrowser, processed results and retained SRV/A/AAAA resolvers; scanning stays alive while active.
- [x] Actual-target Local Network and matching Bonjour plist declarations.
- [x] Manual IPv4/IPv6; selected-host TCP 6466/6467 checks.
- [x] Minimal connection diagnostics, secure TV-code entry and actionable stage errors.
- [x] TLS client identity and certificate processing; private RSA key and pairing persistence in Keychain.
- [x] Certificate-bound six-hex PIN proof and protobuf varint framing.
- [x] Authenticated 6466 session gate, feature negotiation, keepalive, disconnect handling.
- [x] Actual key/app-link writes with error propagation; no success claim based on button taps.
- [x] Structured OSLog events without credentials or pairing payloads.
- [x] Live selected-IP TCP/TLS/Polo qualification from the development Mac; Bonjour TXT matches supplied MAC.
- [x] Automated protocol, TLS, networking and UI validation; iOS Release compilation.
- [x] User reports physical iPhone connection succeeds; subsequent short-lived disconnects prompted the recovery fix.
- [ ] Confirm physical effects of Up/Down/OK/Back/Home/Volume and app shortcuts.
- [x] Fix receive-only timeout; add activity watchdog, TCP keepalive and saved-pairing auto connect/reconnect.
- [x] Test quiet command sessions, ping replies, retry/backoff, no command replay, stale callbacks, lifecycle and explicit cancellation.
- [ ] Confirm the new recovery behavior during extended physical iPhone use, Wi-Fi/power loss and the user's HDMI/audio configuration.
- [ ] Bluetooth HID emulation remains unverified and disabled; no unnecessary Bluetooth permissions.
- [x] Retain touchpad swipe distance; pace/bound navigation and reject stale gesture/session work.
- [x] Local touch indicator and system pointer hover, with real TV focus navigation.
- [x] Native phone keyboard, real negotiated IME writes, current counters and ordered Search/Enter.
- [x] Validate Unicode encoding, reference bytes, failure/session boundaries and keyboard UI; 45 tests passed.
- [ ] Physically verify typing/search in PLAYBOX apps and hover on compatible pointer hardware.

- [x] Hold-to-menu gesture, one-shot action, swipe cancellation and no extra OK on release.
- [x] Minimal adaptive surfaces, shortcut cards, spring press feedback, hold progress and Reduce Motion support.
- [x] Remove production Demo UI/state/transport; keep recording fixtures only in unit tests.
- [ ] Confirm hold/Menu behavior inside the user’s PLAYBOX apps.

- [x] Correct touchpad hold to real long OK (START_LONG/END_LONG), with bounded release and session isolation, for video contextual actions.
- [ ] Verify the actual YouTube thumbnail popup on the user’s PLAYBOX after the long-OK correction.
