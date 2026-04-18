# Plan: Migrate Glance to Firmware Dashboard + Quick Notes

## Goal

Retire the phone-side 640×200 bitmap glance. Push time / weather / calendar
data to the firmware dashboard natively. Push contextual text (transit,
notifications) as a firmware Quick Note.

**Guiding principle:** stay as close to the stock firmware workflow as
possible — just with our own models. Don't fight firmware gestures, don't
reinvent firmware surfaces, don't run the Even mobile app in parallel.
COGOS's value-add is Claude + our own data sources, not a re-skinned UX.

## Why

- Every 60 s we currently render a BMP via Core Graphics, encode it, chunk it
  into 194-byte packets, transfer ~16 KB over BLE, CRC32-XZ verify on both
  arms. Firmware replacements:
  - `0x06 0x01 TIME_AND_WEATHER` — single short packet
  - `0x06 0x03 CALENDAR` — one chunked list
  - `0x1E 0x03 NOTE_TEXT_EDIT` — short quick-note push per contextual winner
- Firmware owns layout + typography from here on. We lose the two-column
  SF Pro look; we gain latency, battery, correctness, and a lot less code.

## What survives, what dies

**Dies:**
- `COGOS/Glance/GlanceRenderer.swift`
- `COGOS/Glance/BmpEncoder.swift`
- `drawContent(in:context:)` on `GlanceSource` + every source implementation
- `GlanceService`'s `BmpTransfer` + `BluetoothManager` dependencies
- 1-bit bitmap inversion logic, font size bookkeeping, column layout
- Custom touchpad bindings that fight firmware defaults (head-up,
  head-down, double-tap — see Q1 table below)

**Conditional on Q4 hypothesis (firmware paginates):**
- `TextPaginator.swift` — deleted, firmware paginates natively.
- `EvenAISession` page-turn methods — deleted.
- `GestureRouter` single-tap AI-mode handler — no-op.
- `EvenAIProto.multiPackListV2` — simplified: transport chunking only,
  no display-page metadata.
- `Proto.sendEvenAIData` — takes full response + display mode, not pages.

**Survives unchanged:**
- Relevance scoring + tier system (`fixed` / `contextual` / `fallback`)
- 60 s refresh loop in `GlanceService`
- All data-source logic (Calendar/Weather/Transit/Notifications/News)
- `BmpTransfer` stays because `BmpView` (the debug probe) uses it — not a
  glance dependency anymore
- Speech recognition + wake word + Claude API call in `EvenAISession`
- Heartbeat, BLE plumbing, notification whitelist, battery telemetry

## Open research before coding

**Status update (2026-04-16):** Gadgetbridge PR #4553 source was inspected
end-to-end. Results:

### Pinned (done)

1. **`0x06 0x01 TIME_AND_WEATHER`** — fixed 22-byte packet (was listed as
   21 pre-sniff; the Even app emits 22 with a trailing `0x00` at byte [21]).
   Layout in `docs/G1_PROTOCOL_REFERENCE.md`.
2. **`0x06 0x03 CALENDAR`** — chunked TLV. 9-byte per-chunk header,
   `0x01/0x02/0x03` TLV per event (title/time_str/location). Time is
   **pre-formatted string**, not a timestamp. Max 171 body bytes per
   chunk. Empty-calendar body is `00 00 02` (not Gadgetbridge's speculative
   `01 03 03`; non-empty prefix still needs a populated-calendar sniff).
   Layout in `docs/G1_PROTOCOL_REFERENCE.md`.
3. **`0x06 0x06 MODE`** — fixed 7-byte packet. Mode byte + secondary pane
   byte. Layout in `docs/G1_PROTOCOL_REFERENCE.md`.
4. **`0x1E 0x03 NOTE_TEXT_EDIT`** — pinned 2026-04-17 via PacketLogger
   capture of the official Even iOS app. Non-empty body is
   `[slot_id][0x01][title_len:u8][title_utf8][body_len:u16 LE][body_utf8]`;
   empty slots use a fixed 7-byte template. Critical protocol semantic:
   **replace-all-4-slots** — every update writes 4 packets, one per
   slot, whether or not each slot changed. The `0x08 NOTE_ADD` and
   `0x07 NOTE_STATUS_EDIT` sub-commands declared in Gadgetbridge are
   never emitted by the Even app — `0x03` is the single unified write.
   Layout in `docs/G1_PROTOCOL_REFERENCE.md`.
5. **`0x22 0x05`** (new, not in prior docs) — right-arm-only status/ack
   fired after every dashboard ping. Format `22 05 00 <seq> 01`, response
   `22 05 00 <seq> 01 0A 01 01`. Trailing bytes unexplained. Our app
   doesn't need to emit this — it's specific to the Even app's keepalive
   strategy. Layout in `docs/G1_PROTOCOL_REFERENCE.md`.

### Still blocked

6. **`0x06 0x04 STOCKS` and `0x06 0x05 NEWS`** — not triggered in the
   Quick Notes sniff session. The Even app only emits these when the user
   enables those dashboard panes. Needs a follow-up session where the
   tester toggles stocks / news on and adds items.
7. **`0x58 DASHBOARD_CALENDAR_NEXT_UP_SET`** — not observed. Theory: fires
   when a calendar event transitions to "next up". To trigger, create a
   calendar event starting in ~5 min and capture across the transition.

### Material consequence (resolved)

Quick Notes is now implementable. The surprise from the sniff is that the
protocol is **replace-all-4-slots**, not per-slot add/delete. That changes
Q3's "slot 0 only, overwrite" — we can still dedicate one slot to contextual
content, but the Swift write always emits 4 packets per update (the
contextual slot + 3 empty templates). See revised Q3 below.

Options A/B/C from the pre-sniff plan: A was executed. Not backtracking.

### Sniff-session protocol

First session complete (2026-04-17, Quick Notes). Byte layouts are pinned
inline in `docs/G1_PROTOCOL_REFERENCE.md`. For follow-up sessions
(stocks/news/`0x58`), the workflow is:

- ATT write handle: **`0x0015`** on both arms. Arms differ at the HCI
  connection-handle layer (`0x0401` / `0x0404`), not at ATT.
- PacketLogger's default text export truncates at 16 hex bytes per value,
  which is useless for >16-byte packets. Use **"Include Packet Bytes"**
  export mode — each row gains a trailing full-HCI byte sequence.
- Wireshark downlink filter: `btatt.handle == 0x0015 && btatt.opcode == 0x52`.

## Product decisions (resolved)

**Q1 — Head-up gesture.** *Decision: stop reacting.* `GestureRouter` no
longer invokes glance on `0xF5 0x02`. We go firmware-native; user invokes
dashboard with double-tap. More broadly: **audit every custom touchpad
binding and remove anything that fights a firmware default.**

Current binding audit (to be ratified in code):

| Event | Our current binding | Firmware intent | Plan |
|-------|--------------------|-----------------|------|
| `0x01` single-tap | AI-mode page prev/next (phone-driven) | firmware handles page scroll internally | **remove** (Q4 hypothesis) |
| `0x02` head-up | show glance | dashboard trigger (implicit) | **remove** |
| `0x03` head-down | dismiss glance | dashboard-dismiss (implicit) | **remove** |
| `0x17/0x18` long-press | Even AI start/stop | long-press action (`0x26 0x07`) | keep, explicit firmware-bound action |
| `0x1E/0x1F` dash show/close | no-op | firmware dashboard | keep no-op (don't react) |
| `0x20` double-tap | forceRefreshAndShow | dashboard show (also fires `0x1E`) | **remove** |

**Q2 — Double-tap.** *Decision: stop reacting.* Firmware owns it. Our `0x20`
handler becomes a no-op. `0x1E` remains a no-op too — we don't need to
react to dashboard-show at all because data push is cadence-driven, not
event-driven (cheap enough to keep pushing on the 60 s tick regardless of
whether the user is looking).

**Q3 — Quick Note slots.** *Decision: one dedicated contextual slot,
replace-all on every update.* The firmware has 4 slots (1-based, 1..4).
Per the 2026-04-17 sniff, the wire protocol is **replace-all-4-slots** —
every user action emits 4 packets, one per slot, whether or not each
slot changed. We claim **slot 1** as "active contextual note"; slots 2–4
are always written as the empty 7-byte template. Every refresh tick:
if a contextual source wins (transit / notifications), write slot 1 with
its text; if nothing wins, write slot 1 as empty too. Calendar, weather,
news have their own firmware panes — they don't go to the note slot.

Why single-slot rather than one-per-source:
- Firmware renders notes in slot-id order (not our priority order), so
  "contextual on top" across multiple slots isn't achievable.
- Stale notes from past-relevant sources would linger until evicted.
- User isn't running the Even app in parallel — slots 2–4 staying empty
  doesn't waste anything.

Swift surface is a single `setSlotsPackets([QuickNote?], startingSeq:)`
call, not add/delete/edit — that matches the firmware protocol. Phase 1
still needs to probe body char cap + update rate limits.

**Q4 — AI response stays on `0x4E`.** *Correction to an earlier misread.*
`0x4E` is the firmware's native Even AI response surface, not our custom
pipeline. We already emit it; the glitchiness is in our Swift layer's
packet assembly / retry / pagination on top of a firmware-native protocol.

*Decision: keep `0x4E`. Simplify our layer to the minimum the firmware
actually needs.* Do the simplest possible swap of Even's LLM for Claude,
stay as close to the stock AI loop as possible.

**Working hypothesis — firmware paginates, we don't.** Single-tap L/R
scrolls pages instantly, with no phone round-trip — strong evidence
firmware holds the full response and paginates locally. Which means:

- Our `TextPaginator` slicing is redundant at best, and likely the root
  glitch: we chop into 5-line pages, send each as a `0x4E` message with
  pageNum metadata; firmware re-paginates our pages; visual output gets
  mangled.
- The `currentPageNum` / `maxPageNum` fields in
  `EvenAIProto.multiPackListV2` are probably **transport chunk indices**,
  not display page numbers. One logical response = one chunked send.
- `0x30` (auto) / `0x50` (manual) status bytes describe how firmware
  should *display* after receiving the full text, not how we send.

If hypothesis validates in Phase 1:

**Deletions in the AI path (once validated):**
- `COGOS/Session/TextPaginator.swift` — firmware paginates, we don't.
- `EvenAISession.lastPageByTouchpad()` / `nextPageByTouchpad()` — firmware
  owns page scroll, no phone involvement.
- `GestureRouter` `0x01` single-tap handler — becomes no-op (firmware
  handles page-turn in AI mode).
- Retry loops in `sendEvenAIReply` if they turn out to be superstition.

**Simplified:**
- `EvenAIProto.multiPackListV2` — strip display-pagination semantics,
  keep transport chunking only. Single logical response per call.
- `Proto.sendEvenAIData` — drop pagination args, add clean
  `status: UInt8` arg for auto vs manual mode.

**Sub-question: progressive streaming.** Native Even AI visibly streams
blocks of text as the LLM produces them — not a big post-completion dump.
Our current code (`EvenAISession.collect(stream:)`) accumulates the full
SSE response *before* sending anything, which is why our UX feels unlike
native. The fix direction is clear regardless of A/B:

- Use the Claude SSE stream we already have.
- Emit `0x4E` with status `0x30` (auto-displaying) as chunks accumulate —
  not just once at the end.
- Emit final `0x4E` with status `0x40` (display complete) when SSE closes.

What's NOT clear yet (Phase 1 probes):
- Do successive `0x30` sends **replace** firmware's buffer (phone sends
  full accumulated text each time) or **append** (phone sends deltas)?
- Does firmware paginate one blob (Model B) or does phone slice into
  pages and firmware accumulates them into a scroll buffer (Model A)?

Phase 1 validation tasks:
- Trace Gadgetbridge driver for the canonical `0x4E` streaming sequence:
  how intermediate `0x30` sends relate to final `0x40`, whether pages are
  sent individually, what action-byte semantics are.
- **Probe A (distinguishes models):** send one 500-word blob as a single
  `0x4E` with `maxPageNum=1`, `status=0x40`. If firmware shows the whole
  thing with working L/R scroll → firmware paginates (Model B, delete
  `TextPaginator`). If it only shows one screenful → phone paginates
  (Model A, keep `TextPaginator` with corrected constants).
- **Probe B (append vs replace):** send `0x30` with "Hello" then `0x30`
  with "World". If on-glass shows "World" → replace semantics (phone
  sends full accumulated each time). If shows "HelloWorld" → append
  (phone sends deltas).
- Extend `docs/G1_PROTOCOL_REFERENCE.md` with the canonical sequence.

**Q5 — Panes vs Quick Notes.** *Decision: don't duplicate.* If a source has
a dedicated firmware pane (calendar, weather, stocks, news, map), push
there. Quick Notes is reserved for sources without a native pane:
transit, notifications, AI response. Calendar winner selection → firmware
calendar pane is already showing it, no Quick Note needed.

## Proposed phases

### Phase 1 — Research & Proto helpers

**Phase 1a (complete):** byte layouts for the three `0x06` commands are
pinned. See `docs/G1_PROTOCOL_REFERENCE.md`.

**Phase 1b (complete, 2026-04-17):** Quick-Notes `0x1E 0x03` layout pinned
via PacketLogger capture of the official Even Realities iOS app. Swift
helper signature locked in below. Stocks (`0x06 0x04`), News (`0x06 0x05`),
and `0x58` next-up remain blocked on follow-up sniff sessions.

**Phase 1c — empirical probes via `BleProbeView`**:
- Push a single quick note, confirm render in Quick Notes pane.
- Push notes at ids 0..N until firmware rejects or wraps — establishes
  slot cap.
- Push a 256 / 1024 / 4096-byte note body — establishes char cap +
  word-wrap behavior.
- Push rapid successive updates to the same note id — establishes
  update rate limits / visual flicker.
- Push a long AI-style response (500-2000 words) — confirms whether
  firmware can hold a full Claude response or we need chunking /
  summarization.

Code changes:

**Shippable now:**
- Add helpers in `COGOS/Protocol/Proto.swift`:
  ```swift
  func setDashboardTimeAndWeather(now: Date, weather: WeatherInfo) async
  func setDashboardCalendar(_ events: [CalendarEvent]) async
  func setDashboardMode(_ mode: DashboardMode, paneMode: DashboardPaneMode) async
  func setQuickNoteSlots(_ slots: [QuickNote?]) async   // always 4 entries, 1-based
  ```
- New file: `COGOS/Protocol/DashboardTypes.swift` for `DashboardMode`,
  `DashboardPaneMode`, `WeatherId`, `CalendarEvent`, `WeatherInfo`, `QuickNote`.
- New file: `COGOS/Protocol/QuickNoteProto.swift` with
  `setSlotsPackets(_ slots: [QuickNote?], startingSeq: UInt8) -> [Data]` —
  emits 4 packets (non-empty or 7-byte empty template per slot).

**Deferred until follow-up sniff:**
  ```swift
  func setDashboardStocks(_ tickers: [String]) async        // 0x06 0x04
  func setDashboardNews(_ headlines: [NewsHeadline]) async  // 0x06 0x05
  func setDashboardNextUp(_ event: CalendarEvent?) async    // 0x58
  ```

### Phase 2 — Dual-push (bitmap + firmware, with a flag)

- Wire Proto helpers into `GlanceService` behind a debug flag
  (`useFirmwareDashboard: Bool`), default false.
- When true: push time/weather/calendar natively each tick, push winning
  contextual as a quick note.
- When false: existing bitmap path unchanged.
- Use `BleProbeView` + on-device validation to confirm firmware accepts our
  payloads and renders them as expected. Do NOT delete the bitmap path yet.

### Phase 3 — Flip the default, cut the bitmap

Once Phase 2 validates:
- Flip flag to true; remove the flag.
- Delete `GlanceRenderer.swift`, `BmpEncoder.swift`.
- Strip `drawContent(...)` from `GlanceSource` protocol and all sources.
- Remove `BmpTransfer`/`BluetoothManager` deps from `GlanceService.init`.
- Remove `WeatherSource.lastWeather` tuple — replace with the new
  `WeatherInfo` struct fed directly to Proto.
- Remove bitmap-specific cached drawing state (`cachedEvents`,
  `cachedArrivals`, `cachedNotifications`, `cachedHeadlines`) — sources
  return structured data directly for the Quick Note / dashboard payload.
- Update `AppState` wiring.

The AI path (`0x4E`) stays; simplification of its retry/paging layer is
a separate, parallel task per Q4.

### Phase 4 — Gesture rewire

- `GestureRouter` loses `0x02` head-up, `0x03` head-down, `0x20` double-tap
  handlers (all become no-ops — firmware owns these gestures).
- `0x01` single-tap AI-mode page-cycle handler removed if Q4 hypothesis
  holds (firmware scrolls pages internally; phone stays out of it).
- Long-press (`0x17`/`0x18`) for AI start/stop stays — that's an explicit
  firmware-bound long-press action we configured via `0x26 0x07`.

### Phase 5 — Tidy

- Delete `BmpView` probe if no longer useful, or keep for low-level
  bitmap debugging.
- Update `CLAUDE.md` display-constraint section (488 px / 21 px / 5 lines
  is the TEXT path, not glance — rewrite or remove).
- Update `docs/G1_FIRMWARE_FEATURES.md` "unused capabilities" section now
  that dashboard IS used.

## Risks

- **Unknown firmware quirks.** Quick Notes may render with rules we can't
  predict (word-wrap, max lines, flicker on update). Phase 2 dual-push
  is specifically to catch this before committing.
- **Update rate limits.** Firmware might debounce or reject rapid quick-note
  edits. Our 60 s cadence is probably fine, but edge cases (contextual
  winner flipping several times within a minute) could hit a rate limit.
- **Pane mode configuration is sticky.** `0x06 0x06 MODE` may persist
  across reconnects. We should read before writing, or always write on
  connect. Pick a side and document it.
- **Loss of custom typography is permanent.** If the firmware font is
  illegible on the waveguide (the text path uses 21 px default), we're
  stuck with it. Mitigation: probe early in Phase 2 before committing.

## Rollback

Each phase is independently revertible:
- Phase 1 adds code but changes no runtime behavior.
- Phase 2 is flag-gated.
- Phase 3 is the point of no return — git-revertable but not runtime-toggleable.

Land Phase 2 and leave it flag-gated for a few days of real wear before
Phase 3.

## Verification checklist (post-Phase 3)

1. Connect + auto-reconnect unchanged.
2. Head-up or double-tap shows firmware dashboard with time/weather/calendar.
3. Transit is relevant near a stop → Quick Notes pane shows arrival text.
4. Notification lands → Quick Notes pane shows it (until NCS passthrough
   ships per spec item #2).
5. No contextual source → Quick Notes pane shows news headlines.
6. AI response still paginates via `0x4E` text packets, separate from dash.
7. `ls COGOS/Glance/` no longer lists `GlanceRenderer.swift` or
   `BmpEncoder.swift`.
8. Build compiles with no bitmap references in `Glance/`.
