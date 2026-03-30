# CLAUDE.md — G1 Claude Terminal

This file gives Claude Code the context it needs to work effectively in this repo.

---

## What this project is

A Flutter (Dart) mobile app that turns **Even Realities G1 smart glasses** into
a wearable Claude terminal.  The phone connects to the glasses over dual BLE
(one connection per arm), streams LC3 audio from the glasses microphone, converts
speech to text via the native platform layer, calls the Claude API, and renders
the reply on the glasses waveguide display.

---

## Tech stack

| Layer | Technology |
|-------|-----------|
| App framework | Flutter / Dart (supports iOS + Android) |
| State management | GetX (`get` package) |
| HTTP client | Dio |
| BLE ↔ Flutter bridge | `MethodChannel('method.bluetooth')` + `EventChannel` |
| Speech-to-text | Native iOS/Android, exposed via `EventChannel(eventSpeechRecognize)` |
| Audio format | LC3 (Low Complexity Communication Codec) from glasses mic |
| AI backend | Anthropic Claude API (`api.anthropic.com/v1/messages`) |
| Local AI sessions | Claude Code CLI (`claude --print`) via relay server |

---

## Repository layout

```
lib/
  ble_manager.dart           # BLE send/receive, TouchBar event dispatch
  app.dart                   # App-level exit / global state
  main.dart                  # Entry point
  controllers/
    evenai_model_controller.dart  # GetX controller for history list
    bmp_update_manager.dart       # BMP image transfer state
  models/
    evenai_model.dart             # Q&A history item model
    claude_session.dart           # (NEW) Claude session + conversation history
  services/
    ble.dart                      # BleReceive data model
    proto.dart                    # Low-level BLE packet builders
    evenai.dart                   # EvenAI session lifecycle (main orchestrator)
    evenai_proto.dart             # EvenAI-specific packet helpers
    text_service.dart             # Text → BLE packet conversion
    features_services.dart        # BMP / notification helpers
    api_services.dart             # Qwen/Aliyun API (legacy, keep for reference)
    api_services_deepseek.dart    # DeepSeek API (legacy, being replaced)
    api_claude_service.dart       # (NEW) Anthropic Claude API client
    cowork_relay_service.dart     # (NEW) Claude Code relay client
  views/
    home_page.dart
    even_list_page.dart
    features_page.dart
    features/
      bmp_page.dart
      text_page.dart
      notification/
  utils/
    string_extension.dart
    utils.dart
tools/
  relay/
    server.js        # (NEW) local Claude Code relay server (Node.js)
```

---

## BLE protocol essentials

### Dual-BLE architecture
The G1 has **two independent BLE connections** (left arm = `L`, right arm = `R`).
Send to L first; only send to R after L acknowledges with `0xC9`.
`BleManager.sendBoth()` handles this sequencing.

### Key commands

| Direction | Command | Meaning |
|-----------|---------|---------|
| App → Glasses | `0x0E 0x01` | Enable right mic |
| App → Glasses | `0x0E 0x00` | Disable mic |
| App → Glasses | `0x4E ...` | Send AI result / text page |
| Glasses → App | `0xF1 seq data` | LC3 audio chunk |
| Glasses → App | `0xF5 0x17` | Long-press: start Even AI |
| Glasses → App | `0xF5 0x18` | Stop recording |
| Glasses → App | `0xF5 0x01` | Single tap (page turn) |
| Glasses → App | `0xF5 0x00` | Double tap (exit) |
| Glasses → App | `0xF5 0x04/05` | Triple tap (mode cycle) |

### Display constraints
- Max width: **488 px**
- Font size: **21 px** (configurable)
- Lines per screen: **5**
- Text is split via `EvenAIDataMethod.measureStringList()` using Flutter's
  `TextPainter` — do not replace this with a naive character count.

### 0x4E packet `newscreen` byte

```
upper 4 bits — status:
  0x30  Even AI displaying (auto mode)
  0x40  Even AI display complete (last page, auto)
  0x50  Even AI manual mode
  0x60  Network error
  0x70  Text show

lower 4 bits — action:
  0x01  Display new content
```

---

## Even AI session lifecycle

```
[Long-press L]
  → 0xF5 0x17 received
  → EvenAI.toStartEvenAIByOS()
     → startListening()       ← begins partial STT transcript
     → openEvenAIMic()        ← sends 0x0E 0x01 to R arm
[Release]
  → 0xF5 0x18 received
  → EvenAI.recordOverByOS()
     → stopEvenAI native
     → check wake word in combinedText
     → call Claude API
     → startSendReply(answer)  ← paginates & sends via 0x4E
[Double-tap]
  → 0xF5 0x00 → App.exitAll() + EvenAI.clear()
```

---

## Adding the Claude API

### Endpoint
`POST https://api.anthropic.com/v1/messages`

### Required headers
```
x-api-key: <ANTHROPIC_API_KEY>
anthropic-version: 2023-06-01
content-type: application/json
```

### Minimal request body
```json
{
  "model": "claude-sonnet-4-6",
  "max_tokens": 1024,
  "system": "...",
  "messages": [{"role":"user","content":"..."}]
}
```

### API key injection
```
flutter run --dart-define=ANTHROPIC_API_KEY=sk-ant-...
```
Access in Dart:
```dart
const String.fromEnvironment('ANTHROPIC_API_KEY', defaultValue: '')
```

---

## Session modes

| Mode | Trigger | System prompt focus | History |
|------|---------|---------------------|---------|
| `chat` | default | Concise general answers | Per-session |
| `code` | triple-tap L | Expert programmer, plain text code | Per-session |
| `cowork` | triple-tap R | Pair-programming, persistent context | Persisted |

Mode is shown in every page header sent to glasses: `[CHAT]`, `[CODE]`, `[WORK]`.

---

## Wake word

- Phrases detected client-side in the partial STT transcript.
- Default list: `['hey claude', 'ok claude', 'claude']`
- Strip the wake phrase from the query before sending to the API.
- If no wake phrase found and `requireWakeWord == true`, prompt the user on
  glasses: `Say "Hey Claude" to start`.

---

## Cowork relay (Claude Code integration)

For `cowork` mode the app optionally delegates to a local relay server instead
of calling the API directly.  The relay spawns `claude --print` CLI processes
and returns the output.

```
Flutter app  ──POST /query──►  relay (localhost:9090)
                               └─ claude --print "<msg>"
                               ◄── streamed response
```

The relay is a small Node.js script in `tools/relay/server.js`.
If the relay is unreachable, `cowork` mode falls back to direct API.

---

## Conventions and gotchas

- Always send L before R.  `BleManager.sendBoth()` is the safe wrapper.
- `Proto.sendEvenAIData()` assembles the 0x4E packet — don't build it manually.
- `EvenAIDataMethod.measureStringList()` must run on the **Flutter UI thread**
  because it uses `TextPainter`.  Do not call from an isolate.
- `isRunning` is both a bool and an `RxBool` — set it via the setter
  `EvenAI.isRunning = ...` to update both.
- `clear()` in `EvenAI` resets all state — always call it on exit paths.
- The existing `retryCount` / `maxRetry` retry loop in `sendEvenAIReply` is
  intentional; don't remove it.
- API keys must never be committed; use `--dart-define` or a `.env` approach.

---

## Running the app

```bash
# iOS
flutter run --dart-define=ANTHROPIC_API_KEY=sk-ant-... -d <ios-device>

# Android
flutter run --dart-define=ANTHROPIC_API_KEY=sk-ant-... -d <android-device>
```

Bluetooth requires a physical device — the simulator cannot test BLE.

## Running the cowork relay

```bash
cd tools/relay
npm install
ANTHROPIC_API_KEY=sk-ant-... node server.js
```

---

## Key files to read before making changes

1. `lib/services/evenai.dart` — session orchestrator, touch this carefully
2. `lib/ble_manager.dart` — BLE send/receive and TouchBar routing
3. `lib/services/proto.dart` — packet builders, understand before adding cmds
4. `lib/services/evenai_proto.dart` — EvenAI-specific packet detail
