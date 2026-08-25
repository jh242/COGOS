# COGOS — Claude On Glass OS

**A hands-free AI assistant that lives on your face.**

COGOS turns [Even Realities G1](https://www.evenrealities.com/g1) smart glasses into a wearable AI terminal: speak naturally, and watch the reply stream onto the lens in front of your eye. No phone out of pocket, no wake screen, no app switching.

<!-- DEMO GIF HERE — 15–30s of: speak a question → text streaming onto the waveguide.
     This single asset does more work than everything below it. -->

## What it does

- **Ask anything, hands-free** — speech is captured from the glasses' mic, transcribed on-device, sent to a Hermes Agent, and the answer streams to the waveguide display in real time
- **Glanceable info** — weather and news briefs designed around the display's narrow line budget: a few words per line, no scrolling walls of text
- **Agent-powered answers** — Hermes owns the model, memory, tools, and agent behavior while the iPhone handles speech, BLE, and display rendering

## Why

Smart glasses shipped with firmware built for notifications. The interesting product is an ambient AI you talk to while walking — so COGOS is my own harness for that loop: audio in, tokens out, rendered on glass. The core design problem isn't the plumbing; it's making AI output *glanceable* on a display that fits a dozen words.

## How it works

```
G1 mic ──LC3 audio──▶ iPhone ──iOS Speech──▶ transcript
                                                 │
waveguide display ◀──0x54 TEXT cmd── streamed ◀──Hermes Agent
```

- Dual BLE connections (one per arm of the glasses)
- LC3 audio streamed from the glasses' microphone
- On-device transcription via the native iOS Speech framework
- Final transcripts sent to a remote Hermes Agent over HTTPS
- Replies streamed to the display using the firmware-native `0x54` TEXT command
- Weather via Apple WeatherKit (entitlement required); news via Google News RSS, digested by a cheap OpenRouter model to fit the line budget

Pure Swift / SwiftUI. iOS 26+. Bundle ID: `com.jackhu.cogos`. Built almost entirely through agentic coding (Claude), with architecture and product direction by me — see `docs/` for design docs and migration plans.

## Getting started

See [`COGOS/README.md`](COGOS/README.md) for Xcode project setup. The `.xcodeproj` is regenerated from `project.yml` via [XcodeGen](https://github.com/yonaskolb/XcodeGen).

## Hermes Agent

Enable Hermes' API server and expose it through HTTPS. Set its URL and bearer
token in the in-app Settings screen, or export `HERMES_API_URL` and
`HERMES_API_KEY` in the Xcode scheme. The app sends only final speech
transcripts; Hermes owns all model, memory, tool, and agent behavior.

Weather uses Apple WeatherKit (entitlement required). News glance fetches
Google News RSS and asks a free OpenRouter model (`poolside/laguna-xs-2.1:free`
by default; pick another from the Settings dropdown) for a three-line digest.
Set `OPENROUTER_API_KEY` in the Xcode scheme or the in-app Settings screen.
Without a key, clipped headlines are shown instead.

## Layout

```
COGOS/          Swift / SwiftUI app source
docs/           Design docs and migration plans
```

## License

See [LICENSE](LICENSE).
