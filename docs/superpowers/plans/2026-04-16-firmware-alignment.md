# Firmware Alignment — Implementation Plan

Companion to `docs/superpowers/specs/2026-04-16-firmware-aligned-refactors.md`.
That doc identifies *what* to refactor; this doc is *how*, split into "do now"
and "plan together".

---

## Status

- [x] **#6 silent-mode side-effect** — GestureRouter no longer resets session
      on `0xF5 0x04/0x05`. Patched during the simplify pass.
- [ ] **#3 wear-state auto-show/hide** — low-hanging fruit, implementing now.
- [ ] **#4 battery/case observable** — low-hanging fruit, implementing now.
- [ ] **#1 firmware dashboard hybrid** — plan together.
- [ ] **#2 NCS notification passthrough** — plan together.
- [ ] **#5 expose additional settings** — plan together (UI scope).
- [ ] **#6 triple-tap mode cycle** — plan together (product decision).
- [ ] **#7 teleprompter/transcribe/translate/navigation** — deferred per spec.

---

## Low-hanging fruit (implementing now)

### #3 — Wear-state auto-show/hide

Firmware emits `0xF5` events we currently discard:
- `0x06` STATE_WORN → show glance
- `0x07` STATE_NOT_WORN_NO_CASE → dismiss glance
- `0x08` STATE_IN_CASE_LID_OPEN → dismiss (glasses are in the case)
- `0x0B` STATE_IN_CASE_LID_CLOSED → no-op

Requires sending `0x27 WEAR_DETECTION_SET` once on connect, otherwise the
firmware may not emit these events. Command shape (per Gadgetbridge):
`0x27 <enable 0x00/0x01>`.

Both arms emit wear events — treat first one in a short window as the
canonical signal; debounce to avoid double-show.

### #4 — Battery / case state observable

Firmware emits battery telemetry via `0xF5` already:
- `0x09` STATE_CHARGING, payload `0x00`/`0x01`
- `0x0A` INFO_BATTERY_LEVEL, payload `0x00–0x64` (0–100 %)
- `0x0E` STATE_CASE_CHARGING
- `0x0F` INFO_CASE_BATTERY_LEVEL

Each arm reports independently. Add a `BatteryState` struct on
`BluetoothManager`:
```swift
struct BatteryState {
    var leftPercent: Int?
    var rightPercent: Int?
    var casePercent: Int?
    var leftCharging: Bool
    var rightCharging: Bool
    var caseCharging: Bool
}
```
Published so `SettingsView` / a debug surface can observe.

On connect, also kick off `0x2C INFO_BATTERY_AND_FIRMWARE_GET` once to seed
initial values instead of waiting for the first firmware-emitted tick.

**Plumbing change:** GestureRouter currently receives only
`(lr, notifyIndex)`. Needs full payload for 0x0A / 0x0F (second byte = level).
Change the signature to pass the entire packet data.

---

## Plan-together items

### #1 — Firmware dashboard hybrid

The glasses natively render time + weather + up to 8 calendar events. Sending
one `0x06 0x01` (time+weather) + one `0x06 0x03` (calendar, chunked) packet
replaces our current 16 KB BMP upload every 60 s.

**Open questions:**
- Keep bitmap path for transit / notifications / news (sources with no
  firmware pane), and swap only when *none* are winning?
- What happens to left-column fixed sources (time, weather) when a
  contextual source wins — still our bitmap, or firmware layered?
- How do we unify dismiss? `0x18` exits our bitmap; what's the equivalent
  for a firmware dashboard that was shown programmatically?
- Timezone: firmware time pane uses its own clock. We currently push our
  own; delta is usually seconds but not zero.

**Effort:** Medium. Touches `GlanceService.sendBitmap()` split, new `Proto`
helpers for the 0x06 family, careful state management for which surface is
currently displayed.

### #2 — NCS notification passthrough

Forward iOS `UNUserNotificationCenter` deliveries through
`0x4B NOTIFICATION_SEND_CONTROL` instead of re-rendering into the glance.

Payload shape (chunked via existing `getNotifyPackList`):
```json
{"ncs_notification": {
    "msg_id": 1234, "app_identifier": "com.apple.mobilemail",
    "title": "…", "subtitle": "…", "message": "…",
    "display_name": "Mail", "time_s": 1712944080
}}
```

**Open questions:**
- Where does the notification feed come from? iOS does NOT deliver
  notifications-for-other-apps to a third-party app. Options:
  - Require users to install an NCS-enabled Notification Service Extension
    (limited — only our own notifications)
  - Mirror only our own app notifications (trivial but tiny surface)
  - Use iOS Focus / Live Activities indirectly (unclear feasibility)
- Dismiss path: `0x4C NOTIFICATION_CLEAR_CONTROL <msg_id>` — needs a
  bidirectional map from OS notification identifiers to msg_ids.
- `NotificationWhitelist` already sends the `0x04` side; reuse the same
  app bundle IDs for filter logic.

**Effort:** Medium–Large. The iOS side is the hard part, not the BLE side.

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
| Display depth (Z) | `0x26 0x02 <depth>` | Slider |
| Double-tap action | `0x26 0x05 <action>` | Picker |
| Long-press action | `0x26 0x07 <action>` | Picker |

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
- Add `cowork` to `SessionMode`? If yes, wire system prompt + history
  persistence per the CLAUDE.md table.
- Accept `0x04/0x05` as the trigger (pragmatic — it fires on triple-tap),
  or rebind via `0x26 0x05/0x07` to a clean user action?
- Cycle order: `chat → code → cowork → chat`? Or mode-per-arm?

### #7 — Teleprompter / transcribe / translate / navigation

Firmware-native apps. Noted in spec as out of scope. Skip unless a concrete
use case surfaces.
