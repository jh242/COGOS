# Plan: Glance provider refactor + 5 s dashboard push

## Goal

Replace the tier/relevance/winner-picks-one glance architecture with an
array of **context providers**, each managing its own cache and display
eligibility. Drive a 5 s full-dashboard push that doubles as the BLE
keepalive (matching the Even Realities iOS app's cadence). Delete the
bitmap-mode rendering path entirely.

## Why

- The current `GlanceSource` protocol conflates fetching, relevance
  scoring, display eligibility, and bitmap drawing. `GlanceService`
  reaches into each source's quirks (transit distance, calendar event
  windows) to decide what to show.
- Even app pushes the full dashboard every ~5 s and has no separate
  heartbeat (`docs/G1_PROTOCOL_REFERENCE.md:118`). Matching their
  cadence gives us near-zero head-up latency and lets us delete our
  `0x25` heartbeat loop.
- WeatherKit (iOS 16+) returns the same data as Apple Weather,
  replacing the wttr.in scraping hack with a supported API.
- Raising the deployment floor to iOS 18 strips a pile of `#available`
  branches and deprecated-API fallbacks.

## Architecture

```
                    ┌─────────────────────────────────────────────┐
                    │                 GlanceService                │
                    │                                              │
                    │     ┌──────────────────────────────────┐     │
  every 5 s ───────►│     │ tick()                            │    │
                    │     │  1. build GlanceContext           │    │
                    │     │  2. weather.refresh(ctx)          │    │
                    │     │  3. for p in providers:           │    │
                    │     │        await p.refresh(ctx)       │    │
                    │     │  4. push()                        │    │
                    │     └──────────────────────────────────┘     │
                    │                     │                        │
                    │                     ▼                        │
                    │     ┌──────────────────────────────────┐     │
                    │     │ push()                            │    │
                    │     │   time+weather  (always)          │    │
                    │     │   slots         (if changed)      │    │
                    │     │   commit        (always)          │    │
                    │     └──────────────────────────────────┘     │
                    └─────────────────────────────────────────────┘
                           │                                  │
                           │                                  │
                           ▼                                  ▼
                  ┌───────────────────┐          ┌────────────────────────┐
                  │   WeatherSource    │          │   ContextProvider[]     │
                  │   (special)        │          │   sorted by priority     │
                  │                    │          │                          │
                  │ currentInfo        │          │  Calendar      (pri 0)   │
                  │     │              │          │  Transit       (pri 1)   │
                  │     ▼              │          │  Notifications (pri 2)   │
                  │ 0x06 0x01          │          │  News          (pri 3)   │
                  │ TIME_AND_WEATHER   │          │                          │
                  └───────────────────┘          │  each owns:              │
                                                  │   - internal cache       │
                                                  │   - refresh cadence      │
                                                  │   - display eligibility  │
                                                  │   - currentNote: QN?     │
                                                  └────────────────────────┘
                                                              │
                                                              ▼
                                                  ┌────────────────────────┐
                                                  │ sorted.compactMap(note)│
                                                  │        .prefix(4)       │
                                                  │                         │
                                                  │  slot1 ← highest-pri    │
                                                  │  slot2 ← next           │
                                                  │  slot3 ← next           │
                                                  │  slot4 ← next           │
                                                  └────────────────────────┘
                                                              │
                                                              ▼
                                                       0x1E 0x03 × 4
                                                       (replace-all-4)

                                                              │
                                                              ▼
                                                        0x22 0x05
                                                       (right-arm commit)
```

**Key invariants**

1. `GlanceService` has zero knowledge of what any provider does. It
   loops, it sorts by priority, it pushes. Dumb.
2. A provider's `currentNote` is the sole signal of "show me this".
   Nil means "don't show me". Display eligibility (transit distance,
   calendar window, notification age) lives inside the provider.
3. `refresh()` is called every tick. The provider decides internally
   whether to do I/O or early-return. Cheap cadence check → no-op most
   ticks.
4. Providers with no data compact out of the slot array. Top 4 win;
   overflow is dropped.

## Protocol

```swift
protocol ContextProvider: AnyObject {
    var name: String { get }
    var priority: Int { get }                    // lower = higher priority
    func refresh(_ ctx: GlanceContext) async
    var currentNote: QuickNote? { get }
}
```

No `shouldFetch`, no `relevance`, no `tier`, no `drawContent`. The
protocol is the minimum shape that lets the service drive the loop.

## Provider table

| Provider       | Priority | Internal `refresh` cadence           | `currentNote` is nil when                       |
|----------------|---------:|--------------------------------------|-------------------------------------------------|
| Calendar       |        0 | refetch if `lastFetch > 5 min`       | no event in next 24 h                           |
| Transit        |        1 | refetch if `lastFetch > 1 min`       | no station within 200 m, or no upcoming arrivals|
| Notifications  |        2 | refetch if `lastFetch > 30 s`        | no delivered notification in last 10 min        |
| News           |        3 | refetch if `lastFetch > 30 min`      | no cached headlines                             |
| Weather\*      |        — | refetch if `lastFetch > 15 min`      | not applicable — feeds time+weather pane        |

\* Weather is not a `ContextProvider` — it feeds the dedicated firmware
time+weather pane, not the Quick Notes slots. Same `refresh` shape,
parallel path on `GlanceService`.

## Push loop

```swift
private func tick() async {
    let now = Date()
    let ctx = buildContext(now: now)

    await weather.refresh(ctx)
    for p in providers {
        await p.refresh(ctx)
    }
    await push(now: now)
}

private func push(now: Date) async {
    let info = weather.currentInfo ?? .empty
    _ = await proto.setDashboardTimeAndWeather(now: now, weather: info)

    let notes = providers
        .sorted { $0.priority < $1.priority }
        .compactMap { $0.currentNote }
    let slots: [QuickNote?] = (0..<4).map {
        notes.indices.contains($0) ? notes[$0] : nil
    }
    if slots != lastSlots {
        _ = await proto.setQuickNoteSlots(slots)
        lastSlots = slots
    }
    _ = await proto.commitDashboard()
}

func startTimer() {
    refreshTimer = Task { [weak self] in
        while !Task.isCancelled {
            await self?.tick()
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }
}
```

Tick-then-sleep so the first push lands immediately at connect, not
5 s later. No minute alignment (cadence is 5 s, alignment moot).

## Files

**New**
- `COGOS/Glance/ContextProvider.swift` — protocol definition

**Rewritten**
- `COGOS/Glance/GlanceService.swift` — 5 s loop, provider iteration, multi-slot push
- `COGOS/Glance/Sources/CalendarSource.swift` — conforms to `ContextProvider`
- `COGOS/Glance/Sources/TransitSource.swift` — conforms; clears `currentNote` when > 200 m from station
- `COGOS/Glance/Sources/NotificationSource.swift` — conforms
- `COGOS/Glance/Sources/NewsSource.swift` — conforms
- `COGOS/Glance/Sources/WeatherSource.swift` — drops `GlanceSource`, uses WeatherKit
- `COGOS/Platform/Settings.swift` — drop `useFirmwareDashboard`
- `COGOS/App/AppState.swift` — drop heartbeat, always set dashboard mode at connect
- `COGOS/BLE/GestureRouter.swift` — drop head-up + dismiss handlers (bitmap-only)

**Deleted**
- `COGOS/Glance/GlanceSource.swift`
- `COGOS/Glance/Sources/TimeSource.swift`
- `COGOS/Glance/GlanceRenderer.swift`
- `COGOS/Glance/GlanceDrawing.swift` (if it exists; audit)
- `COGOS/Protocol/BmpTransfer.swift` — audit callers first; may be used by debug `BmpView`
- `COGOS/Protocol/Proto.swift::sendHeartBeat` — method only
- Settings UI toggle for `useFirmwareDashboard`

## Sequencing

### Phase 0 — Prep
- [ ] Bump `IPHONEOS_DEPLOYMENT_TARGET = 18.0` in Xcode project
- [ ] Strip every `#available(iOS 15/16/17, *)` branch and its `else` arm
- [ ] Update CLAUDE.md iOS version line
- [ ] Enable WeatherKit capability on the App ID
- [ ] Add `WeatherKit` to entitlements file
- [ ] Add `Equatable` conformance to `QuickNote` in `DashboardTypes.swift`

**Exit:** builds clean on iOS 18 SDK with no availability branches remaining.

### Phase 1 — Delete bitmap mode
- [ ] Audit `BmpTransfer` callers; delete the file if only `GlanceService` used it
- [ ] Delete `GlanceRenderer.swift`, `GlanceDrawing.swift`, `TimeSource.swift`
- [ ] Remove `isShowing`, `showGlance`, `forceRefreshAndShow`, `dismiss`, `sendBitmap`, `bmpTransfer`, `renderer` from `GlanceService`
- [ ] Remove `useFirmwareDashboard` from `Settings` + UI
- [ ] Unconditional `proto.setDashboardMode(.dual, paneMode: .quickNotes)` at connect
- [ ] Remove head-up / dismiss branches from `GestureRouter` (double-tap stays for AI session exit)
- [ ] Remove `drawContent` from `GlanceSource` protocol (dies entirely in phase 4)

**Exit:** app still builds, dashboard still updates on the existing 60 s timer.

### Phase 2 — Drop heartbeat
- [ ] Delete `AppState.startHeartbeat`, `stopHeartbeat`, `heartbeatTask`
- [ ] Delete `Proto.sendHeartBeat`
- [ ] Verify glasses stay connected for > 60 s between ticks (they should — the 60 s dashboard push is already under the 32 s disconnect threshold once we're on 5 s)

**Exit:** no `0x25` writes appear in a Wireshark capture; connection holds.

### Phase 3 — New protocol + weather split
- [ ] Add `ContextProvider.swift`
- [ ] Rewrite `WeatherSource` as standalone (no `GlanceSource`), WeatherKit-backed, with `refresh(ctx)` + `currentInfo`
- [ ] Delete wttr.in code path

**Exit:** weather still populates the time+weather pane; Apple Weather comparison matches.

### Phase 4 — Migrate providers (easy → hard)
- [ ] `NotificationSource` → `ContextProvider`
- [ ] `NewsSource` → `ContextProvider`
- [ ] `CalendarSource` → `ContextProvider`
- [ ] `TransitSource` → `ContextProvider` (clears `currentNote` when > 200 m from last-known station)
- [ ] Delete `GlanceSource.swift`

**Exit:** all four providers implement the new protocol; old protocol is gone.

### Phase 5 — Service rewrite
- [ ] Replace `GlanceService.refresh` with the 5 s `tick` + `push` loop
- [ ] Multi-slot fill, diff-gate against `lastSlots: [QuickNote?]`
- [ ] Delete `winningSource`, `winningSourceText`, `lastDashboardSignature`, `fetchCached`, `CandidateResult`, `lastCandidates`
- [ ] Update logging to show per-slot assignments

**Exit:** on-device, glasses cycle through real data. Wireshark shows ~5 s cadence matching Even app pattern.

## Verification

- Build: clean against iOS 18 SDK, no warnings about `#available`
- Connect: glasses receive `0x06 0x06 MODE (dual, quickNotes)` once, then `0x06 0x01 + commit` every ~5 s
- Heartbeat: no `0x25` traffic
- Calendar: remove all events from EventKit → slot 1 empty, Transit shifts up
- Transit: walk > 200 m from station (or mock location) → slot empties on next tick
- Notifications: receive a push → appears within 5 s
- Weather: temperature + condition match Apple Weather app for the same coordinates
- Clock: visible HH:MM on glasses stays within 1 s of phone clock (5 s refresh keeps drift invisible)

## Open questions

None. All decisions locked in discussion:
- iOS 18 minimum, WeatherKit yes, bitmap mode deleted entirely
- 5 s cadence, no minute alignment, heartbeat deleted
- Multi-slot fill by priority, `compactMap` + `prefix(4)`
- Providers own all display logic; service is dumb
- `refresh(ctx)` is the single provider method — no `shouldFetch` / `relevance` split
- No head-up push (firmware handles head-up from latched state, refreshed every 5 s)
