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

Cloud agents (Linux) install Swift + XcodeGen and compile IMAP/SwiftMail with:

```bash
./scripts/cloud-compile.sh
```

That generates `COGOS.xcodeproj` and typechecks the mail client against SwiftMail. Full iOS `xcodebuild` still needs a Mac.

If you modify the project structure (add/remove files, change build settings),
edit `project.yml` and re-run `xcodegen generate`.

## Hermes Agent

Enter the HTTPS Hermes API URL and access token in Settings, or export
`HERMES_API_URL` and `HERMES_API_KEY` in the Xcode scheme. The token is stored
in Keychain. Hermes owns model selection, memory, skills, and tools; COGOS
sends only final speech transcripts and renders streamed final-answer text.

## OpenRouter spoken agent

Settings → Spoken assistant can switch the glasses question path from Hermes
to OpenRouter. That path uses [SwiftAgent](https://github.com/SwiftedMind/SwiftAgent)
(`OpenAISession`) against `https://openrouter.ai/api/v1/responses`. The phone
owns the tool loop (calendar, weather, location, IMAP mail, and web search), resends
the full transcript every turn, and pushes the finished answer to the glasses
scroller — it does not stream tokens or tool JSON to the waveguide.

Use a tool-capable model (default `google/gemini-2.5-flash`), not the news
digest free model. The same OpenRouter key is stored in Keychain
(`OPENROUTER_API_KEY`). Override the agent slug with `OPENROUTER_AGENT_MODEL`.
Web search uses OpenRouter's `openrouter:web_search` server tool. Mail search
uses [SwiftMail](https://github.com/Cocoanetics/SwiftMail) over TLS IMAP
(iCloud default `imap.mail.me.com:993`). Store an app-specific password in
Settings / Keychain, not the Apple ID password. Overrides: `IMAP_HOST`,
`IMAP_PORT`, `IMAP_USER`, `IMAP_PASSWORD`, `IMAP_MAILBOX`.

The news glance still uses a separate cheap chat completion
(`poolside/laguna-xs-2.1:free` by default) to turn RSS headlines into a
three-line digest. Without that key it falls back to clipped headlines.

After adding or changing Swift packages, re-run `xcodegen generate` and
`./scripts/resolve-spm.sh`, then commit
`COGOS.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.
Xcode Cloud has automatic resolution disabled, so Archive fails without that pin file.
Do not “Update to Latest Package Versions” for OpenAI: SwiftAgent still
uses `Includable` / `ToolChoicePayload`, which MacPaw renamed on `main`.
`resolve-spm.sh` pins OpenAI to the revision SwiftAgent itself resolved.
`ci_scripts/ci_post_clone.sh` and `ci_pre_xcodebuild.sh` set
`IDESkipMacroFingerprintValidation` (the usual Xcode Cloud stand-in for
`xcodebuild -skipMacroValidation`) so Archive can use SwiftAgentMacros without
the local “Enable Macros” dialog.

## Project layout

```
COGOS/
├── App/               SwiftUI App, root state, ContentView
├── BLE/               BluetoothManager, BleRequestQueue, GestureRouter, UUIDs
├── Protocol/          Proto, EvenAIText54, DashboardProto, QuickNoteProto, CRC32XZ
├── Session/           EvenAISession, EvenTextRenderer, VoiceCaptureController,
│                      SpeechStreamRecognizer, PcmConverter, LC3 codec
├── API/               HermesClient, OpenRouterClient, IMAPClient, SSEParser
├── Agent/             OpenRouter SwiftAgent session, device tools
├── Glance/            GlanceService + Sources/
├── Platform/          NativeLocation, Settings, NotificationWhitelist
├── Models/            EvenaiModel, HistoryStore, NotifyModel
├── Views/             SwiftUI views (Home, History, Settings, BleProbe, …)
└── Supporting/        Info.plist, bridging header, entitlements
```
