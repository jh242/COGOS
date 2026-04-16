# Firmware-Aligned Refactors

Opportunities identified after reverse-engineering the G1 BLE protocol via
Gadgetbridge and MentraOS (see `docs/G1_PROTOCOL_REFERENCE.md` and
`docs/G1_FIRMWARE_FEATURES.md`).

These are **big refactors** — not bugs, not simplifications. Each would shift
work from the phone to the glasses firmware, improving latency, battery, and
robustness at the cost of giving up per-pixel control.

---

## 1. Use firmware dashboard for standard panes

**What:** Replace the bitmap glance with firmware-native dashboard commands
for time/weather/calendar. Keep the bitmap pipeline for AI responses only.

**Why:** The glasses already render time + weather + up to 8 calendar events
natively with no phone round-trip per refresh. Every 60 s we currently:
1. Query EventKit, fetch weather from wttr.in, reverse-geocode location
2. Render a 640×200 BMP via Core Graphics (~16 KB)
3. Chunk into 194-byte packets @ 8 ms intervals
4. Verify CRC32-XZ on both arms

Firmware equivalent: one `0x06 0x01 …` (time+weather) packet + one chunked
`0x06 0x03 …` (calendar) packet. No bitmap upload at all.

**Trade-off:** Loses the two-column custom layout + SF Pro typography. Can't
show transit or headlines (no firmware pane for either).

**Suggested hybrid:** Firmware dashboard for the idle glance; fall back to
bitmap only when a contextual source (transit / notifications / news) wins.

**Effort:** Medium. Need `Proto` helpers for the `0x06` family + swap the
`GlanceService.sendBitmap()` path.

---

## 2. Push iOS notifications via NCS passthrough

**What:** Forward `UNNotificationCenter` deliveries through `0x4B
NOTIFICATION_SEND_CONTROL` instead of re-rendering them into the glance.

**Why:** Firmware handles notification display + timeout + dismissal
autonomously. `0x4F NOTIFICATION_AUTO_DISPLAY_SET` controls wake-on-notify.
The current `NotificationSource` requires the user to open the glance to
see anything — the firmware path is push-driven and zero-latency.

**Payload:** Apple NCS JSON (chunked):
```json
{"ncs_notification": {"msg_id": …, "app_identifier": …, "title": …, "message": …, …}}
```
Plus `0x4C NOTIFICATION_CLEAR_CONTROL <msg_id>` on dismiss.

**Trade-off:** Firmware controls the rendering — no custom layout, no typography.

**Effort:** Medium. Needs a `UNUserNotificationCenterDelegate` that forwards
to `Proto` + a new `CommandNotificationSend` handler. `NotificationWhitelist`
already covers the `0x04` side of this.

---

## 3. Wear-state auto-show/hide

**What:** Auto-show the glance when glasses go from not-worn → worn; dismiss
when worn → not-worn or lid-open.

**Why:** Firmware emits these reliably as `0xF5` events: `0x06` worn, `0x07`
not-worn-no-case, `0x08` case lid open. We currently ignore all three.
Requires enabling wear detection via `0x27 WEAR_DETECTION_SET`.

**Effort:** Small. Wire into `GestureRouter` alongside existing head-up.

---

## 4. Battery / case state observable

**What:** Track glasses + case battery from `0xF5` telemetry and surface in
the iOS UI (e.g. a `BatteryState` `@Published` on `BluetoothManager`).

**Source events:**
- `0x09` STATE_CHARGING, payload `00`/`01`
- `0x0A` INFO_BATTERY_LEVEL, payload `00–64` (0–100 %)
- `0x0E` STATE_CASE_CHARGING
- `0x0F` INFO_CASE_BATTERY_LEVEL

Plus a `0x2C INFO_BATTERY_AND_FIRMWARE_GET` on connect for the initial value.

**Effort:** Small. Parse in `GestureRouter.handle(...)` instead of the current
silent discard, publish via `BluetoothManager`.

---

## 5. Expose additional settings

Settings currently phone-only or unexposed, all trivially wrappable in `Proto`:

| Setting | Command | Notes |
|---------|---------|-------|
| Brightness | `0x01 BRIGHTNESS_SET` | Level 0–0x2A + auto flag |
| Wear detection | `0x27 WEAR_DETECTION_SET` | Prerequisite for #3 |
| Notification auto-display | `0x4F` | On/off + timeout seconds |
| Silent mode | `0x03 SILENT_MODE_SET` | Also emitted as `0xF5 0x04/0x05` |
| Language | `0x3D LANGUAGE_SET` | 8 options |
| Display geometry | `0x26 HARDWARE_SET` + `0x02` | Height + depth, with 5s preview |
| Double-tap / long-press actions | `0x26` + `0x05 / 0x07` | Rebind on-device gestures |

`SettingsView` currently only exposes head-up angle. A "Glasses Hardware"
section would be a natural fit.

**Effort:** Small per setting, mostly UI work.

---

## 6. Triple-tap / mode-cycle semantics

**What:** The current code fires `session.resetSession()` on `0xF5 0x04/0x05`,
which Gadgetbridge identifies as `ACTION_SILENT_MODE_ENABLED/DISABLED`.
These events fire any time silent mode toggles — including as a side-effect
of triple-tap on the touchpad. Result: every silent-mode toggle wipes AI
history and paints "Session reset" on the glasses.

**Status:** Already patched in this pass — the handler is now a no-op.

**Follow-up:** The original intent (per `CLAUDE.md`) was that triple-tap
cycles session modes (`chat` → `code` → `cowork`). But:
- `SessionMode` enum only has `chat` and `code` (no cowork)
- No mode-cycling code exists
- `0x04/0x05` is the silent-mode result event, not the triple-tap itself

If mode-cycling is still wanted, the right hook is either the silent-mode
event (accept it as the intended gesture) or a firmware-level action
rebinding via `0x26 0x05 DOUBLE_TAP_ACTION`. Needs a product decision.

---

## 7. Teleprompter / transcribe / translate / navigation

**What:** Firmware-native apps we don't use. All have dedicated command
families: `0x09` teleprompter, `0x0D` transcribe, `0x0F` translate, `0x0A`
navigation (with INIT/TRIP_STATUS/MAP_OVERVIEW/PANORAMIC_MAP/SYNC/EXIT/
ARRIVED sub-commands).

**When it'd matter:** If we ever want speech transcription *displayed
directly on-glass* without phone STT, or turn-by-turn walking navigation.
Currently out of scope — noting for completeness.

---

## Recommendation

Prioritize **#3 (wear state)** and **#4 (battery)** first — they're small,
high-value, and already fire at us as events we're currently discarding.

**#1 (firmware dashboard)** is the biggest lever but the largest refactor;
defer until we have a concrete reason to reduce bitmap-transfer cost.
