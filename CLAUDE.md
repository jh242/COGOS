# CLAUDE.md — COGOS (Claude On Glass OS)

This file gives Claude Code the context it needs to work effectively in this repo.

---

## What this project is

An **iOS-only** Swift / SwiftUI app that turns **Even Realities G1 smart
glasses** into a wearable AI terminal. The phone connects to the glasses
over dual BLE (one connection per arm), streams LC3 audio from the glasses
microphone, transcribes speech via the native iOS Speech framework, and
sends the transcript either to a remote Hermes Agent or to an on-device
SwiftAgent loop over OpenRouter. Replies stream (Hermes) or land as a
finished page (OpenRouter) on the glasses waveguide via the firmware-native
0x54 TEXT command.

Pure Swift / SwiftUI. iOS 26+. Bundle ID: `com.jackhu.cogos`.

---

## Tech stack

| Layer | Technology |
|-------|-----------|
| App framework | Swift / SwiftUI (iOS 26+) |
| State management | `@MainActor` ObservableObject + `@Published` + `@EnvironmentObject` |
| Concurrency | Swift actors, async/await, AsyncStream, CheckedContinuation |
| Event bus | Combine `PassthroughSubject` |
| BLE | CoreBluetooth (dual CBPeripheral, one per arm) |
| Speech-to-text | Apple Speech framework (`SFSpeechRecognizer`, on-device) |
| Audio format | LC3 codec (C sources under `COGOS/Session/lc3/`) |
| HTTP client | `URLSession` |
| AI backend | Hermes Responses API, or on-device SwiftAgent → OpenRouter Responses API |

---

## Repository layout

```
COGOS/
  App/               SwiftUI @main, AppState, ContentView
  BLE/               BluetoothManager, BleRequestQueue, GestureRouter, UUIDs
  Protocol/          Proto, EvenAIText54, DashboardProto, QuickNoteProto, CRC32XZ
  Session/           EvenAISession, SpeechStreamRecognizer,
                     PcmConverter, LC3 codec (C)
  API/               HermesClient, OpenRouterClient, SSEParser
  Agent/             OpenRouter SwiftAgent session, calendar/weather/location tools
  Glance/            GlanceService + Sources/ (location, calendar, weather,
                     news, transit, notifications)
  Platform/          NativeLocation, Settings, NotificationWhitelist
  Models/            EvenaiModel, HistoryStore
  Views/             HomeView, HistoryView, SettingsView, BleProbeView, …
  Supporting/        Info.plist, COGOS-Bridging-Header.h
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
| App → Glasses | `0x54 ... 02 ...` | AI text: prepare (one per reply) |
| App → Glasses | `0x54 ... 03 ...` | AI text: cumulative update (chunked) |
| App → Glasses | `0x25 ...` | Heartbeat (every 8s) |
| App → Glasses | `0x04 ...` | Notification whitelist JSON |
| App → Glasses | `0x4B ...` | Notify push |
| App → Glasses | `0x18` | Exit to dashboard |
| App → Glasses | `0x0B angle 0x01` | Head-up angle threshold |
| Glasses → App | `0xF1 seq data` | LC3 audio chunk |
| Glasses → App | `0xF5 0x17` | Long-press: start Even AI |
| Glasses → App | `0xF5 0x18` | Stop recording |
| Glasses → App | `0xF5 0x01` | Single tap (firmware paginates; ignore) |
| Glasses → App | `0xF5 0x02` | Head-up |
| Glasses → App | `0xF5 0x04/05` | Triple tap (mode cycle) |
| Glasses → App | `0xF5 0x20` | Double-tap exit |

### 0x54 TEXT streaming (firmware-native)

12-byte header followed by UTF-8 text (text packets only):
```
0:  0x54
1:  total length (header + payload)
2:  0x00
3:  seq (per logical message; all chunks share it)
4:  sub  — 0x02 prepare, 0x03 text
5:  chunk_count
6:  0x00
7:  chunk_index (1-based)
8:  0x00
9:  scroll flag — 0x00 during streaming + initial "done" re-send;
                 0x01 on phone-driven scroll-position updates (post-done)
10: 0x00
11: status byte —
      prepare:   0x00
      streaming: 0xFF (firmware pins viewport to the bottom)
      complete:  0x64 (100; final re-send — this is what enables the
                 firmware's native single-tap scroll viewer; without it
                 the display stays locked to the last 3 lines)
      0x00..0x64 scroll-position percentage when byte 9 = 0x01
12+: UTF-8 (sub=0x03 only)
```

Each reply: one prepare, then cumulative text updates (every update carries
the full answer so far, status=0xFF). After the last streaming update, send
one more cumulative update with status=0x64 — firmware then hands the text
to its scrollable viewer and single-tap scroll starts working.
Max payload per chunk: 100 bytes. ACK: `54 0A 00 <seq> <sub> <count> 00 <idx> 00 C9`.

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
     → Hermes: settings.makeHermesClient().streamResponse(...)
       or OpenRouter: OpenRouterSpokenAgent.respond(to:) then pushReply
     → proto.sendEvenAITextPrepare() then proto.sendEvenAIText(...)
[Double-tap]    → 0xF5 0x20 → appState.exitAll() + session.clear()
```

---

## Hermes API (`HermesClient.swift`)

The app is a thin client for `POST /v1/responses`. It sends the final speech
transcript, a stable named conversation, and a short display-format hint.
Hermes owns prompts, model selection, memory, tools, skills, and tool loops.
The app ignores tool-progress events and renders only cumulative final-text
snapshots. Glance providers remain local and are never uploaded to Hermes.

The HTTPS endpoint is stored in `UserDefaults`; the bearer token is stored in
Keychain. Scheme overrides are `HERMES_API_URL` and `HERMES_API_KEY`.

---

## OpenRouter spoken agent (`COGOS/Agent/`)

Settings can point spoken questions at OpenRouter instead of Hermes. COGOS
embeds SwiftedMind SwiftAgent (`OpenAISession`) with `store: false` and the
full transcript on every `POST /v1/responses` (OpenRouter is stateless).
Client tools wrap EventKit / WeatherKit / `NativeLocation` / IMAP mail
(SwiftMail `IMAPServer`) / OpenRouter web search. The glasses get
`respond()`'s final text via `EvenTextRenderer.pushReply` — not token
streaming and never tool JSON. Transcript trim keeps the last 12 user
prompts, dropping oldest turns from the front.

The OpenRouter key is the same Keychain item as the news digest
(`OPENROUTER_API_KEY`). Agent model is `OPENROUTER_AGENT_MODEL` / Settings
(default `google/gemini-2.5-flash`). News digest still uses cheap
`chat/completions`. Glance payloads are never uploaded. Mail uses SwiftMail
over TLS IMAP (iCloud `imap.mail.me.com:993`); the password lives in Keychain
(`IMAP_PASSWORD` / Settings), never in git.

---

## Conventions and gotchas

- Always send L before R. `BleRequestQueue.sendBoth(_:)` handles it; `Proto`
  streaming methods send L→R per chunk serially.
- `Proto.sendEvenAITextPrepare()` + `Proto.sendEvenAIText(_:)` — don't
  hand-roll 0x54 headers; use `EvenAIText54` encoder.
- Each AI reply is one prepare + N cumulative text updates. Firmware owns
  pagination; phone never splits into pages.
- Actor isolation: `Proto` and `BleRequestQueue` are actors; call with `await`.
- `EvenAISession.clear()` resets all state — call on every exit path.
- The Hermes token lives in Keychain or `HERMES_API_KEY`; never commit it.
- The OpenRouter key lives in Keychain or `OPENROUTER_API_KEY`; never commit it.

---

## Running the app

No `.xcodeproj` is committed. See [`COGOS/README.md`](COGOS/README.md) to
create one in Xcode, drag in `COGOS/`, set the bridging header
(`COGOS/Supporting/COGOS-Bridging-Header.h`), use
`COGOS/Supporting/Info.plist`, and enable Background Modes → Uses Bluetooth
LE accessories. Requires a physical iOS device (BLE cannot be simulated).

## Key files to read before making changes

1. `COGOS/Session/EvenAISession.swift` — session orchestrator
2. `COGOS/BLE/BluetoothManager.swift` — dual-BLE transport + packet bus
3. `COGOS/BLE/BleRequestQueue.swift` — request/response + sendBoth sequencing
4. `COGOS/Protocol/Proto.swift` — command helpers, packet assemblers
5. `COGOS/Protocol/EvenAIText54.swift` — 0x54 streaming text encoder
6. `COGOS/API/HermesClient.swift` — Hermes Responses API transport
7. `COGOS/Agent/OpenRouterSpokenAgent.swift` — on-device OpenRouter tool loop
8. `COGOS/App/AppState.swift` — top-level wiring
