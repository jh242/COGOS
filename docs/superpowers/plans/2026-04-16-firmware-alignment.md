# Firmware Alignment — Implementation Plan

Companion to `docs/superpowers/specs/2026-04-16-firmware-aligned-refactors.md`.
That doc identifies *what* to refactor; this doc is *how*, split into "do now"
and "plan together".

---

## Status

- [x] **#6 silent-mode side-effect** — GestureRouter no longer resets session
      on `0xF5 0x04/0x05`. Patched during the simplify pass.
- [x] **#3 wear-state auto-show/hide** — `GestureRouter` handles
      `0xF5 0x06/0x07/0x08`; `Proto.setWearDetection(enabled:)` called on
      connect from `AppState`. Debounce is **not** yet implemented; both arms
      fire events and can double-trigger `showGlance()`. See follow-ups below.
- [x] **#4 battery/case observable** — `BluetoothManager.BatteryState`
      published; `GestureRouter` parses `0xF5 0x09/0x0A/0x0E/0x0F` with full
      payload; `Proto.queryBatteryAndFirmware()` seeds on connect. No UI
      surface yet — debug-only observability.
- [>] **#1 firmware dashboard hybrid** — superseded by
      [`2026-04-16-firmware-dashboard-migration.md`](./2026-04-16-firmware-dashboard-migration.md),
      which takes a more aggressive "retire the bitmap" stance with
      phased rollout. Follow that plan; the thumbnail below is kept for
      cross-reference only.
- [ ] **#2 NCS notification passthrough** — **blocked on iOS capability.**
      Third-party apps cannot read other apps' notifications without MDM or
      jailbreak. A Notification Service Extension only touches pushes sent to
      COGOS itself. Revisit only if we find a product use for forwarding
      COGOS's own notifications, otherwise defer indefinitely.
- [ ] **#5 expose additional settings** — plan together (UI scope). No
      blockers; waiting on #1 to land so we don't design around a doomed
      glance surface.
- [ ] **#6 triple-tap mode cycle** — product decision. `SessionMode` enum
      still lacks `cowork` (`COGOS/Session/SessionMode.swift`) despite
      `CLAUDE.md` documenting it. Doc/code drift to resolve as part of this.
- [ ] **#7 teleprompter/transcribe/translate/navigation** — deferred per spec.

---

## Shipped

### #3 — Wear-state auto-show/hide (shipped)

Implementation landed in:
- `COGOS/BLE/GestureRouter.swift:46-54` — `0x06` shows glance,
  `0x07`/`0x08` dismiss + exit session.
- `COGOS/Protocol/Proto.swift:87-90` — `setWearDetection(enabled:)`.
- `COGOS/App/AppState.swift:92` — enabled on connect.

**Follow-ups not yet done:**
- No debounce across L/R arms. Both emit wear events; the current handler
  races. Low-risk today because `glance.showGlance()` and `session.exitAll()`
  are idempotent-ish, but flicker is possible. Add a 200-300 ms debounce in
  `GestureRouter` keyed on `(notifyIndex)`, ignoring the second arm.
- When #1 (firmware dashboard) lands, "show glance" will mean something
  different. The wear handler will need a one-line swap from bitmap-glance
  to firmware-dashboard show.

### #4 — Battery / case state observable (shipped)

Implementation landed in:
- `COGOS/BLE/BluetoothManager.swift:28-42` — `BatteryState` struct published.
- `COGOS/BLE/GestureRouter.swift:55-69` — parses `0x09/0x0A/0x0E/0x0F`.
- `COGOS/Protocol/Proto.swift:93-95` — `queryBatteryAndFirmware()`.
- `COGOS/App/AppState.swift:93` — seeded on connect.

**Follow-ups not yet done:**
- No UI surface. `SettingsView` is the natural home; gated on #5 scope.
- `0x2C` response parsing: we send the query but I haven't traced that the
  firmware response actually lands in `BatteryState` (the `0xF5` telemetry
  path does, but the `0x2C` reply is a different frame). Verify end-to-end
  once the UI lands.

---

## Plan-together items

### #1 — Firmware dashboard (see separate plan)

**Superseded by [`2026-04-16-firmware-dashboard-migration.md`](./2026-04-16-firmware-dashboard-migration.md).**
That plan takes a stronger position than "hybrid": retire the bitmap glance
entirely, push time/weather/calendar via `0x06` family, push contextual
sources (transit, notifications) via `0x1E` Quick Notes, keep AI responses
on `0x4E`. Five phases, flag-gated rollout, verification checklist.

Open questions from earlier drafts (kept here for cross-reference):
- Bitmap-for-contextual hybrid vs. Quick-Notes-only → dashboard plan picks
  Quick Notes.
- Dismiss unification → dashboard plan treats it as cadence-driven, no
  programmatic dismiss needed.
- Timezone drift → punt to firmware clock once migration lands.

### #2 — NCS notification passthrough (blocked on iOS)

**Status: blocked.** iOS does not let a third-party app read other apps'
notifications. A Notification Service Extension only intercepts push
notifications delivered to *our* app, not system-wide. Without MDM
enrollment or jailbreak, the entire premise of "forward iOS notifications
to the glasses" is not achievable on stock iOS.

What this means:
- Options listed in earlier drafts (NSE, mirror-own-only, Focus/Live
  Activities) either don't apply or give a surface too small to justify
  the work.
- The `0x4B` BLE plumbing is still correct — that side of the work would
  be straightforward whenever we *do* have a notification source to feed.
- `NotificationWhitelist` (`0x04`) is already in the codebase and is used
  by the *firmware's* NCS consumer — unrelated to our ability to feed it.

**Recommendation:** park this item. If COGOS later sends its own push
notifications to itself (e.g. relay-status alerts), we can forward those
— but mirror-our-own-pushes is a tiny surface and doesn't justify the
`UNUserNotificationCenterDelegate` plumbing yet.

### #5 — Expose additional settings

Settings to add to `SettingsView` (and corresponding `Proto` helpers):

| Setting | Command | UI |
|---------|---------|-----|
| Brightness | `0x01 <level 0..0x2A> <auto 0/1>` | Slider + toggle |
| Wear detection | `0x27 <0/1>` | Toggle (tied to #3) |
| Notification auto-display | `0x4F <on/off> <timeout_s>` | Toggle + slider |
| Silent mode | `0x03 <0/1>` | Toggle |
| Language | `0x3D <enum 0..7>` | Picker |
| Display height (Y) | `0x26 0x02 <height>` | Slider, 5 s preview |
| Display depth (Z) | `0x26 0x0?`¹ `<depth>` | Slider |
| Double-tap action | `0x26 0x05 <action>` | Picker |
| Long-press action | `0x26 0x07 <action>` | Picker |

¹ The Y/Z sub-command bytes need pinning from Gadgetbridge — earlier
drafts listed both as `0x26 0x02` which is clearly wrong (two different
settings cannot share a sub-command). Likely `0x02` = height and depth
is a neighbouring sub-command, but confirm before UI work.

**Open questions:**
- Do we want to persist each setting in `UserDefaults` and re-apply on
  connect, or trust the glasses firmware to remember?
- Display geometry has a 5 s preview window — UX should reflect "commit"
  vs "preview". SwiftUI drag gesture with debounced commit?
- Language enum values need cross-referencing with Gadgetbridge
  (`LANGUAGE_*` constants) — doc it in `G1_PROTOCOL_REFERENCE.md` before
  shipping a picker.

**Effort:** Small per setting, but the UI work is non-trivial if we want
it to feel native.

### #6 — Triple-tap / mode cycle

`CLAUDE.md` documents triple-tap as `chat → code → cowork`. But:
- `SessionMode` enum has only `chat` and `code`.
- No mode-cycling code exists anywhere.
- `0xF5 0x04 / 0x05` are silent-mode *result* events, not the triple-tap
  gesture itself. They fire whenever silent mode toggles — which happens
  to include triple-tap, but also any other silent-mode trigger.

**Product decisions needed:**
- Add `cowork` to `SessionMode`? `CLAUDE.md` documents it but
  `COGOS/Session/SessionMode.swift` still only has `chat`/`code`. Doc/code
  drift to resolve as part of this decision. If yes, wire system prompt +
  history persistence per the CLAUDE.md table.
- Accept `0x04/0x05` as the trigger (pragmatic — it fires on triple-tap),
  or rebind via `0x26 0x05/0x07` to a clean user action?
- Cycle order: `chat → code → cowork → chat`? Or mode-per-arm?

### #7 — Teleprompter / transcribe / translate / navigation

Firmware-native apps. Noted in spec as out of scope. Skip unless a concrete
use case surfaces.
