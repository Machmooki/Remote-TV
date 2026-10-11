# Short-lived disconnect diagnosis and automatic recovery

## What caused the reported failure

The user's physical iPhone screenshot shows an already disconnected session and the error “Protocol response timed out … handshake”. The previous `AndroidTVRemoteTransport.receiveLoop` repeatedly called `channel.next(timeout: .seconds(20))`. That timer measured time until the next inbound message; sending keys or opening apps did not reset it. Consequently, twenty seconds of command traffic without inbound messages could tear down an otherwise active TLS connection.

The pinned [androidtvremote2 reference](https://github.com/tronikos/androidtvremote2/blob/e664a8e1f14ee458b14c646bfb3ea46f10367051/src/androidtvremote2/remote.py) resets inactivity on both commands and received messages. Its server-ping discussion explains that commands can suppress idle pings. The old code used a receive deadline as if it were an activity deadline. The shared timeout message also incorrectly described a post-authentication timeout as a handshake failure. This code defect is reproduced by the regression scenario below. It matches the screenshot, although no iPhone packet capture has been provided to exclude additional network-side failures.

Other gaps were confirmed in the audit: no automatic reconnect, no foreground resume, no last-successful-device restoration, no TCP keepalive, and TLS diagnostics left “authentication pending” displayed even after a successful remote session.

## Changes in the existing project

- `AndroidTVRemoteTransport.receiveLoop`: established sessions wait for messages continuously (`next(timeout: nil)`); pairing and negotiation still have bounded deadlines.
- `watchActivity`, `commandCompleted`, `handle`: a separate monotonic 20-second watchdog observes both inbound messages and completed key/app-link writes. Pings are answered using the received counter; no invented application heartbeat messages were added. A genuinely inactive session drops with a session-specific error.
- `AndroidTVTLSChannel`: real Network.framework TCP keepalive (idle 15 seconds, interval 5 seconds, count 3), plus `noDelay`; typed transport/timeout/permission/certificate failures. Read cancellation and write timeouts still close the connection and complete pending continuations.
- `ConnectionManager`: a single connection attempt/retry owner, saved-pairing-only reconnect, delay sequence 1/2/4/8/16/30 seconds (cap 30), network path observation, background suspension and foreground resumption. A brief reconnected session does not reset the backoff and cause a one-second reconnect loop. A stable session of at least 30 seconds resets the sequence upon its next disconnect.
- Connection generations/session IDs reject stale state, TLS, protocol and activity callbacks from an older connection. Reconnection never restores a queued command, so keys, power and volume are not repeated automatically.
- `RemoteViewModel`: remembers the last successfully connected device, migrates existing saved pairings, persists the automatic-connection setting, and respects explicit stop across launch. `ContentView` resumes on active/initial launch and suspends on background, without adding background network entitlements.
- Existing Devices diagnostics include retry attempt and received/sent/ping counters. Successful authenticated sessions show paired-peer verification instead of stale “authentication pending”. Existing Settings contains **Auto connect & reconnect**, enabled by default. The working touchpad UI and signing are retained.

Only transport/network inactivity failures retry automatically. A changed peer certificate, denied local access, TLS authorization rejection or malformed/unsupported protocol stops the loop and retains the actionable error. Automatic attempts never create a new pairing prompt or discard a trust record. Disconnect/Cancel stops further attempts; manual Connect resumes the desired session. Turning off auto connection prevents launch, foreground and loss retries while leaving an already active session usable.

## Verification

Regression tests use production `AndroidTVRemoteTransport`, `ConnectionManager` and `AndroidTVTLSChannel`; injected/scripted peers exist only in the test target.

1. Quiet server with no replies after negotiation: send keys across multiple watchdog periods; connection remains alive. Stop traffic; the real inactivity deadline drops it with a session error, not a handshake error.
2. A real local TLS server negotiates the remote protocol, receives ten actual framed key messages and deliberately sends no subsequent replies/pings. Production TLS writes keep the session alive past its short test activity deadline; actual idle closes it afterward.
3. Repeated idle pings return the exact counters and keep the session alive with zero commands.
4. Transient loss reconnects; new transport contains no replayed key messages, and a stale old-session callback cannot disconnect it.
5. Consecutive transient failures increase the retry attempt; unknown/unpaired devices never auto-pair.
6. Certificate/permission/authorization failures stop retries, including after background/foreground.
7. Background halts attempts; foreground reconnects; explicit stop and disabled auto mode do not restart. A cancelled pending retry cannot run later.
8. Launch restores an existing paired device and persists last success; explicit stop and the auto setting survive relaunch.

See `Verification.md` for recorded build/test results. These are automated and local TLS tests, not a claim of extended physical AIS PLAYBOX stability.

## Test this update on your iPhone

1. Run this update over the installed app using the existing Xcode scheme/signing. Keep the app and its Keychain pairing; do not delete/reinstall or restart pairing just for this update.
2. Settings → **Auto connect & reconnect** should be on. If you previously pressed Disconnect (or used Demo in an older version), manually Connect once. Subsequent launches should reuse the existing pairing without another code.
3. Swipe/tap/use volume continuously for at least two minutes, then leave the remote idle for two minutes. Open Devices: verify Connected and increasing ping/reception counters when the box sends idle pings. Any failure now reports the actual session/transport stage.
4. Background the app briefly and reopen it. It should authenticate again automatically, without a code. The iOS app does not hold a background remote session.
5. Disable Wi-Fi briefly, then restore the same LAN. Watch Reconnecting/Waiting for network and verify it returns to Connected. Commands pressed during loss must not run later.
6. Disconnect/Cancel: verify no further attempts, including after reopening. Manually Connect to resume. Turn off auto connection in Settings to opt out of automatic behavior.
7. If it still drops, share the new connection diagnostics immediately afterward, including the activity counters, retry attempt, error and whether you were swiping or idle. In Console filter subsystem `Mach.Remote-TV`, category `Connection`: `REMOTE_PING_REPLIED`, `REMOTE_SESSION_IDLE_TIMEOUT`, `REMOTE_SESSION_DISCONNECTED`, `REMOTE_RECONNECT_SCHEDULED` distinguish missing activity from network or protocol errors. Codes, certificates, keys and command payloads are not logged.
