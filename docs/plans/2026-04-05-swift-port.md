# Port COGOS to Pure Swift, Remove Flutter

## Context

COGOS is an iOS-only Flutter app that bridges Claude to Even Realities G1 smart glasses (dual BLE, LC3 audio, native STT, Claude streaming, glasses text rendering). Flutter is buying almost nothing here — the hard parts (CoreBluetooth dual-peripheral, SFSpeechRecognizer, LC3 C codec, CoreLocation) are already native Swift/C in `ios/Runner/`. The Dart layer is mostly a MethodChannel router plus business logic (session orchestration, text pagination, SSE streaming, glance ranking) that has to go through a Flutter boundary for no benefit.

Porting to pure Swift/SwiftUI removes the boundary, shrinks the binary, lets us call iOS APIs directly (EventKit, CoreLocation, MapKit, UserNotifications, SFSpeechRecognizer) without channel marshaling, and maps GetX's `Rx` reactivity onto SwiftUI's `@Observable`/`@Published` naturally.

**User decisions:** SwiftUI, replace Flutter in place at repo root, full feature parity (core loop + glance + cowork/history + utility pages), stdlib-only (no SPM packages).

**Outcome:** One SwiftUI app, iOS 14+, bundle `com.jackhu.cogos`, all Dart deleted, existing Swift/C carried forward and un-Flutterized.

---

## Strategy

**Big-bang port on a branch.** No hybrid phase — Flutter and a Swift app cannot sensibly coexist at the same bundle ID, and the MethodChannels are small enough that an incremental swap would be more work than a clean rewrite. Development happens on a branch; `main` keeps the Flutter app runnable until the Swift port reaches parity.

**Two-layer rewrite:**
1. **Keep & un-Flutterize** the native Swift/C that already exists (BluetoothManager, SpeechStreamRecognizer, LC3 codec, LocationChannel). Strip `FlutterMethodChannel` / `FlutterEventSink` references; replace with Combine publishers or delegate callbacks.
2. **Rewrite** all Dart as new Swift modules with clean module boundaries, one Swift file per logical unit (not one-per-Dart-file).

---

## Target Architecture

```
COGOS.xcodeproj/
  COGOS/
    App/
      COGOSApp.swift              # @main SwiftUI App
      AppState.swift              # top-level ObservableObject (replaces App singleton)
      ContentView.swift           # root TabView
    BLE/
      BluetoothManager.swift      # EXISTING - strip Flutter, expose Combine publishers
      GattProtocol.swift          # EXISTING - copy as-is
      ServiceIdentifiers.swift    # EXISTING - copy as-is
      BleRequestQueue.swift       # NEW - ports BleManager.request/sendBoth/requestRetry
      GestureRouter.swift         # NEW - ports BleManager._handleReceivedData (0xF5 dispatch)
    Protocol/
      Proto.swift                 # NEW - ports services/proto.dart (0x0E, 0x25, 0x4B, 0x4E, 0x0B, 0x04, 0x18, 0x34)
      EvenAIProto.swift           # NEW - ports evenai_proto.dart (0x4E multi-packet builder)
      BmpTransfer.swift           # NEW - ports bmp_update_manager.dart with CRC32-XZ
      CRC32XZ.swift               # NEW - hand-rolled CRC32 (stdlib only)
    Session/
      EvenAISession.swift         # NEW - ports services/evenai.dart (the orchestrator)
      TextPaginator.swift         # NEW - ports measureStringList using CTFramesetter
      SpeechStreamRecognizer.swift # EXISTING - strip Flutter, expose AsyncStream<String>
      PcmConverter.h/.m           # EXISTING - copy as-is
      lc3/                        # EXISTING - copy entire C codec as-is
      ClaudeSession.swift         # NEW - ports models/claude_session.dart
      SessionMode.swift           # NEW - enum: chat/code/cowork + header tags
    API/
      AnthropicClient.swift       # NEW - URLSession SSE parser for api.anthropic.com/v1/messages
      CoworkRelayClient.swift     # NEW - URLSession SSE for localhost:9090/query + fallback
      SSEParser.swift             # NEW - line buffer → event/data pair emitter (shared)
    Glance/
      GlanceService.swift         # NEW - ports glance_service.dart (Haiku ranking, cache, 60s timer)
      GlanceSource.swift          # NEW - protocol
      Sources/
        LocationSource.swift      # NEW - uses NativeLocation
        CalendarSource.swift      # NEW - EventKit directly (replaces device_calendar)
        WeatherSource.swift       # NEW - OpenWeather via URLSession
        NewsSource.swift          # NEW - NewsAPI via URLSession
        TransitSource.swift       # NEW - MapKit MKLocalSearch directly
        NotificationSource.swift  # NEW - UNUserNotificationCenter directly
    Platform/
      NativeLocation.swift        # EXISTING LocationChannel - strip Flutter, expose async API
      Settings.swift              # NEW - UserDefaults wrapper (replaces SharedPreferences)
      NotificationWhitelist.swift # NEW - JSON list stored in UserDefaults
    Models/
      EvenaiModel.swift           # NEW - Q&A history item (Identifiable)
      HistoryStore.swift          # NEW - @MainActor ObservableObject for history list
      NotifyModel.swift           # NEW - whitelist + notification item Codable
    Views/
      HomeView.swift              # NEW - ports home_page.dart (scan, connect, status)
      HistoryListView.swift       # NEW - ports even_list_page.dart
      FeaturesView.swift          # NEW - ports features_page.dart (nav hub)
      BmpView.swift               # NEW - ports features/bmp_page.dart
      TextEntryView.swift         # NEW - ports features/text_page.dart
      SettingsView.swift          # NEW - ports settings_page.dart
      BleProbeView.swift          # NEW - ports ble_probe_page.dart
      NotificationSettingsView.swift # NEW - ports notification_settings_page.dart
    Supporting Files/
      Info.plist                  # EXISTING - copy permission strings
      Assets.xcassets             # NEW - lift any needed assets
  COGOS.xcodeproj/project.pbxproj # NEW - fresh project, or heavily surgeried ios/Runner.xcodeproj
```

---

## Critical implementation notes

### BLE request/response (`BleRequestQueue.swift`)
Ports `BleManager.request()`, `sendBoth()`, `requestRetry()`, `requestList()` from `lib/ble_manager.dart:1`. Uses `async/await` with `CheckedContinuation` keyed by `(cmd, lr)`. `sendBoth` awaits L ack (`0xC9`) before dispatching to R. Timeouts via `Task.sleep` + `Task.cancel`. Heartbeat loop is a detached `Task` firing every 8s.

### Text pagination (`TextPaginator.swift`)
`EvenAIDataMethod.measureStringList` in `lib/services/evenai.dart` uses Flutter's `TextPainter` at 21px on 488px width to wrap lines. Replace with **CoreText `CTFramesetterCreateWithAttributedString` + `CTFramesetterSuggestFrameSizeWithConstraints`**, or more simply iterate word-by-word using `NSAttributedString.boundingRect(with:options:context:)` with `UIFont.systemFont(ofSize: 21)` at width 488. Must run on `@MainActor`. Returns `[String]` split into 5-line chunks (one per glasses screen). This is the single most display-critical piece — wrap points must match byte-for-byte to preserve existing page counts.

### Speech recognizer un-Flutterization (`SpeechStreamRecognizer.swift`)
Current file at `ios/Runner/SpeechStreamRecognizer.swift` writes to `blueSpeechSink: FlutterEventSink`. Change to expose `AsyncStream<String>` (partial transcripts) and a single `final: String` on `stopRecognition()`. `appendPCMData(Data)` stays. `EvenAISession` consumes the stream, accumulates `combinedText`, runs the silence timer (2s default from `Settings.silenceThreshold`).

### BluetoothManager un-Flutterization (`BluetoothManager.swift`)
Current file at `ios/Runner/BluetoothManager.swift` writes incoming packets to `blueInfoSink: FlutterEventSink`. Change to expose:
- `@Published var connectionState` (scanning/connecting/connected/disconnected)
- `@Published var pairedDevices: [(left: CBPeripheral, right: CBPeripheral)]`
- A `PassthroughSubject<ReceivedPacket, Never>` for incoming non-audio packets (consumed by `BleRequestQueue` and `GestureRouter`)
- PCM frames continue to route to `SpeechStreamRecognizer.appendPCMData` directly (no channel hop)
Methods `startScan`, `stopScan`, `connectToGlasses`, `disconnectFromGlasses`, `send(lr:data:)`, `tryReconnect` become plain `async` methods. `startEvenAI`/`stopEvenAI` collapse into `EvenAISession` calling the recognizer directly.

### Claude SSE streaming (`AnthropicClient.swift` + `SSEParser.swift`)
`lib/services/api_claude_service.dart` parses SSE with `event: content_block_delta` / `data: {...}` lines. Use `URLSession.bytes(for:)` (iOS 15+) or `URLSessionDataDelegate` buffering (iOS 14 compatible — our target is 14, so use delegate). `SSEParser` buffers line-by-line, emits `(event: String?, data: String)` pairs. `AnthropicClient.stream(message:session:)` returns `AsyncThrowingStream<String, Error>` yielding text chunks. Headers `x-api-key`, `anthropic-version: 2023-06-01`, `content-type: application/json`. Model `claude-sonnet-4-6`, `max_tokens: 1024`, `stream: true`. Caps history to `ClaudeSession.maxTurns = 20`.

### Cowork relay (`CoworkRelayClient.swift`)
Ports `lib/services/cowork_relay_service.dart`. Same `SSEParser`. Distinguishes `RelayOfflineError` (connection refused / timeout) vs `RelayAuthError` (HTTP 401). `EvenAISession` catches `RelayOfflineError` → sets `session.isOffline = true` → falls back to `AnthropicClient`. Session ID (`relaySessionId`) persisted per `ClaudeSession` for multi-turn continuity.

### GetX → SwiftUI reactivity mapping
| Dart (GetX)                       | Swift (SwiftUI)                            |
|-----------------------------------|--------------------------------------------|
| `RxBool isEvenAIOpen`             | `@Published var isEvenAIOpen: Bool` on session |
| `EvenaiModelController.items` (RxList) | `@Published var items: [EvenaiModel]` on `HistoryStore` |
| `Obx(() => ...)`                  | `@EnvironmentObject` / `@ObservedObject` |
| Singleton `EvenAI.get`            | `@EnvironmentObject var session: EvenAISession` |

`AppState` is a single `ObservableObject` injected at the root `WindowGroup` that owns `BluetoothManager`, `EvenAISession`, `HistoryStore`, `GlanceService`, `Settings`, `NotificationWhitelist`.

### CRC32-XZ (`CRC32XZ.swift`)
Dart uses the `crclib` package's CRC32-XZ variant for BMP transfer. Polynomial `0xEDB88320`, init `0xFFFFFFFF`, xor out `0xFFFFFFFF`, reflected input/output. Hand-roll a table-driven implementation in ~30 lines. Verify against a known test vector from the existing BMP flow before trusting it on-device.

### CocoaPods removal
Delete `ios/Podfile`, `ios/Podfile.lock`, `ios/Pods/`. The only non-plugin pod was `Toast` (used by `fluttertoast`) — replace toast usage with SwiftUI overlays or `UIAlertController`. `device_calendar` pod is replaced by direct `EKEventStore` calls in `CalendarSource.swift`. `shared_preferences_foundation` pod is replaced by `UserDefaults` directly.

### In-place replacement mechanics
1. Branch off `main`.
2. Create `COGOS.xcodeproj` at repo root (or renovate `ios/Runner.xcodeproj` — cleaner to create fresh and copy build settings).
3. Port `ios/Runner/Info.plist` permission strings into the new project's Info.plist.
4. Copy reusable Swift/C into the new project's source tree and strip Flutter imports.
5. Build out the Swift modules in the order below.
6. Once parity verified, in a single commit: delete `lib/`, `pubspec.yaml`, `pubspec.lock`, `android/`, `ios/Runner/`, `ios/Flutter/`, `ios/Podfile*`, `ios/Pods/`, `ios/.symlinks/`, `analysis_options.yaml`, `.metadata`, `tools/relay/server.js` stays (it's a Node script, not Flutter).
7. Update `README.md` and `CLAUDE.md` to reflect Swift stack.

---

## Build order (execution phases)

**Phase 0 — Project scaffold** (1 unit)
- Create new Xcode project at repo root, SwiftUI App lifecycle, iOS 14+, bundle `com.jackhu.cogos`.
- Copy `Info.plist` permission strings. Add capabilities: Bluetooth Central, Background Modes (bluetooth-central for BLE keepalive).
- Copy LC3 C codec, `PcmConverter.h/.m`, bridging header. Verify builds and links.

**Phase 1 — BLE foundation** (depends on 0)
- Un-Flutterize `BluetoothManager.swift` (replace `FlutterEventSink` → `PassthroughSubject`).
- Build `BleRequestQueue.swift` with async/await + continuation map.
- Build `GestureRouter.swift` to dispatch `0xF5 0xXX` gestures.
- Smoke test: scan, connect, heartbeat every 8s, log all incoming packets.

**Phase 2 — Protocol layer** (depends on 1)
- Port `Proto.swift`, `EvenAIProto.swift`.
- Port `CRC32XZ.swift` with unit test vectors.
- Port `BmpTransfer.swift`.
- Smoke test: send a text page and a test BMP to glasses.

**Phase 3 — Speech + pagination** (depends on 2)
- Un-Flutterize `SpeechStreamRecognizer.swift` (replace sink → `AsyncStream`).
- Build `TextPaginator.swift` with CoreText; write a test that compares outputs against a fixture list of Dart-generated wraps for 10 reference strings.

**Phase 4 — Session + API** (depends on 3)
- Build `SSEParser`, `AnthropicClient`, `CoworkRelayClient`.
- Build `ClaudeSession`, `SessionMode`, `EvenAISession` (the orchestrator).
- Wire long-press → mic on → STT → silence detect → API stream → paginate → send.
- **Parity milestone**: core AI loop works end-to-end with physical glasses.

**Phase 5 — State + UI** (depends on 4)
- Build `AppState`, `HistoryStore`, `Settings`, `NotificationWhitelist`.
- Build `HomeView`, `HistoryListView`, `SettingsView`, `FeaturesView`, `BleProbeView`, `TextEntryView`, `BmpView`, `NotificationSettingsView`.
- Wire all navigation, settings persistence, manual text/BMP sending.

**Phase 6 — Glance service** (depends on 5)
- Un-Flutterize `LocationChannel.swift` → `NativeLocation.swift` with async API.
- Build `GlanceSource` protocol and 6 sources (direct EventKit/MapKit/UNUserNotificationCenter, URLSession for Weather + News).
- Build `GlanceService` with Haiku ranking + per-source cache + 60s timer + head-up trigger.

**Phase 7 — Delete Flutter** (depends on 6, parity verified)
- Delete Dart/Flutter tree in a single commit.
- Update `README.md`, `CLAUDE.md`.

---

## Critical files & mapping

| Dart source | Swift target |
|---|---|
| `lib/main.dart`, `lib/app.dart` | `App/COGOSApp.swift`, `App/AppState.swift` |
| `lib/ble_manager.dart` | `BLE/BleRequestQueue.swift` + `BLE/GestureRouter.swift` |
| `lib/services/proto.dart` | `Protocol/Proto.swift` |
| `lib/services/evenai_proto.dart` | `Protocol/EvenAIProto.swift` |
| `lib/services/evenai.dart` | `Session/EvenAISession.swift` + `Session/TextPaginator.swift` |
| `lib/services/text_service.dart` | folded into `Session/TextPaginator.swift` + `EvenAISession` |
| `lib/services/api_claude_service.dart` | `API/AnthropicClient.swift` + `API/SSEParser.swift` |
| `lib/services/cowork_relay_service.dart` | `API/CoworkRelayClient.swift` |
| `lib/services/features_services.dart` | folded into `Protocol/BmpTransfer.swift` |
| `lib/services/notification_service.dart` | `Platform/NotificationWhitelist.swift` |
| `lib/services/glance_service.dart` + 6 sources | `Glance/GlanceService.swift` + `Glance/Sources/*.swift` |
| `lib/controllers/evenai_model_controller.dart` | `Models/HistoryStore.swift` |
| `lib/controllers/bmp_update_manager.dart` | `Protocol/BmpTransfer.swift` |
| `lib/models/*.dart` | `Models/EvenaiModel.swift`, `Models/NotifyModel.swift`, `Session/ClaudeSession.swift` |
| `lib/views/*.dart` (8 pages) | `Views/*.swift` (8 views) |
| `lib/utils/*.dart` | folded into call sites or `Supporting/Utils.swift` |
| `lib/services/api_services*.dart` (legacy) | **deleted** |
| `ios/Runner/BluetoothManager.swift` | `BLE/BluetoothManager.swift` (un-Flutterized) |
| `ios/Runner/SpeechStreamRecognizer.swift` | `Session/SpeechStreamRecognizer.swift` (un-Flutterized) |
| `ios/Runner/LocationChannel.swift` | `Platform/NativeLocation.swift` (un-Flutterized) |
| `ios/Runner/GattProtocal.swift` | `BLE/GattProtocol.swift` (copy, rename typo) |
| `ios/Runner/ServiceIdentifiers.swift` | `BLE/ServiceIdentifiers.swift` (copy as-is) |
| `ios/Runner/PcmConverter.h/.m` | `Session/PcmConverter.h/.m` (copy as-is) |
| `ios/Runner/lc3/` | `Session/lc3/` (copy as-is) |
| `ios/Runner/AppDelegate.swift` | deleted (SwiftUI App lifecycle) |
| `ios/Runner/TransitChannel.swift` | deleted (MapKit used directly in `TransitSource.swift`) |
| `ios/Runner/NotificationChannel.swift` | deleted (UNUserNotificationCenter used directly) |
| `ios/Runner/GeneratedPluginRegistrant.*` | deleted |

---

## Verification

End-to-end tests on physical G1 glasses (BLE can't be simulated):

1. **Scan & connect** — app discovers paired glasses, connects both arms, heartbeat keeps connection alive for ≥5 min.
2. **Gesture routing** — single-tap pages text, double-tap exits, triple-tap cycles mode, head-up triggers glance, long-press starts recording.
3. **Core AI loop** — long-press L → say "hey claude what time is it" → release → glasses display Claude reply paginated across 5-line screens → single-tap pages through.
4. **Wake word gating** — recording without "hey claude" prompts `Say "Hey Claude" to start`.
5. **Mode cycle** — triple-tap L → `[CODE]` header on next reply; triple-tap R → `[WORK]` header, session persists across turns.
6. **Cowork fallback** — stop relay server mid-session → next query auto-falls-back to direct API without user-visible error.
7. **Text pagination parity** — run `TextPaginator` on 10 reference strings; output must match Dart fixtures byte-for-byte.
8. **BMP transfer** — send a test BMP from BmpView; glasses render it; CRC32 ack received.
9. **Glance** — head-up tilt triggers glance, shows 5 lines from at least 3 sources, auto-dismisses after 60s.
10. **Settings persistence** — change silence threshold + head-up angle, kill app, relaunch, values persist and are pushed to glasses on reconnect.
11. **Notification whitelist** — add app → list persists → reconnecting glasses receives updated whitelist via `0x04`.
12. **Cold start reconnect** — launch app with glasses out of range, glasses come into range, `tryReconnect` succeeds using UUIDs from `UserDefaults`.
13. **Flutter removal** — `lib/`, `pubspec.yaml`, `android/`, `ios/Pods/`, `ios/Flutter/` all gone; `git grep -i flutter` returns only matches in `README.md`/`CLAUDE.md` history notes or nothing.
