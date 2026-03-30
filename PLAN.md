# G1 Claude Terminal — Implementation Plan

## Vision

Turn the Even Realities G1 glasses into a wearable Claude terminal.
Long-press the left TouchBar → say "Hey Claude" (or any query) → glasses display
the response streamed from Claude.  The phone app bridges BLE ↔ Claude API and
maintains persistent conversation sessions (chat, code, cowork).

---

## Phase 0 — Foundation (done / already in repo)

| Item | File | Status |
|------|------|--------|
| Dual-BLE manager | `lib/ble_manager.dart` | ✅ |
| TouchBar event routing | `lib/ble_manager.dart:154` | ✅ |
| LC3 mic open/close | `lib/services/proto.dart` | ✅ |
| Native speech-to-text bridge | `EventChannel(eventSpeechRecognize)` | ✅ |
| Paginated text → glasses | `lib/services/evenai.dart` | ✅ |
| DeepSeek/Qwen API call | `lib/services/api_services_deepseek.dart` | ✅ |
| History list UI | `lib/views/even_list_page.dart` | ✅ |

---

## Phase 1 — Claude API Backend

### 1.1  New service: `lib/services/api_claude_service.dart`

Replace `ApiDeepSeekService` with an Anthropic-native service.

```
POST https://api.anthropic.com/v1/messages
Headers:
  x-api-key: $ANTHROPIC_API_KEY
  anthropic-version: 2023-06-01
  content-type: application/json

Body:
{
  "model": "claude-sonnet-4-6",
  "max_tokens": 1024,
  "system": "<system prompt per mode>",
  "messages": [<conversation history>]
}
```

- Store API key via `--dart-define=ANTHROPIC_API_KEY=sk-ant-...`
- Return `content[0].text` from the response.
- On error surface the HTTP status / error_type to the glasses display.

### 1.2  Wire into `EvenAI.recordOverByOS()`

```dart
// lib/services/evenai.dart  ~line 149
final apiService = ApiClaudeService(mode: _currentMode, history: _history);
String answer = await apiService.sendChatRequest(combinedText);
_history.addUser(combinedText);
_history.addAssistant(answer);
```

### 1.3  Add `pubspec.yaml` dependency

```yaml
dependencies:
  http: ^1.2.1   # lighter than dio for a single endpoint
```

Or keep `dio` — both work.

---

## Phase 2 — Wake Word ("Hey Claude")

The native layer already streams speech recognition text in real time via
`EventChannel(eventSpeechRecognize)`.  We intercept the partial transcript
**before** the long-press is released.

### Strategy

1. In `EvenAI.startListening()`, track partial transcript.
2. If transcript contains a wake phrase (`hey claude`, `ok claude`, `claude`),
   set `_wakeWordDetected = true`.
3. In `recordOverByOS()`, if `!_wakeWordDetected`, skip the API call and send a
   short "Listening… say 'Hey Claude'" prompt to the glasses instead.
4. Strip the wake phrase from the query before sending to the API.

### Wake phrases (configurable list)

```dart
static const List<String> _wakePhrases = [
  'hey claude',
  'ok claude',
  'claude',
];
```

### Alternative / fallback: gesture-based modes

| Gesture | Event | Action |
|---------|-------|--------|
| Long-press left | `0xF5 0x17` | Start Even AI (existing) |
| Triple-tap left | `0xF5 0x04` | Cycle mode: Chat → Code → Cowork |
| Triple-tap right | `0xF5 0x05` | Open new cowork session |
| Double-tap | `0xF5 0x00` | Exit (existing) |

Display the current mode in the top-right corner of the glasses HUD on every
page (e.g., `[CHAT]`, `[CODE]`, `[WORK]`).

---

## Phase 3 — Session Modes

### 3.1  Mode enum

```dart
enum ClaudeMode { chat, code, cowork }
```

### 3.2  System prompts per mode

**Chat**
```
You are a helpful assistant running on smart glasses.
Be concise — each reply should fit 5 lines of 488px width at font-size 21.
Prefer short paragraphs. No markdown except for code blocks.
```

**Code**
```
You are an expert programmer. Answers must be concise.
For code, use plain text — no markdown fences. Indent with 2 spaces.
Max 5 lines visible at once; break long solutions into numbered steps.
```

**Cowork (Claude Code integration)**
```
You are a senior software engineer pair-programming with the user.
Maintain context across turns. Reference previous messages by topic.
When asked to write code, produce complete, runnable snippets.
Prefer explaining changes before showing code.
```

### 3.3  Conversation history model

```dart
// lib/models/claude_session.dart
class ClaudeSession {
  final ClaudeMode mode;
  final List<Map<String, String>> messages; // [{role, content}, ...]
  final DateTime createdAt;

  void addUser(String text)      => messages.add({'role':'user',    'content':text});
  void addAssistant(String text) => messages.add({'role':'assistant','content':text});
  void clear() => messages.clear();

  // Cap history at N turns to stay within token budget
  static const int maxTurns = 20;
}
```

- **Chat**: history cleared on double-tap exit.
- **Code**: history cleared on exit.
- **Cowork**: history persists across BLE reconnects (saved to local storage via
  `shared_preferences`).

---

## Phase 4 — Claude.ai / Claude Code Connectivity

### 4.1  Direct API (all modes)

The `ApiClaudeService` calls `api.anthropic.com` directly from the phone.
No server-side proxy needed for chat and code modes.

### 4.2  Claude Code bridge (cowork mode)

For real cowork sessions the glasses relay queries to a **Claude Code daemon**
running on the user's workstation:

```
G1 Glasses
    ↕ BLE
Flutter App (phone)
    ↕ HTTPS / WebSocket
Cowork Relay Server (laptop/desktop)
    ↕ stdin/stdout
claude --print "<query>"        ← Claude Code CLI
    ↕
Claude API
```

**Relay server** (minimal Node.js or Python script, runs locally):

```
POST /query   { session_id, message }
→ spawns: claude --print --session <id> "<message>"
→ returns streamed text
```

The Flutter app posts to `http://localhost:PORT/query` (or a tunnelled URL if
on mobile data).  The relay server manages session files so cowork history
survives across glass disconnections.

Configuration in app settings:
- Relay URL (default: `http://localhost:9090`)
- Session ID (auto-generated UUID per cowork session)
- Fallback: direct API if relay unreachable

---

## Phase 5 — Display & UX Polish

### 5.1  Status indicators on glasses

Every page packet prepends a 1-line header:

```
[CHAT] Hey Claude ───────────
<response line 1>
<response line 2>
...
```

Header is built in `startSendReply()` before calling `EvenAIDataMethod.measureStringList()`.

### 5.2  Streaming feel (progressive display)

Claude API supports streaming (`stream: true`).  Implement a chunked update:

1. Send first 5 lines as soon as they are assembled from the stream.
2. Continue appending lines as stream arrives.
3. Auto-page at `interval` seconds (existing timer, keep as-is).

### 5.3  Input confirmation

After speech-to-text but before API call, flash the recognised query on the
glasses for 2 seconds:

```
You said:
"<combinedText>"
──────────────
Thinking…
```

This lets the user double-tap to cancel if misrecognised.

### 5.4  Error states

| Condition | Glasses display |
|-----------|-----------------|
| No wake word detected | `Say "Hey Claude" to start` |
| Network error | `Network error. Check connection.` |
| API auth error | `API key invalid. Check settings.` |
| Cowork relay down | `Relay offline. Using direct API.` |
| Empty transcript | `No speech detected.` |

---

## Phase 6 — Settings UI

Add a settings screen reachable from the existing `FeaturesPage`:

| Setting | Type | Default |
|---------|------|---------|
| Anthropic API key | password field | env var |
| Default mode | dropdown | Chat |
| Wake phrases | editable list | hey claude, claude |
| Require wake word | toggle | true |
| Pages per screen | slider 3-5 | 5 |
| Font size | slider 16-28 | 21 |
| Auto-page interval (s) | slider 3-10 | 5 |
| Cowork relay URL | text field | http://localhost:9090 |
| Keep cowork history | toggle | true |

---

## File Structure (new / changed files)

```
lib/
  models/
    claude_session.dart          ← NEW: session + history model
  services/
    api_claude_service.dart      ← NEW: Anthropic API client
    cowork_relay_service.dart    ← NEW: Claude Code relay client
    evenai.dart                  ← MODIFIED: wire Claude, wake word, modes
  views/
    settings_page.dart           ← NEW: settings UI
    features/
      mode_indicator_widget.dart ← NEW: [CHAT]/[CODE]/[WORK] badge
  ble_manager.dart               ← MODIFIED: triple-tap → mode cycle

tools/
  relay/
    server.js                    ← NEW: local Claude Code relay (Node.js)
    README.md                    ← NEW: relay setup instructions

CLAUDE.md                        ← NEW: AI context for this repo
README.md                        ← UPDATED: Claude terminal vision
PLAN.md                          ← this file
```

---

## Implementation Order

1. `api_claude_service.dart` + wire into `evenai.dart` — replace DeepSeek backend
2. `claude_session.dart` + history in `evenai.dart` — multi-turn context
3. Wake word detection in `startListening()` / `recordOverByOS()`
4. Triple-tap mode switching + mode header on glasses display
5. `settings_page.dart` — key, mode, wake phrase config
6. Streaming display (progressive 5-line updates)
7. `cowork_relay_service.dart` + `tools/relay/server.js`
8. Input confirmation flash before API call
9. Persistent cowork history (`shared_preferences`)
10. Full E2E test on device

---

## Open Questions / Decisions Needed

- **Wake word library**: On-device (e.g., `porcupine` Flutter plugin for
  "Hey Claude") vs. STT prefix match.  Porcupine requires a custom wake word
  trained model; STT prefix is simpler but fires only after release.
- **Streaming on glasses**: The 0x4E protocol is packet-based.  True streaming
  requires buffering partial lines client-side — confirm acceptable latency.
- **Cowork relay auth**: Should the relay accept connections only from localhost,
  or support a bearer token for remote access?
- **Cowork session persistence**: SQLite vs. `shared_preferences` vs. flat JSON
  file for conversation history.
- **iOS vs Android mic path**: The existing native bridge handles LC3 decode and
  STT differently per platform — confirm wake word intercept works on both.
