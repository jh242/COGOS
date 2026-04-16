# COGOS — Claude On Glass OS (Swift)

An iOS app that turns **Even Realities G1 smart glasses** into a wearable
Claude terminal. The phone connects to the glasses over dual BLE (one
connection per arm), streams LC3 audio from the glasses microphone,
transcribes speech with the native iOS Speech framework, calls the Claude
API, and renders the reply on the glasses waveguide display.

Pure Swift / SwiftUI. iOS 14+. Bundle ID: `com.jackhu.cogos`.

## Getting started

See [`COGOS/README.md`](COGOS/README.md) for Xcode project setup
(the `.xcodeproj` is not committed — create it fresh in Xcode and drag
the `COGOS/` folder into the project).

## API keys

Set in the in-app Settings screen (persisted to `UserDefaults`) or export
`ANTHROPIC_API_KEY` in the Xcode scheme's environment variables.

Weather and news glance sources are keyless: weather via
[wttr.in](https://wttr.in), news via Google News RSS.

## Cowork relay (optional)

For the `cowork` session mode, a Node.js relay can spawn `claude --print`
locally so the glasses pair-program with Claude Code on your workstation.

```bash
cd tools/relay
npm install
ANTHROPIC_API_KEY=sk-ant-... node server.js
```

The Swift client falls back to the direct Anthropic API if the relay
is unreachable.

## Layout

```
COGOS/          Swift / SwiftUI app source
tools/relay/    Node.js Claude Code relay server
docs/           Design docs and migration plans
```

## License

See [LICENSE](LICENSE).
