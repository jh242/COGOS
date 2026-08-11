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

## Hermes Agent

Enter the HTTPS Hermes API URL and access token in Settings, or export
`HERMES_API_URL` and `HERMES_API_KEY` in the Xcode scheme. The token is stored
in Keychain. Hermes owns model selection, memory, skills, and tools; COGOS
sends only final speech transcripts and renders streamed final-answer text.

## Project layout

```
COGOS/
├── App/               SwiftUI App, root state, ContentView
├── BLE/               BluetoothManager, BleRequestQueue, GestureRouter, UUIDs
├── Protocol/          Proto, EvenAIText54, DashboardProto, QuickNoteProto, CRC32XZ
├── Session/           EvenAISession, EvenTextRenderer, VoiceCaptureController,
│                      SpeechStreamRecognizer, PcmConverter, LC3 codec
├── API/               HermesClient, SSEParser
├── Glance/            GlanceService + Sources/
├── Platform/          NativeLocation, Settings, NotificationWhitelist
├── Models/            EvenaiModel, HistoryStore, NotifyModel
├── Views/             SwiftUI views (Home, History, Settings, BleProbe, …)
└── Supporting/        Info.plist, bridging header, entitlements
```
