# Plan: Ambient Conversate Mode

## Goal

Add an optional, unbound-by-default conversation intelligence mode for the
Even Realities G1 glasses. From neutral state, the user may bind a
double-click on either sidebar to start or stop this mode.

When active, COGOS listens to nearby conversation audio, streams it to a
realtime reasoning backend, and displays only high-value, compact cues on
the glasses: factual checks, clarifying questions, action items, or
memory-worthy names/dates/places.

This is not a live transcript feature. The glasses should stay silent most
of the time.

## Product shape

Ambient Conversate Mode should feel like a quiet conversation radar:

- turn on and go
- no prep notes required
- no scripted conversation path
- no constant assistant chatter
- no always-visible transcript on glasses
- one small cue only when it is worth interrupting the wearer

Example cues:

```text
CHECK
stat may be off
ask source
```

```text
CLARIFY
Q3 or Sept?
confirm date
```

```text
ACTION
send resume
after call
```

```text
REMEMBER
Maya = hiring mgr
infra team
```

## Gesture binding

This feature should be bindable to:

- double-click left sidebar from neutral state
- double-click right sidebar from neutral state

It should be **unbound by default**.

Rationale:

- double-click is intentional enough for a privacy-sensitive listening mode
- either sidebar should be supported because user preference / handedness matters
- neutral-state-only avoids conflict with AI session exit / active display flows
- default unbound avoids surprising users with an ambient microphone mode

Settings should eventually expose something like:

```text
Sidebar double-click from neutral:
- Unbound (default)
- Ambient Conversate toggle
- Existing action ...
```

If Ambient Conversate is active, double-clicking the bound sidebar again
should stop the session.

## Non-goals

- Do not implement prep notes in the first version.
- Do not show a continuous transcript on the glasses.
- Do not build a cached cue deck or predicted conversation path.
- Do not make every transcript window produce a cue.
- Do not hardwire OpenAI Realtime into app-level code.
- Do not bind the gesture by default.

## Architecture

```
AudioCapture
  ↓
RealtimeReasoningSession
  ↓
CuePolicy
  ↓
GlassesDisplay
  ↓
ConversateHistoryStore
```

Provider-specific details must stay behind a common adapter so OpenAI
Realtime can be used first, then swapped for a cheaper/self-hosted backend
such as Qwen Omni through vLLM-Omni.

## Realtime provider adapter

Define a provider-neutral session interface. Exact Swift names can change,
but the seam should stay stable:

```swift
protocol RealtimeReasoningSession: AnyObject {
    func start(config: RealtimeSessionConfig) async throws
    func sendAudio(_ pcm16: Data, timestampMs: Int64) async throws
    func commitAudio() async throws
    func updateInstructions(_ instructions: String) async throws
    func stop() async throws

    var events: AsyncStream<RealtimeReasoningEvent> { get }
}
```

Normalized events:

```swift
enum RealtimeReasoningEvent {
    case sessionStarted
    case sessionStopped
    case speechStarted
    case speechStopped
    case transcriptPartial(String)
    case transcriptFinal(String)
    case cueCandidate(CueCandidate)
    case providerError(String)
}
```

Cue candidate:

```swift
struct CueCandidate: Codable, Equatable {
    enum CueType: String, Codable {
        case check
        case clarify
        case action
        case remember
    }

    let type: CueType
    let lines: [String]          // max 3 lines, display-budgeted
    let confidence: Double
    let sourceStartMs: Int64?
    let sourceEndMs: Int64?
    let provider: String
}
```

The app should never depend directly on OpenAI's event names. Provider
adapters translate raw provider events into `RealtimeReasoningEvent`.

## Provider implementations

### Phase 1 provider: OpenAI Realtime

Use OpenAI Realtime as the first backend because it gives the cleanest
product-feel prototype:

```
iPhone PCM16 audio
  → OpenAI Realtime session
  → normalized transcript / cue events
  → CuePolicy
  → glasses
```

The Realtime session should be instructed to be silence-biased and output
structured cue candidates only when useful.

Provider output should be text/JSON for COGOS. Audio output is not needed
for the first version.

### Later provider: Qwen Omni / vLLM-Omni

Add a second provider behind the same adapter:

```
iPhone PCM16 audio
  → vLLM-Omni / Qwen Omni realtime endpoint
  → normalized transcript / cue events
  → CuePolicy
  → glasses
```

This should be treated as a backend swap, not a product rewrite.

### Fallback provider: Apple Speech + text-window LLM

Keep a possible fallback path:

```
iPhone mic
  → Apple Speech partial/final transcript
  → rolling text windows
  → text LLM
  → normalized cue candidates
```

This is less realtime-native, but easier to debug and useful if realtime
provider cost or availability becomes an issue.

## Cue policy

The provider may emit cue candidates, but `CuePolicy` decides whether they
actually appear on glasses.

Rules for the first implementation:

- maximum one visible cue at a time
- suppress low-confidence cues
- suppress repeated semantic duplicates
- cooldown after showing a cue, initially 8-15 s
- expire cues quickly, initially 8-12 s
- do not queue old cues behind newer conversation context
- prefer no cue over a mediocre cue

Allowed cue types:

| Type     | Purpose                                      |
|----------|----------------------------------------------|
| CHECK    | possible factual issue or contradiction      |
| CLARIFY  | ambiguity worth asking about                 |
| ACTION   | commitment / follow-up detected              |
| REMEMBER | name, date, place, or entity worth retaining |

No generic encouragement. No generic summaries. No suggestions unless they
fit one of the above types.

## Display behavior

When the session starts:

```text
LISTENING
Ambient mode
hold/double: stop
```

When a cue is accepted:

```text
CHECK
stat may be off
ask source
```

When the session ends:

```text
SUMMARY READY
open phone
```

Use the existing firmware-native text path initially. If `0x54` behavior
remains fragile for short-lived cue cards, isolate display transport behind
a small `ConversateDisplay` wrapper so the rendering path can change later.

## Privacy / safety defaults

- Feature is unbound by default.
- Starting a session should require an explicit user gesture.
- The app should make active listening state obvious on phone and glasses.
- Do not retain raw audio by default.
- Store transcript only if the user enables session history.
- A summary-only mode should be possible later.
- Provider choice should be visible in settings.

## Files

Likely new files:

- `COGOS/Session/RealtimeReasoningSession.swift`
- `COGOS/Session/OpenAIRealtimeSession.swift`
- `COGOS/Session/AppleSpeechWindowSession.swift` (fallback / later)
- `COGOS/Session/CuePolicy.swift`
- `COGOS/Session/ConversateSession.swift`
- `COGOS/Models/CueCandidate.swift`
- `COGOS/Models/ConversateHistoryStore.swift`
- `COGOS/Views/ConversateView.swift`
- `COGOS/Views/ConversateSettingsView.swift`

Likely modified files:

- `COGOS/BLE/GestureRouter.swift` — neutral-state double-click routing
- `COGOS/Platform/Settings.swift` — gesture binding + provider selection
- `COGOS/Protocol/EvenAIText54.swift` or a display wrapper — cue cards
- `COGOS/App/AppState.swift` — session ownership / lifecycle

## Sequencing

### Phase 0 — Product seam

- [ ] Add this plan document.
- [ ] Define `RealtimeReasoningSession` and normalized events.
- [ ] Define `CueCandidate` and `CuePolicy` types.
- [ ] Add settings model for neutral sidebar double-click binding.
- [ ] Default binding to unbound.

Exit: app builds with no behavior change.

### Phase 1 — Phone-only prototype

- [ ] Implement a mock or debug provider that emits cue candidates manually.
- [ ] Build `ConversateSession` lifecycle: idle, listening, stopping.
- [ ] Build phone UI for start/stop and candidate cue inspection.
- [ ] Verify `CuePolicy` suppression/dedupe/cooldown behavior.

Exit: cue candidates can be generated and filtered without BLE/display risk.

### Phase 2 — OpenAI Realtime provider

- [ ] Implement `OpenAIRealtimeSession` behind the adapter.
- [ ] Stream iPhone mic PCM16 into the session.
- [ ] Request text/JSON cue outputs only; no audio output needed.
- [ ] Normalize transcript and cue events.
- [ ] Log provider latency: speech start, transcript, cue candidate, display accept.

Exit: phone-only realtime cues work from live audio.

### Phase 3 — Glasses display

- [ ] Add `ConversateDisplay` wrapper over the existing text display path.
- [ ] Show listening / stopped state on glasses.
- [ ] Show accepted cue cards on glasses.
- [ ] Auto-expire cue cards.

Exit: live ambient cues appear on glasses with acceptable latency.

### Phase 4 — Gesture binding

- [ ] Add neutral-state double-click binding support for left sidebar.
- [ ] Add neutral-state double-click binding support for right sidebar.
- [ ] Ensure the setting remains unbound by default.
- [ ] If bound, double-click starts Ambient Conversate from neutral.
- [ ] If active, double-click stops Ambient Conversate.
- [ ] Ensure active AI/session gestures still take precedence.

Exit: feature can be started/stopped from glasses only when explicitly bound.

### Phase 5 — Backend swap experiment

- [ ] Implement `QwenOmniRealtimeSession` or equivalent provider against vLLM-Omni.
- [ ] Run the same normalized event interface.
- [ ] Compare latency, cue quality, JSON reliability, and cost against OpenAI Realtime.

Exit: backend can be changed without rewriting product logic.

## Verification

- Default install: double-click sidebar from neutral does nothing new.
- Binding set to left: left double-click toggles Ambient Conversate; right does not.
- Binding set to right: right double-click toggles Ambient Conversate; left does not.
- Ambient mode active: phone and glasses clearly indicate listening.
- Provider emits repeated similar cue candidates: only one cue displays.
- Provider emits stale cue after newer context: stale cue is ignored.
- Provider emits low-confidence cue: cue is suppressed.
- Session stop: microphone streaming stops, provider session closes, glasses state clears.
- OpenAI provider can be replaced by a mock provider without touching gesture/display code.

## Open questions

- Should session history store transcript, summary only, or nothing by default?
- Should fact-check cues trigger a secondary verifier/tool lookup, or only surface uncertainty?
- What is the best display transport for short cue cards if `0x54` streaming remains unreliable?
- Should both left and right sidebar double-click be independently bindable, or a single setting choosing one side?
- What minimum confidence threshold makes the glasses feel helpful rather than noisy?
