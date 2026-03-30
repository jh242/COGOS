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

## Files to Create / Modify

| File | Action | Purpose |
|------|--------|---------|
| `lib/services/cowork_relay_service.dart` | **CREATE** | HTTP client for the desktop relay |
| `lib/services/api_claude_service.dart` | **CREATE** | Fallback direct Anthropic API client |
| `lib/models/claude_session.dart` | **CREATE** | Holds relay session ID + offline flag |
| `lib/services/evenai.dart` | **MODIFY** | Replace DeepSeek, tap-to-toggle, silence detection, dispatch |
| `lib/ble_manager.dart` | **MODIFY** | Tap = state-aware toggle; triple-tap = reset session |
| `lib/views/settings_page.dart` | **CREATE** | API key, relay URL, secret token config |
| `tools/relay/server.js` | **CREATE** | Node.js relay: spawns `claude -p` subprocess |
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

Accumulates streamed text chunks, measures lines on the UI thread, and sends pages to the glasses progressively. Returns the full assembled answer string when the stream ends.

```dart
Future<String> startStreamingReply(Stream<String> textStream) async {
  _currentLine = 0;
  list = [];
  String accumulated = '';
  bool firstPageSent = false;

  await for (final chunk in textStream) {
    if (!isRunning) break;
    accumulated += chunk;

    // Measure on UI thread — must not be called from an isolate
    list = EvenAIDataMethod.measureStringList(
        _session.isOffline ? '[OFFLINE] $accumulated' : accumulated);

    // Send first page as soon as 5 lines are ready
    if (!firstPageSent && list.length >= 5) {
      final page = list.sublist(0, 5).map((l) => '$l\n').join();
      await sendEvenAIReply(page, 0x01, 0x30, 0);
      firstPageSent = true;
    }
  }

  // Stream done — send final state with 0x40 (display complete)
  if (list.isNotEmpty) {
    final lastLines = list.length <= 5
        ? list
        : list.sublist(list.length - (list.length % 5 == 0 ? 5 : list.length % 5));
    final lastPage = lastLines.map((l) => '$l\n').join();
    if (firstPageSent) {
      await Future.delayed(Duration(seconds: 3));
    }
    await sendEvenAIReply(lastPage, 0x01, 0x40, 0);
  }

  return accumulated;
}
```

**Note:** `EvenAIDataMethod.measureStringList()` is called directly here (UI thread guaranteed since `recordOverByOS` is triggered from a BLE event on the main isolate). The existing timer-based auto-paging (`updateReplyToOSByTimer`) is **not used** for streamed responses — paging is driven by the stream instead.

**e) Offline indicator:**
Prepend `[OFFLINE] ` to `accumulated` before measuring — handled inline in `startStreamingReply` above.

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
8. **Progressive display**: ask a long question → first page appears on glasses before Claude finishes responding; subsequent pages appear as text accumulates
9. **E2E on device**: tap, say "what files are in this directory", 2s silence → relay running in project root → glasses display file list progressively, no `[OFFLINE]`
10. **Web search E2E**: tap, say "what is today's weather in London", 2s silence → Claude uses WebSearch → glasses show weather progressively as answer streams in
