# COGOS (Swift)

Pure-Swift / SwiftUI port of the COGOS app. iOS-only. Targets iOS 26+.

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

Either enter them in the in-app Settings screen (persisted to `UserDefaults`
under `llm_api_key`), or export `LLM_API_KEY` in the Xcode scheme. Base URL
(default `https://api.openai.com/v1/`) and model are also configurable.

## Project layout

```
COGOS/
├── App/               SwiftUI App, root state, ContentView
├── BLE/               BluetoothManager, BleRequestQueue, GestureRouter, UUIDs
├── Protocol/          Proto, EvenAIText54, DashboardProto, QuickNoteProto, CRC32XZ
├── Session/           EvenAISession, SpeechStreamRecognizer,
│                      ClaudeSession, PcmConverter, LC3 codec
├── API/               ChatCompletionsClient, SSEParser
├── Glance/            GlanceService + Sources/
├── Platform/          NativeLocation, Settings, NotificationWhitelist
├── Models/            EvenaiModel, HistoryStore, NotifyModel
├── Views/             SwiftUI views (Home, History, Settings, BleProbe, …)
└── Supporting/        Info.plist, bridging header, entitlements
```
