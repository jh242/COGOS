# Repurposing the right-side TouchBar hold

## Today

`0xF5 0x17` (long-press held) and `0xF5 0x18` (released) fire from either
arm. `GestureRouter` currently ignores `lr` and routes both into
`EvenAISession.toStartEvenAIByOS()` / `recordOverByOS()`. So right-arm hold
behaves identically to left-arm hold: long-press starts an Even AI voice
turn, release ends it.

That wastes a free, symmetrical, always-available physical input.

## Why right-arm hold is interesting

- It is symmetrical to the left-arm hold (same firmware event, just a
  different `lr`), so we already get the gesture for free.
- It is **distinct from** taps and double-taps, which firmware uses for
  page scroll and dashboard show/hide.
- The user's hand is already on the temple; no other gesture needs the
  right arm right now.
- It cleanly maps to "second voice action" without conflicting with the
  primary "ask the agent" verb.

## Candidate repurposings

Pick one, not all. Listed roughly in order of leverage.

1. **Scratch / off-the-record mode.** Right-hold runs a one-shot voice
   turn that does not persist into `AgentMemory.recentTurns` and does not
   feed future context. Useful for "translate this", "what time is it in
   X", quick lookups that should not pollute the running conversation.

2. **Quick Note dictation.** Right-hold transcribes voice straight into a
   `QuickNote` slot (`0x1E`) with no LLM call. Fastest path from "I just
   thought of something" to "it's on the glasses". Pairs naturally with
   the existing dashboard Quick Notes pane.

3. **Repeat / re-render last answer.** Right-hold short-press re-pushes
   the last assistant reply via the renderer so the user can re-read a
   message that scrolled off, without burning another model call.

4. **Mode switch.** Right-hold cycles `SessionMode` (chat ↔ code ↔ note)
   and announces the new mode on-glass. Cheap, discoverable, no STT
   required.

5. **User-bindable action.** Defer the decision: ship right-hold as an
   `AgentBinding` slot (Phase 7), with a sensible default like #1 or #2,
   and let Settings remap it to a prompt / tool / mode.

## Implementation notes

- `GestureRouter.handle(lr:data:)` already receives `lr`. Branch on it for
  `0x17`/`0x18` instead of dropping it.
- Keep the left-arm path exactly as it is. Only add the right-arm path.
- If the choice is "scratch mode" or "quick note", the runtime needs a
  way to opt out of memory persistence per-event. That maps cleanly to
  a new `AgentEvent` variant (e.g. `voiceTranscriptScratch(String)`)
  rather than a flag on the existing one — keeps the reducer-style event
  surface honest.
- If the choice is "user-bindable", wait for Phase 7 (`SidebarBinding` →
  `AgentBindingAction`) and reuse that machinery.

## Recommendation

Default to **scratch mode** as the stock right-hold behaviour, and make
it remappable later via Phase 7 bindings. It is the smallest change that
extracts real value from a currently-redundant gesture and it composes
with the existing voice flow.
