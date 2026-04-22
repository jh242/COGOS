# COGOS — Claude On Glass OS (Swift)

An iOS app that turns **Even Realities G1 smart glasses** into a wearable
AI terminal. The phone connects to the glasses over dual BLE (one
connection per arm), streams LC3 audio from the glasses microphone,
transcribes speech with the native iOS Speech framework, calls an
OpenAI-compatible Chat Completions endpoint, and streams the reply to
the waveguide display using the firmware-native 0x54 TEXT command.

Pure Swift / SwiftUI. iOS 26+. Bundle ID: `com.jackhu.cogos`.

## Getting started

See [`COGOS/README.md`](COGOS/README.md) for Xcode project setup.
The `.xcodeproj` is regenerated from `project.yml` via
[XcodeGen](https://github.com/yonaskolb/XcodeGen).

## API

The LLM endpoint is user-configurable — any OpenAI-compatible
`/v1/chat/completions` server will do. Set base URL, model, and API key
in the in-app Settings screen (persisted to `UserDefaults`), or export
`LLM_API_KEY` in the Xcode scheme.

Weather uses Apple WeatherKit (entitlement required). News glance uses
Google News RSS; headlines are truncated to their first few words for the
waveguide's narrow line budget.

## Layout

```
COGOS/          Swift / SwiftUI app source
docs/           Design docs and migration plans
```

## License

See [LICENSE](LICENSE).
