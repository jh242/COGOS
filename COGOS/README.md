# COGOS (Swift)

Pure-Swift / SwiftUI port of the COGOS app. iOS-only. Targets iOS 18+.

## Xcode project setup

The `.xcodeproj` is generated from `project.yml` using
[XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen   # one-time
xcodegen generate       # run from repo root
open COGOS.xcodeproj
```

Then build & run on a physical device (BLE can't be simulated).

If you modify the project structure (add/remove files, change build settings),
edit `project.yml` and re-run `xcodegen generate`.

## API keys

Either enter them in the in-app Settings screen (they persist to
`UserDefaults`), or export `ANTHROPIC_API_KEY` as an environment variable in
the Xcode scheme.

## Project layout

```
COGOS/
├── App/               SwiftUI App, root state, ContentView
├── BLE/               BluetoothManager, BleRequestQueue, GestureRouter, UUIDs
├── Protocol/          Proto, EvenAIProto, DashboardProto, QuickNoteProto, CRC32XZ
├── Session/           EvenAISession, SpeechStreamRecognizer, TextPaginator,
│                      ClaudeSession, PcmConverter, LC3 codec
├── API/               AnthropicClient, CoworkRelayClient, SSEParser
├── Glance/            GlanceService + Sources/
├── Platform/          NativeLocation, Settings, NotificationWhitelist
├── Models/            EvenaiModel, HistoryStore, NotifyModel
├── Views/             SwiftUI views (Home, History, Settings, BleProbe, …)
└── Supporting/        Info.plist, bridging header, entitlements
```
