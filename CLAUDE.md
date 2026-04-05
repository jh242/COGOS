# CLAUDE.md — COGOS (Claude On Glass OS)

This file gives Claude Code the context it needs to work effectively in this repo.

---

## What this project is

An **iOS-only** Swift / SwiftUI app that turns **Even Realities G1 smart
glasses** into a wearable Claude terminal. The phone connects to the glasses
over dual BLE (one connection per arm), streams LC3 audio from the glasses
microphone, transcribes speech via the native iOS Speech framework, calls the
Claude API, and renders the reply on the glasses waveguide display.

Pure Swift / SwiftUI. iOS 14+. Bundle ID: `com.jackhu.cogos`.
stdlib + Apple frameworks only (no SPM, no CocoaPods).

---

## Tech stack

| Layer | Technology |
|-------|-----------|
| App framework | Swift / SwiftUI (iOS 14+) |
| State management | `@MainActor` ObservableObject + `@Published` + `@EnvironmentObject` |
| Concurrency | Swift actors, async/await, AsyncStream, CheckedContinuation |
| Event bus | Combine `PassthroughSubject` |
| BLE | CoreBluetooth (dual CBPeripheral, one per arm) |
| Speech-to-text | Apple Speech framework (`SFSpeechRecognizer`, on-device) |
| Audio format | LC3 codec (C sources under `COGOS/Session/lc3/`) |
| HTTP client | `URLSession` |
| AI backend | Anthropic Claude API (`api.anthropic.com/v1/messages`) |
| Local AI sessions | Claude Code CLI (`claude --print`) via Node.js relay server |

---

## Repository layout

```
COGOS/
  App/               SwiftUI @main, AppState, ContentView
  BLE/               BluetoothManager, BleRequestQueue, GestureRouter, UUIDs
  Protocol/          Proto, EvenAIProto, BmpTransfer, CRC32XZ
  Session/           EvenAISession, SpeechStreamRecognizer, TextPaginator,
                     PcmConverter, LC3 codec (C)
  API/               AnthropicClient, HaikuClient, CoworkRelayClient, SSEParser
  Glance/            GlanceService + Sources/ (location, calendar, weather,
                     news, transit, notifications)
  Platform/          NativeLocation, Settings, NotificationWhitelist
  Models/            EvenaiModel, HistoryStore
  Views/             HomeView, HistoryView, SettingsView, BleProbeView, …
  Supporting/        Info.plist, COGOS-Bridging-Header.h
tools/relay/         Node.js Claude Code relay server
docs/                Design docs
```

---

## BLE protocol essentials

### Dual-BLE architecture
The G1 has **two independent BLE connections** (left arm = `L`, right arm = `R`).
Send to L first; only send to R after L acknowledges with `0xC9`.
`BleRequestQueue.sendBoth(_:)` and `.requestList(_:)` handle this sequencing.

### Key commands

| Direction | Command | Meaning |
|-----------|---------|---------|
| App → Glasses | `0x0E 0x01` | Enable right mic |
| App → Glasses | `0x0E 0x00` | Disable mic |
| App → Glasses | `0x4E ...` | Send AI result / text page |
| App → Glasses | `0x25 ...` | Heartbeat (every 8s) |
| App → Glasses | `0x15/0x20/0x16` | BMP upload / finish / CRC |
| App → Glasses | `0x04 ...` | Notification whitelist JSON |
| App → Glasses | `0x4B ...` | Notify push |
| App → Glasses | `0x18` | Exit to dashboard |
| App → Glasses | `0x0B angle 0x01` | Head-up angle threshold |
| Glasses → App | `0xF1 seq data` | LC3 audio chunk |
| Glasses → App | `0xF5 0x17` | Long-press: start Even AI |
| Glasses → App | `0xF5 0x18` | Stop recording |
| Glasses → App | `0xF5 0x01` | Single tap (page turn) |
| Glasses → App | `0xF5 0x02` | Head-up |
| Glasses → App | `0xF5 0x04/05` | Triple tap (mode cycle) |
| Glasses → App | `0xF5 0x20` | Double-tap exit |

### Display constraints
- Max width: **488 px**
- Font size: **21 px**
- Lines per screen: **5**
- Text is paginated by `TextPaginator` using
  `NSAttributedString.size(withAttributes:)` — not a naive character count.

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

## Even AI session lifecycle (EvenAISession.swift)

```
[Long-press L]  → 0xF5 0x17
  → toStartEvenAIByOS()
     → proto.micOn()                 ← sends 0x0E 0x01 to R
     → speech.startRecognition()     ← AsyncStream<String>
     → silence timer + 30s timeout
[Release]       → 0xF5 0x18
  → recordOverByOS()
     → proto.micOff()
     → strip wake word from transcript
     → try CoworkRelayClient (if cowork mode + relay configured)
     → fall back to AnthropicClient on RelayError.offline
     → TextPaginator → startSendReply() via 0x4E pages
[Double-tap]    → 0xF5 0x20 → appState.exitAll() + session.clear()
```

---

## Anthropic API (AnthropicClient.swift)

`POST https://api.anthropic.com/v1/messages`

Headers:
```
x-api-key: <ANTHROPIC_API_KEY>
anthropic-version: 2023-06-01
content-type: application/json
```

Models: `claude-sonnet-4-6` (main), `claude-haiku-4-5-20251001` (glance ranking).
Uses `URLSession.bytes(for:)` on iOS 15+, falls back to `data(for:)` on iOS 14.
SSE parsed by `SSEParser.swift`.

---

## Session modes

| Mode | Trigger | System prompt focus | History |
|------|---------|---------------------|---------|
| `chat` | default | Concise general answers | Per-session |
| `code` | triple-tap L | Expert programmer, plain text code | Per-session |
| `cowork` | triple-tap R | Pair-programming, persistent context | Persisted |

Mode is shown in every page header: `[CHAT]`, `[CODE]`, `[WORK]`.

---

## Wake word

- Phrases detected client-side in the partial STT transcript.
- Default list: `["hey claude", "ok claude", "claude"]`
- Wake phrase is stripped from the query before sending to the API.

---

## Cowork relay (Claude Code integration)

For `cowork` mode the app optionally delegates to a local relay that spawns
`claude --print` CLI processes.

```
iOS app  ──POST /query──►  relay (localhost:9090)
                            └─ claude --print "<msg>"
                            ◄── streamed SSE response
```

Relay lives in `tools/relay/server.js`. If unreachable, falls through to the
direct Anthropic API.

---

## Conventions and gotchas

- Always send L before R. Use `BleRequestQueue.sendBoth(_:)`.
- `Proto.sendEvenAIData(...)` assembles 0x4E packets — don't hand-roll.
- `TextPaginator` runs on `@MainActor` because it touches UIKit text metrics.
- Actor isolation: `Proto` and `BleRequestQueue` are actors; call with `await`.
- `EvenAISession.clear()` resets all state — call on every exit path.
- Retry loops in `sendEvenAIReply` are intentional; don't remove them.
- API keys live in `UserDefaults` via `Settings.swift` or Xcode scheme env;
  never commit them.

---

## Running the app

No `.xcodeproj` is committed. See [`COGOS/README.md`](COGOS/README.md) to
create one in Xcode, drag in `COGOS/`, set the bridging header
(`COGOS/Supporting/COGOS-Bridging-Header.h`), use
`COGOS/Supporting/Info.plist`, and enable Background Modes → Uses Bluetooth
LE accessories. Requires a physical iOS device (BLE cannot be simulated).

## Running the cowork relay

```bash
cd tools/relay
npm install
ANTHROPIC_API_KEY=sk-ant-... node server.js
```

---

## Key files to read before making changes

1. `COGOS/Session/EvenAISession.swift` — session orchestrator
2. `COGOS/BLE/BluetoothManager.swift` — dual-BLE transport + packet bus
3. `COGOS/BLE/BleRequestQueue.swift` — request/response + sendBoth sequencing
4. `COGOS/Protocol/Proto.swift` — command helpers, packet assemblers
5. `COGOS/Protocol/EvenAIProto.swift` — 0x4E multi-packet format
6. `COGOS/App/AppState.swift` — top-level wiring
