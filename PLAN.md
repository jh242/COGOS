# Plan: G1 Claude Terminal — Core Implementation

## Context

The Even Realities G1 glasses app currently calls the DeepSeek API when the user long-presses the left TouchBar. The goal is to replace this with a Claude-powered wearable terminal that routes all queries through a local Claude Code CLI relay on the user's desktop. This gives the glasses real agentic capabilities (web search, file access, bash, session memory) managed by Claude Code itself. A direct Anthropic API fallback is used when the relay is unreachable, with an `[OFFLINE]` indicator on the glasses display.

**Key constraints established in research/design:**
- Claude.ai Projects/Cowork have no public API — web UI only
- The Claude Agent SDK is Python/TypeScript only — cannot embed in Flutter
- `claude -p --resume <session_id>` is the programmatic interface that handles its own session memory
- One unified mode (no mode switching) — Claude decides which tools to use per query
- No phone-side wake word filter — "Hey Even" hardware trigger or tap-to-toggle handles activation

---

## Architecture

```
G1 Glasses
  ↕  dual BLE
Flutter App (phone)
  └─ PRIMARY  ──► relay (localhost:9090 or public URL) ──► claude -p --resume <sid>
  └─ FALLBACK ──► api.anthropic.com/v1/messages  (relay offline → [OFFLINE] tag)
```

The relay server runs on the user's desktop, in the CWD of their project. Claude Code CLI handles session memory via `~/.claude/` session files — the relay only passes session IDs through.

---

## Activation: Tap-to-Toggle

Rather than hold-to-talk (hold bar while speaking), the app uses **tap-to-toggle** with **auto-stop on silence**:

```
IDLE ──[double-tap]──► RECORDING ──[double-tap OR silence timeout]──► THINKING ──[answer ready]──► DISPLAYING
                                        └──[30s max]──────────────────────────────────────────────────────┘
DISPLAYING ──[tap L]──► prev page
DISPLAYING ──[tap R]──► next page
DISPLAYING ──[triple-tap]──► IDLE (exit)
IDLE / DISPLAYING ──[triple-tap]──► reset session + IDLE
```

"Hey Even" hardware wake word (built into G1 firmware) fires `0xF5 0x17` — same as long-press — so it also activates recording without any phone-side filtering.

### Silence auto-stop

Inside `startListening()`, a periodic timer watches `combinedText` for changes. If no new words arrive for `silenceThresholdSecs` (default: 2s) AND the transcript is non-empty, `recordOverByOS()` is called automatically:

```dart
_lastTranscriptChange = DateTime.now();
_silenceTimer = Timer.periodic(Duration(seconds: 1), (_) {
  if (!isReceivingAudio) { _silenceTimer?.cancel(); return; }
  final silent = DateTime.now().difference(_lastTranscriptChange).inSeconds;
  if (silent >= silenceThresholdSecs && combinedText.isNotEmpty) {
    _silenceTimer?.cancel();
    recordOverByOS();
  }
});
```

---

## Files to Delete / Archive

**Delete** (no future value):

| File | Reason |
|------|--------|
| `lib/services/text_service.dart` | Manual text send removed |
| `lib/views/features/text_page.dart` | Manual text send removed |
| `lib/views/features/notification/notification_page.dart` | Replaced by real notification system |

**Archive to `docs/reference/bmp/`** (keep for future custom display graphics):

| File | Destination |
|------|-------------|
| `lib/controllers/bmp_update_manager.dart` | `docs/reference/bmp/bmp_update_manager.dart` |
| `lib/services/features_services.dart` | `docs/reference/bmp/features_services.dart` |
| `lib/views/features/bmp_page.dart` | `docs/reference/bmp/bmp_page.dart` |

The BMP protocol (1-bit 576×136px images, 194-byte packets, CRC32Xz big-endian, dual-BLE simultaneous send) is the foundation for any future custom waveguide graphics. `BmpUpdateManager` handles the full send sequence including the storage address prefix on the first packet and the `0x20 0x0d 0x0e` end command.

---

## Files to Create / Modify

| File | Action | Purpose |
|------|--------|---------|
| `lib/services/cowork_relay_service.dart` | **CREATE** | HTTP/SSE client for the desktop relay |
| `lib/services/api_claude_service.dart` | **CREATE** | Fallback direct Anthropic API client (streaming) |
| `lib/models/claude_session.dart` | **CREATE** | Holds relay session ID + offline flag + last exchange |
| `lib/models/notify_model.dart` | **MOVE** from `lib/views/features/notification/notify_model.dart` | Notification data models |
| `lib/services/hud_service.dart` | **CREATE** | Look-up HUD: display logic + auto-dismiss timer |
| `lib/services/notification_service.dart` | **CREATE** | Auto-forward phone notifications to glasses |
| `lib/services/evenai.dart` | **MODIFY** | Replace DeepSeek, double-tap, silence detection, dispatch, streaming |
| `lib/ble_manager.dart` | **MODIFY** | Double-tap toggle; triple-tap reset; IMU look-up event (TBD cmd) |
| `lib/views/features_page.dart` | **MODIFY** | Remove BMP/Text/Notification buttons; add Settings + Notification Settings |
| `lib/views/settings_page.dart` | **CREATE** | API key, relay URL, secret token, silence threshold |
| `lib/views/notification_settings_page.dart` | **CREATE** | App whitelist management |
| `tools/relay/server.js` | **CREATE** | Node.js relay: spawns `claude -p` subprocess, SSE response |
| `pubspec.yaml` | **MODIFY** | Add `shared_preferences: ^2.3.0` |

---

## Step-by-Step Implementation

### 1. `lib/models/claude_session.dart` (new)

```dart
class ClaudeSession {
  String? relaySessionId;   // returned by relay, passed back on --resume
  bool isOffline = false;   // true when relay unreachable, triggers [OFFLINE] tag
  final List<Map<String, String>> messages; // fallback API history [{role, content}]

  ClaudeSession() : messages = [];
  void addUser(String text)      => messages.add({'role':'user',    'content':text});
  void addAssistant(String text) => messages.add({'role':'assistant','content':text});
  void reset() { relaySessionId = null; messages.clear(); isOffline = false; }
  static const int maxTurns = 20;
}
```

---

### 2. `lib/services/cowork_relay_service.dart` (new)

Streams SSE from relay server. Throws `RelayOfflineException` on timeout/connection refused.

```
POST <relayUrl>/query
Headers: Authorization: Bearer <secret>   (if secret configured)
         Accept: text/event-stream
Body:    { "message": "...", "session_id": "abc123" | null }

SSE response (newline-delimited):
  data: {"type":"text",    "text":"Hello, here is..."}
  data: {"type":"text",    "text":" the answer"}
  data: {"type":"done",    "session_id":"abc123"}
  data: {"type":"error",   "message":"..."}
```

Returns a `Stream<String>` of text chunks; session ID extracted from `done` event and written back to `session.relaySessionId`.

- Uses `dio` with `ResponseType.stream` for chunked SSE reception
- Parses `data:` lines from the raw byte stream
- If secret is non-empty, adds `Authorization: Bearer <secret>` header
- Connection timeout 10s; throws `RelayOfflineException` on failure
- On 401: throws `RelayAuthException`

---

### 3. `lib/services/api_claude_service.dart` (new)

Direct streaming call to `api.anthropic.com/v1/messages` — used only when relay is offline.

```
POST https://api.anthropic.com/v1/messages
Headers: x-api-key, anthropic-version: 2023-06-01, content-type: application/json
Body: { model, max_tokens, stream: true, system, messages }

SSE response events (relevant subset):
  event: content_block_delta  → delta.text  (text chunk)
  event: message_stop         → stream complete
```

Returns a `Stream<String>` of text deltas — same interface as `CoworkRelayService` so `evenai.dart` handles both identically.

- API key: `const String.fromEnvironment('ANTHROPIC_API_KEY')` with fallback to `shared_preferences`
- Model: `claude-sonnet-4-6`, `max_tokens`: 1024
- `stream: true` — uses Anthropic SSE streaming
- Passes `session.messages` for multi-turn context (capped at `ClaudeSession.maxTurns`)
- System prompt: `"You are a helpful assistant on Even Realities G1 smart glasses. The display shows 5 lines at a time. Be concise. No markdown."`
- On HTTP error: yields a single error string chunk then closes stream

---

### 4. `tools/relay/server.js` (new)

Minimal Node.js HTTP server (stdlib only, no framework).

```js
// POST /query { message, session_id }
// → spawns: claude -p --output-format stream-json [--resume <session_id>]
//           with message passed via stdin
// → forwards text chunks as SSE to Flutter as they arrive
// → extracts session_id from 'result' event, sends 'done' SSE event
```

Key implementation details:
- Response: `Content-Type: text/event-stream` (SSE)
- Use `child_process.spawn` — avoids shell injection, handles long output
- Pass message via **stdin** to avoid shell escaping issues
- `--output-format stream-json` produces newline-delimited JSON events as Claude runs:
  - `{"type":"assistant","message":{"content":[{"type":"text","text":"..."}]}}` → forward as `data: {"type":"text","text":"..."}`
  - `{"type":"result","session_id":"..."}` → forward as `data: {"type":"done","session_id":"..."}` and end response
  - Tool use/result events are silently consumed (not forwarded — Claude handles them internally)
- Working directory: `process.env.RELAY_CWD` or `process.cwd()`
- Port: `process.env.PORT || 9090`
- Logs startup errors if `claude` is not in PATH

**Auth (required for internet exposure):**
- Read `RELAY_SECRET` from env var
- If set, reject requests without `Authorization: Bearer <RELAY_SECRET>` with HTTP 401
- If not set, accept all requests (localhost-only use)

**Internet exposure options (documented in `tools/relay/README.md`):**

| Option | Setup | Pros | Cons |
|--------|-------|------|------|
| ngrok | `ngrok http 9090` | Free, instant | URL changes on restart (free tier) |
| Cloudflare Tunnel | `cloudflared tunnel` | Free, stable hostname | More setup |
| Tailscale | Install + `100.x.x.x:9090` | Stable hostname, no open port | Requires Tailscale on phone too |
| VPS | Deploy to Fly.io / Railway | Always on | Requires server + Claude Code on VPS |

Recommended: **Cloudflare Tunnel** (free, stable subdomain that doesn't change on restart).

`tools/relay/package.json`: minimal, no dependencies.

---

### 5. `lib/services/evenai.dart` (modify)

**a) Add session + silence detection state (class fields):**
```dart
final ClaudeSession _session = ClaudeSession();
Timer? _silenceTimer;
DateTime _lastTranscriptChange = DateTime.now();
static const int silenceThresholdSecs = 2;
```

**b) Update `startListening()` — add silence auto-stop:**
```dart
void startListening() {
  combinedText = '';
  _lastTranscriptChange = DateTime.now();
  _eventSpeechRecognizeChannel.listen((event) {
    final txt = event["script"] as String;
    if (txt != combinedText) {
      combinedText = txt;
      _lastTranscriptChange = DateTime.now();
    }
  }, onError: (error) => print("Error in event: $error"));

  _silenceTimer?.cancel();
  _silenceTimer = Timer.periodic(Duration(seconds: 1), (_) {
    if (!isReceivingAudio) { _silenceTimer?.cancel(); return; }
    final silent = DateTime.now().difference(_lastTranscriptChange).inSeconds;
    if (silent >= silenceThresholdSecs && combinedText.isNotEmpty) {
      _silenceTimer?.cancel();
      recordOverByOS();
    }
  });
}
```

**c) Replace DeepSeek API call in `recordOverByOS()` (~line 149):**
```dart
// Dispatch to relay (primary) or direct API (fallback)
Stream<String> textStream;
try {
  textStream = CoworkRelayService().queryStream(combinedText, _session);
  _session.isOffline = false;
} on RelayAuthException {
  startSendReply('Relay auth failed. Check secret token in settings.');
  isEvenAISyncing.value = false;
  return;
} on RelayOfflineException {
  _session.isOffline = true;
  textStream = ApiClaudeService().streamChatRequest(combinedText, _session);
}

isEvenAISyncing.value = false;
final fullAnswer = await startStreamingReply(textStream);
_session.addUser(combinedText);
_session.addAssistant(fullAnswer);
saveQuestionItem(combinedText, fullAnswer);
updateDynamicText('$combinedText\n\n$fullAnswer');
```

**d) New method `startStreamingReply(Stream<String>)` in `evenai.dart`:**

**Phase 1 — Live streaming (typewriter effect):**
Accumulates chunks and updates the glasses display every ~250ms with the **last 5 lines** of accumulated text. The user sees text appearing and scrolling in real time. No paging during this phase — it's a live window into the current response tail.

A debounce timer + in-flight flag prevents BLE queue buildup (BLE round-trip is ~400-500ms, so we skip an update if the previous one hasn't completed):

```dart
String _streamAccumulated = '';
bool _streamSendInFlight = false;
Timer? _streamDebounce;

Future<String> startStreamingReply(Stream<String> textStream) async {
  _currentLine = 0;
  list = [];
  _streamAccumulated = '';
  _streamSendInFlight = false;

  await for (final chunk in textStream) {
    if (!isRunning) break;
    _streamAccumulated += chunk;

    // Debounce: schedule a display update 250ms after last chunk
    _streamDebounce?.cancel();
    _streamDebounce = Timer(Duration(milliseconds: 250), () async {
      if (_streamSendInFlight || !isRunning) return;
      _streamSendInFlight = true;

      final tag = _session.isOffline ? '[OFFLINE] ' : '';
      // Must run on UI thread — safe here (main isolate)
      final lines = EvenAIDataMethod.measureStringList(
          tag + _streamAccumulated);

      // Always show the LAST 5 lines — typewriter scrolling effect
      final tail = lines.length <= 5 ? lines : lines.sublist(lines.length - 5);
      final display = tail.map((l) => '$l\n').join();
      await sendEvenAIReply(display, 0x01, 0x30, 0);

      _streamSendInFlight = false;
    });
  }

  // Wait for any pending debounce to fire and complete
  _streamDebounce?.cancel();
  _streamDebounce = null;
  while (_streamSendInFlight) {
    await Future.delayed(Duration(milliseconds: 50));
  }

  // Phase 2 — stream done: hand off to normal paginated display
  final tag = _session.isOffline ? '[OFFLINE] ' : '';
  list = EvenAIDataMethod.measureStringList(tag + _streamAccumulated);
  await startSendReply(tag + _streamAccumulated); // existing paging logic
  return _streamAccumulated;
}
```

**Phase 2 — Paginated review:**
After streaming ends, `startSendReply()` (existing method) takes over with the full response text. The user can now navigate pages with single-tap L/R. This reuses all existing pagination logic unchanged.

**Note:** `EvenAIDataMethod.measureStringList()` is called on the main isolate throughout — safe because `recordOverByOS` is always invoked from a BLE event on the main thread, and `await for` preserves the zone.

**e) Add to `clear()`:**
```dart
_streamDebounce?.cancel();
_streamDebounce = null;
_streamSendInFlight = false;
_streamAccumulated = '';
```

**e) Add to `clear()`:**
```dart
_session.reset();
_silenceTimer?.cancel();
_silenceTimer = null;
```

**f) Add `resetSession()` (for triple-tap):**
```dart
void resetSession() {
  _session.reset();
  startSendReply('Session reset');
}
```

---

### 6. `lib/ble_manager.dart` (modify)

**`case 0:` (double-tap) becomes recording toggle:**
```dart
case 0:
  if (EvenAI.get.isReceivingAudio) {
    // double-tap while recording → stop and send
    EvenAI.get.recordOverByOS();
  } else if (!EvenAI.get.isRunning) {
    // double-tap while idle → start recording
    EvenAI.get.toStartEvenAIByOS();
  } else {
    // double-tap while displaying → exit (existing App.get.exitAll())
    App.get.exitAll();
  }
  break;
```

**`case 1:` (single tap) — page navigation only (no change to existing logic):**
```dart
case 1:
  if (res.lr == 'L') EvenAI.get.lastPageByTouchpad();
  else EvenAI.get.nextPageByTouchpad();
  break;
```

**Triple-tap (cases 4 & 5) — reset session:**
```dart
case 4:
case 5:
  EvenAI.get.resetSession();
  break;
```

---

### 7. `lib/views/settings_page.dart` (new)

Simple `StatefulWidget` reachable from `FeaturesPage`. All values persisted via `shared_preferences`.

| Field | Type | Default |
|-------|------|---------|
| Anthropic API key | Password text field | env var |
| Relay URL | Text field | `http://localhost:9090` |
| Relay secret token | Password text field | _(empty = no auth)_ |
| Silence threshold (s) | Slider 1–5 | `2` |

On save: update `shared_preferences` + reload values in `EvenAI` instance.

**Relay URL can be any HTTP/HTTPS URL** — localhost for home use, or a public tunnel URL when away.

---

### 8. `pubspec.yaml` (modify)

```yaml
dependencies:
  shared_preferences: ^2.3.0   # add this line
```

---

## Notification System

### Overview

Replace the manual demo notification sender with an automatic system that intercepts real phone notifications and forwards them to the glasses.

The existing BLE protocol for notifications is already implemented in `Proto.sendNotify()` and `Proto.sendNewAppWhiteListJson()` — the demo page just triggered these manually. The missing piece is the native notification listener that fires automatically.

### Architecture

```
iOS/Android notification arrives
  ↓ native NotificationListenerService / UNUserNotificationCenter
  ↓ MethodChannel / EventChannel → Flutter
  ↓ NotificationService (filter by whitelist)
  ↓ Proto.sendNotify() → BLE → G1 glasses display
```

### Native layer (existing or to be wired up)

**Android:** `NotificationListenerService` — the whitelist concept in the existing demo code implies this is already scaffolded in the native Android layer. Needs an `EventChannel` wired to Flutter to deliver incoming notifications.

**iOS:** `UNUserNotificationCenterDelegate` or a notification service extension. More restricted than Android — only foreground notifications can be intercepted without an extension.

Both platforms: emit notification events to Flutter via `EventChannel('eventNotificationReceive')`, delivering a map of `{appId, appName, title, body, timestamp}`.

### `lib/services/notification_service.dart` (new)

```dart
class NotificationService {
  static NotificationService? _instance;
  static NotificationService get get => _instance ??= NotificationService._();
  NotificationService._();

  static const _eventChannel = EventChannel('eventNotificationReceive');
  List<String> _whitelist = []; // app identifiers

  void startListening() {
    _loadWhitelist();
    _eventChannel.receiveBroadcastStream().listen((event) {
      final notify = NotifyModel.fromMap(event);
      if (notify == null) return;
      if (_whitelist.isEmpty || _whitelist.contains(notify.appIdentifier)) {
        _forwardToGlasses(notify);
      }
    });
  }

  Future<void> _forwardToGlasses(NotifyModel notify) async {
    if (!BleManager.get().isConnected) return;
    await Proto.sendNotify(notify.toMap(), _nextNotifyId());
  }

  Future<void> setWhitelist(List<String> appIds) async {
    _whitelist = appIds;
    await _saveWhitelist();
    if (BleManager.get().isConnected) {
      final model = NotifyWhitelistModel(
          appIds.map((id) => NotifyAppModel(id, id)).toList());
      await Proto.sendNewAppWhiteListJson(model.toJson());
    }
  }
}
```

### `lib/models/notify_model.dart` (moved)

Move `notify_model.dart` from `lib/views/features/notification/` to `lib/models/`. No code changes — just relocating to the right layer. Update all imports.

### `lib/views/notification_settings_page.dart` (new)

Simple settings page for managing the notification whitelist:

- List of whitelisted app IDs (editable)
- "Add app" button (text field for package name / bundle ID)
- Toggle to disable notifications entirely
- "Push whitelist to glasses" button (also fires automatically on connect)

### `lib/views/features_page.dart` (modify)

Strip out BMP, Text, and Notification (demo) buttons. Replace with:
- **Settings** → `SettingsPage` (API key, relay URL, etc.)
- **Notifications** → `NotificationSettingsPage` (whitelist)

### Startup wiring (`lib/main.dart` or `BleManager._onGlassesConnected`)

On glasses connect:
1. `NotificationService.get.startListening()` — begin forwarding notifications
2. Push current whitelist to glasses via `Proto.sendNewAppWhiteListJson()`

---

## Look-Up HUD

### Overview

When the user looks up, the glasses briefly show a status line + the last Claude exchange. Auto-dismisses after 5 seconds. Designed to be glanceable — no interaction required.

```
14:32 | Listening...
─────────────────────
You: what files are in
this directory?
3 dart files, 1 pubspec,
2 asset images
```

Line 1: `HH:MM | <AI state>`
Lines 2–5: last query (truncated) + last answer (truncated), fitted to 488px width

### Prerequisite: IMU BLE command (TBD)

The G1 glasses have an IMU but the demo protocol does not document a BLE command for head gesture / accelerometer data. Before implementing, we need to discover the command via one of:

1. **BLE sniffing** — run the official Even app, use a BLE sniffer (e.g. nRF Sniffer, Wireshark + BLE adapter) to capture packets sent when tilting the head up
2. **Even Realities developer docs** — check if an SDK or extended protocol doc exists
3. **Probe undocumented commands** — the existing `default: print("Unknown Ble Event")` in `_handleReceivedData` would catch any undocumented events; log all unknown packets while using the official app

Until the command is known, `HudService` is implemented but the BLE trigger line in `ble_manager.dart` is left as a `// TODO: case <IMU_CMD>:` placeholder.

### `lib/services/hud_service.dart` (new)

```dart
class HudService {
  static HudService? _instance;
  static HudService get get => _instance ??= HudService._();
  HudService._();

  Timer? _dismissTimer;
  static const int hudDurationSecs = 5;

  Future<void> showHud(ClaudeSession session) async {
    _dismissTimer?.cancel();

    final now = TimeOfDay.now();
    final timeStr = '${now.hour.toString().padLeft(2,'0')}:${now.minute.toString().padLeft(2,'0')}';
    final stateStr = _aiStateLabel(session);
    final statusLine = '$timeStr | $stateStr';

    final lastQuery = session.lastQuery ?? '';
    final lastAnswer = session.lastAnswer ?? '';
    final body = lastQuery.isEmpty ? '' : 'You: $lastQuery\n$lastAnswer';

    final hudText = body.isEmpty ? statusLine : '$statusLine\n$body';

    // Reuse EvenAI's existing send pipeline — 0x70 = Text Show status
    await EvenAI.get.sendHudText(hudText);

    // Auto-dismiss after hudDurationSecs
    _dismissTimer = Timer(Duration(seconds: hudDurationSecs), () {
      Proto.exit();
    });
  }

  String _aiStateLabel(ClaudeSession session) {
    if (EvenAI.get.isReceivingAudio) return 'Listening...';
    if (EvenAI.isEvenAISyncing.value) return 'Thinking...';
    if (EvenAI.get.isRunning) return 'Displaying';
    if (session.relaySessionId != null) return 'Claude ready';
    return session.isOffline ? 'Offline' : 'Claude ready';
  }
}
```

### `lib/models/claude_session.dart` (add fields)

```dart
String? lastQuery;    // last question asked — shown in HUD
String? lastAnswer;   // last response — truncated in HUD
```

Set in `evenai.dart` after `recordOverByOS()` completes:
```dart
_session.lastQuery = combinedText;
_session.lastAnswer = fullAnswer;
```

### `lib/ble_manager.dart` (add IMU handler)

```dart
// TODO: replace <IMU_LOOKUP_CMD> with actual command once discovered
// case <IMU_LOOKUP_CMD>:
//   HudService.get.showHud(EvenAI.get.session);
//   break;
```

### `sendHudText()` in `evenai.dart`

Thin wrapper that sends text using the existing `0x70` (Text Show) newscreen status rather than `0x30`/`0x40` (Even AI status), so the glasses treat it as a standalone display, not part of an AI session:

```dart
Future<void> sendHudText(String text) async {
  final lines = EvenAIDataMethod.measureStringList(text);
  final display = lines.take(5).map((l) => '$l\n').join();
  await Proto.sendEvenAIData(display,
      newScreen: EvenAIDataMethod.transferToNewScreen(0x01, 0x70),
      pos: 0, current_page_num: 1, max_page_num: 1);
}
```

### Future extensibility

`HudService.showHud()` currently takes `ClaudeSession` for content. To make it context-aware later, introduce a `HudContentProvider` interface:

```dart
abstract class HudContentProvider {
  Future<String> buildHudText(ClaudeSession session);
}
```

Swap in implementations without touching `HudService`:
- `SimpleHudContentProvider` — time + last chat (current)
- `CalendarHudContentProvider` — time + next calendar event
- `LocationHudContentProvider` — time + nearby context
- `ClaudeHudContentProvider` — ask Claude for a contextual summary (relay call)

---

## Session Memory

Memory is fully owned by Claude Code on the desktop:
- First query: relay calls `claude -p --output-format json` → gets back `session_id`
- Subsequent queries: relay calls `claude -p --output-format json --resume <session_id>`
- Session files live in `~/.claude/` on the desktop
- Flutter app only stores the opaque `session_id` string
- Triple-tap resets `session_id` to null → next query starts a fresh Claude Code session

---

## Verification

1. **Double-tap-to-toggle**: double-tap → mic opens → speak → silence for 2s → auto-sends to relay
2. **Double-tap-to-stop**: double-tap → mic opens → double-tap again → immediately sends (no waiting for silence)
3. **Relay server**: `curl -X POST localhost:9090/query -d '{"message":"what is 2+2"}' -H 'Content-Type: application/json' -H 'Accept: text/event-stream'` → SSE stream with `data: {"type":"text",...}` events then `data: {"type":"done","session_id":"..."}`
4. **Session continuity**: two queries with same `session_id` → second response references first
5. **Offline fallback**: relay URL pointing at dead port → response has `[OFFLINE]` prefix
6. **Auth failure**: wrong secret token → glasses show "Relay auth failed", no fallback
7. **Session reset**: triple-tap → glasses show "Session reset"; next query has no `--resume`
8. **Live streaming display**: ask a long question → text appears word by word on glasses (debounced at 250ms); last 5 lines always visible, older lines scroll off; after stream ends switches to full paginated view
9. **E2E on device**: tap, say "what files are in this directory", 2s silence → relay running in project root → glasses display file list progressively, no `[OFFLINE]`
10. **Web search E2E**: tap, say "what is today's weather in London", 2s silence → Claude uses WebSearch → glasses show weather progressively as answer streams in
11. **Look-up HUD**: (once IMU command discovered) tilt head up → glasses show `HH:MM | Claude ready` + last exchange for 5s then auto-dismiss
