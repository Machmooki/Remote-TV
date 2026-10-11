# Touchpad and phone keyboard — 2026-10-11

## Usage

Connect the PLAYBOX, focus a search/text field on the TV, then tap **Keyboard** below the touchpad. Type a draft on the iPhone and choose **Send text**, or **Search** to send the draft followed by Enter. The native phone keyboard supports editing/composition before transmission, including Thai, emoji and iOS dictation. This is explicit draft submission, rather than continuous synchronization of an existing TV field. Some applications use custom input methods or ignore IME/Enter; check the actual TV result.

The local touch indicator follows contact immediately. Compatible pointing devices can also move it with Apple's [onContinuousHover](https://developer.apple.com/documentation/swiftui/view/oncontinuoushover(coordinatespace:perform:)). Hover alone sends no TV command. On an iPhone, holding a finger above the screen does not supply hover input. Physical pointer/Pencil hover needs a supported iPad and accessory.

The pinned [Remote v2 schema](https://github.com/tronikos/androidtvremote2/blob/e664a8e1f14ee458b14c646bfb3ea46f10367051/src/androidtvremote2/remotemessage.proto) has key injection and IME messages, with no mouse-coordinate injection message. TV control therefore moves focus with directions and OK; this implementation does not create a free mouse pointer on the TV.

## Implementation

- `TouchpadInterpreter` retains sub-step distance, resets remainder on reversal, discards perpendicular drift at each direction step, bounds large flick backlog and prevents out-and-back swipes from selecting accidentally. Existing Settings → Swipe distance remains available.
- `TouchpadCommandQueue` paces serial navigation at 80 ms after completed writes, with at most two pending directions. Direction changes replace pending movement. A generation token prevents cancelled workers from clearing newer work. Already submitted network writes cannot be recalled.
- `TouchpadView` renders positions without animation lag, consumes final gesture samples before cancellation cleanup and clears interaction on disconnect/session changes/disappearance. `RemoteViewModel.navigate` binds queued work to one service session. Backgrounding, a new gesture or cancellation clears pending navigation; nothing is replayed after reconnect.
- `KeyboardView` → `RemoteViewModel.sendText` → `RemoteControlService.sendText` → `CommandDispatcher.sendText` → `AndroidTVRemoteTransport.sendText` → existing authenticated `ATVChannel.send`. The new view has explicit app target Sources membership. No new transport, permissions or runtime dependencies.
- IME feature `4` is included in requested mask `615`. Unsupported servers disable text transmission with an actionable explanation. Incoming `remote_ime_batch_edit` field 21 updates the IME/field counters; counters start at zero and reset every session.
- Outgoing text follows the pinned [remote.py send_text](https://github.com/tronikos/androidtvremote2/blob/e664a8e1f14ee458b14c646bfb3ea46f10367051/src/androidtvremote2/remote.py): `RemoteImeBatchEdit` contains both counters and one `RemoteEditInfo(insert=1)` with a `RemoteImeObject`. Start/end = Unicode scalar count minus one, matching Python `len(text)` for Thai combining marks and emoji, rather than Swift grapheme-cluster count. Text is UTF-8.
- **Search** sends Android `KEYCODE_ENTER` (66) only after text transmission completes. Text/Enter capture the same transport; cancellation, failed text or transport replacement cannot submit Enter to a replacement session. Empty text and drafts exceeding 2,048 Unicode scalars produce no writes.
- Drafts clear after successful transmission or sheet dismissal and are never automatically resent. Text content is neither logged nor persisted in UserDefaults/Keychain; OSLog labels writes only as `IME text`. Recording transports are now test-only; the app no longer offers Demo. A completed write is labelled **transmitted**, without claiming the TV accepted it.

## Hold/menu and visual update

Hold still for 0.55 seconds to recognize a long OK action. The transport then sends keycode 23 with START_LONG, waits 800 ms, and sends END_LONG. This replaces the earlier Menu-key mapping; see [YouTube hold implementation and test instructions](YouTubeHold.md). The recognized gesture sends no extra short OK or navigation on release. Movement before recognition disqualifies the hold. Cancellation before recognition sends nothing. After recognition, the bounded key pair completes its release even if its gesture worker is cancelled; disconnect cancels/closes the session. Stale releases/callbacks cannot affect a replacement session. VoiceOver **Open TV menu** requests the same long OK action.

Individual TV apps decide how to handle long OK. The indicator includes a 0.55-second hold progress ring. The UI uses understated adaptive light/dark surfaces, compact shortcut cards, subtle touchpad depth, spring press feedback and a staggered fade/slide on initial appearance. Position tracking remains unanimated to avoid lag. Motion effects respect Reduce Motion.

Demo UI, view-model state/actions and the production mock transport were removed. The recording transport and legacy `.demo` fixture exist only in `Remote-TVTests/TestRemoteTransport.swift`. Legacy saved demo entries are ignored during selection/restoration. Saved real pairings, auto reconnect and IME remain intact.

## Earlier keyboard validation

**45/45 tests passed**: 40 unit/integration and 5 UI. Debug Simulator and unsigned Release iOS builds passed. New tests cover swipe distance, reversal/diagonal behavior, bounded flicks/queues, serial writes, cancellation/stale completions, failures, IME capability negotiation, current counters, Thai/emoji encoding, exact Python-reference bytes, text-before-Enter ordering, no Enter after failed text or transport replacement, and keyboard UI in Demo/disconnected states. Existing recovery, real TLS, discovery and shortcut tests still pass. Golden bytes were independently generated with the pinned Python protobuf schema in a temporary environment.

Result bundle `/tmp/AISRemote-touchpad-tests.xcresult`; log `/tmp/AISRemote-touchpad-tests.log`; Release log `/tmp/AISRemote-touchpad-release.log`; summary `TouchpadKeyboardTestResults.json`; exported UI screenshots `/tmp/AISRemote-touchpad-attachments`. No Swift compiler/concurrency errors or xcresult runtime warnings. Xcode emits the existing unused AppIntents metadata notice.

Phone typing/search on the user's physical PLAYBOX and accessory hover remain unverified. Physical checks: try slow/fast swipes, reversal, tap after swipe, background interruption and reconnect. Focus a TV search field and send English, then Thai/emoji; verify Search on the TV. Disable Wi-Fi during typing and confirm there is no automatic resend. On compatible pointer hardware, hover must move only the local indicator; click/drag retain TV focus control.

Current hold/UI verification and screenshots are recorded in `Verification.md` and `TestResults.json`. The earlier 45-test run above predates removal of Demo. Physical PLAYBOX long-OK/context behavior is still unverified.
