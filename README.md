# COGOS — Claude On Glass OS (Swift)

An iOS app that turns **Even Realities G1 smart glasses** into a wearable
AI terminal. The phone connects to the glasses over dual BLE (one
connection per arm), streams LC3 audio from the glasses microphone,
transcribes speech with the native iOS Speech framework, sends the transcript
to a remote Hermes Agent, and streams the reply to
the waveguide display using the firmware-native 0x54 TEXT command.

Pure Swift / SwiftUI. iOS 26+. Bundle ID: `com.jackhu.cogos`.

## Getting started

See [`COGOS/README.md`](COGOS/README.md) for Xcode project setup.
The `.xcodeproj` is regenerated from `project.yml` via
[XcodeGen](https://github.com/yonaskolb/XcodeGen).

## Hermes Agent

Enable Hermes' API server and expose it through HTTPS. Set its URL and bearer
token in the in-app Settings screen, or export `HERMES_API_URL` and
`HERMES_API_KEY` in the Xcode scheme. The app sends only final speech
transcripts; Hermes owns all model, memory, tool, and agent behavior.

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
