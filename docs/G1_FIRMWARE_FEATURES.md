# G1 Firmware Features

What the G1 firmware does natively — features exposed over BLE that don't
require the phone to do any rendering or heavy lifting. Useful for deciding
what COGOS should delegate to the firmware versus render on-phone and ship
as bitmaps.

**Source:** reverse-engineered from Gadgetbridge PR #4553
(`G1Communications.java`, `G1Constants.java`, `G1SideManager.java`,
`G1DeviceSupport.java`) plus MentraOS `G1.java`. Byte codes are cross-referenced
in [`G1_PROTOCOL_REFERENCE.md`](G1_PROTOCOL_REFERENCE.md).

---

## Connection lifecycle

The glasses are dual-BLE and require a specific dance at connect time.

1. **Request MTU 251** on both sides (firmware actually caps payload at 180 B).
2. **Subscribe** to Nordic UART RX characteristic on both sides.
3. **Per-side init queries** (both sides):
   - `INFO_BATTERY_AND_FIRMWARE_GET` (0x2C)
   - `SYSTEM_CONTROL` + `FIRMWARE_BUILD_STRING_GET` (0x23 0x74)
   - `SILENT_MODE_GET` (0x2B)
4. **Left only:**
   - `BRIGHTNESS_GET` (0x29)
   - `INFO_SERIAL_NUMBER_GLASSES_GET` (0x34) — encodes frame shape + color
5. **Right only:**
   - `HEAD_UP_ANGLE_GET` (0x32)
   - `HARDWARE_DISPLAY_GET` (0x3B)
   - `WEAR_DETECTION_GET` (0x3A)
   - `NOTIFICATION_AUTO_DISPLAY_GET` (0x3C)
6. **Post-init background tasks** (after both sides ready):
   - Set dashboard mode, language, time
   - Start heartbeat loop (critical — see below)
   - Push notification app whitelist to **left only** (large payload)
   - Sync calendar events

**Heartbeat:** glasses auto-disconnect after ~32 s of BLE silence. Gadgetbridge
sends a ping every 8 s with a 25 s target and 10 s jitter budget. COGOS
already does this at 8 s.

---

## On-device dashboard

A firmware-rendered HUD — no phone rendering needed for the built-in panes.

### Modes (`DASHBOARD_SET` 0x06 subcommand `0x06` `MODE`)

| Byte | Mode | Description |
|------|------|-------------|
| `0x00` | `FULL` | Full-screen dashboard |
| `0x01` | `DUAL` | Split pane: time/weather + secondary |
| `0x02` | `MINIMAL` | Minimal HUD |

### Secondary pane contents (DUAL mode)

| Byte | Pane |
|------|------|
| `0x00` | Quick notes |
| `0x01` | Stocks |
| `0x02` | News |
| `0x03` | Calendar |
| `0x04` | Map |
| `0x05` | Empty |

### Pane sub-commands (all under `DASHBOARD_SET` 0x06)

| Byte | Sets |
|------|------|
| `0x01` | Time + weather (combined; see below) |
| `0x02` | Weather only |
| `0x03` | Calendar (up to 8 events, chunked) |
| `0x04` | Stocks |
| `0x05` | News |
| `0x07` | Map |

### Time + weather packet (`0x06 0x15 0x00 seq 0x01 …`)

- Time: uint32 unix seconds @ offset 5, uint64 millis @ offset 9
- Weather: `icon_byte, temp_celsius_byte, unit_byte, 12/24h_byte`
- Temperature always sent in Celsius; the `unit_byte` only controls display.
- Icon `0x01` (night) is substituted for `0x10` (sunny) after sunset.

### Calendar

- Max **8 events** (4 pages × 2 per page in UI).
- Per event fields, TLV-style: `0x01 len title`, `0x02 len timeStr`, `0x03 len location`.
- Time strings are app-formatted ("HH:mm" or "h:mm[am|pm]"); firmware does
  not parse timestamps — just renders the string it's given.
- Payload is chunked (multi-packet); Gadgetbridge clears stale events 5 min
  after start time.

---

## Notifications

Fully firmware-driven — phone supplies JSON, glasses render and time out.

### App whitelist (`0x04 NOTIFICATION_APP_LIST_SET`)

Chunked JSON, sent to **left side only**:
```json
{
  "calendar_enable": false,
  "call_enable": false,
  "msg_enable": false,
  "ios_mail_enable": false,
  "app": {
    "list": [{"id": "bundle.id", "name": "Display Name"}, ...],
    "enable": true
  }
}
```

### Send notification (`0x4B NOTIFICATION_SEND_CONTROL`)

Chunked JSON using Apple NCS format:
```json
{
  "ncs_notification": {
    "msg_id": 12345,
    "action": 0,
    "app_identifier": "bundle.id",
    "title": "…",
    "subtitle": "…",
    "message": "…",
    "time_s": 1713200000,
    "date": "Tue Apr 15 12:00:00 2026",
    "display_name": "Name"
  }
}
```

### Clear notification (`0x4C NOTIFICATION_CLEAR_CONTROL`)

`4C <msg_id_uint32_be>` — clears by ID.

### Auto-display settings

- `NOTIFICATION_AUTO_DISPLAY_GET` (0x3C) / `SET` (0x4F)
- Payload: `enabled_byte timeout_byte` (timeout in seconds)
- When enabled, the HUD wakes up automatically on notification arrival.

---

## Sensors and wear state

### Wear detection (`0x27 WEAR_DETECTION_SET` / `0x3A GET`)

Toggle. When enabled, firmware emits `0xF5` events:
- `0x06` `STATE_WORN`
- `0x07` `STATE_NOT_WORN_NO_CASE`
- `0x08` `STATE_IN_CASE_LID_OPEN`
- `0x0B` `STATE_IN_CASE_LID_CLOSED`

### Head-up gesture (`0x0B HEAD_UP_ANGLE_SET`)

- Format: `0B angle 01` (magic `0x01` is "level setting")
- Valid range: **0–60 degrees**
- Emits `0xF5 0x02` (up) / `0xF5 0x03` (down)

### Head-up action binding (`0x08 HEAD_UP_ACTION_SET`)

Used for binding what happens on head-up — dashboard, AI trigger, etc.

### Head-up mic activation (`HARDWARE_SET` 0x26 + `0x08`)

If enabled, head-up gesture also enables the microphone.

### Head-up calibration (`0x10 HEAD_UP_CALIBRATION_CONTROL`)

---

## Display hardware

### Brightness (`0x01 BRIGHTNESS_SET` / `0x29 GET`)

- Payload: `level_byte auto_byte` (auto `0x01` / manual `0x00`)
- Manual range: 0x00–0x2A (0–42)

### Display geometry (`0x26 HARDWARE_SET` + `0x02 DISPLAY`)

- `26 08 00 seq 02 preview height depth`
- `height` — waveguide vertical offset (user-configurable in official app)
- `depth` — focal depth
- `preview` byte enables a 5-second preview window

### Hardware sub-commands (`0x26`)

| Byte | Sub-command |
|------|-------------|
| `0x02` | Display geometry |
| `0x04` | LUM gear (luminance step) |
| `0x05` | Double-tap action binding |
| `0x06` | LUM coefficient |
| `0x07` | Long-press action binding |
| `0x08` | Head-up mic activation |

### Anti-shake (`0x2A ANTI_SHAKE_GET`)

Get only — stabilization/drift-correction setting.

---

## Bitmap display

### Upload (`0x15 FILE_UPLOAD`)

- 194-byte chunks
- First chunk includes address bytes `0x00 0x1C 0x00 0x00`

### Finalize (`0x20 FILE_UPLOAD_COMPLETE`)

Tells firmware the upload is done.

### CRC verify (`0x16 BITMAP_SHOW`)

`16 <crc32_xz_big_endian>` — firmware verifies and renders on pass.

### Exit to dashboard (`0x18 BITMAP_HIDE`)

---

## Text display (`0x4E TEXT_SET`)

Multi-packet text rendering for AI responses. Header byte upper nibble
controls scroll behavior:

| Byte | Mode | Behavior |
|------|------|----------|
| `0x30` | `AI_DISPLAY_AUTO_SCROLL` | Auto-advance pages |
| `0x40` | `AI_DISPLAY_COMPLETE` | Final page, auto mode |
| `0x50` | `AI_DISPLAY_MANUAL_SCROLL` | User tap-through |
| `0x60` | `AI_NETWORK_ERROR` | Error state |
| `0x70` | `TEXT_ONLY` | Plain page (no scroll semantics) |

Lower nibble: `0x01` = display new content.

Display hard limits: **488 px wide, 21 px font, 5 lines per screen.**

---

## Built-in apps (firmware-native)

These are full features the glasses can run themselves — currently we don't
use any of them. Listed for future reference.

| Command | Byte | Notes |
|---------|------|-------|
| Teleprompter control | `0x09` | Firmware renders scrolling script |
| Teleprompter suspend | `0x24` | Pause |
| Teleprompter position | `0x25` | Seek |
| Transcribe control | `0x0D` | Native STT (language-dependent) |
| Translate control | `0x0F` | Native translation |
| Navigation | `0x0A` | Turn-by-turn with sub-commands: INIT, TRIP_STATUS, MAP_OVERVIEW, PANORAMIC_MAP, SYNC, EXIT, ARRIVED |
| Quick note control | `0x1E` | Dashboard note editor + audio recorder |
| Timer control | `0x07` | Countdown timer |
| Tutorial control | `0x1F` | Built-in onboarding |
| Firmware upgrade | `0x17` | OTA |
| Unpair | `0x47` | Factory unpair |

### Quick note sub-commands (`0x1E`)

| Byte | Meaning | Observed in Even app? |
|------|---------|------------------------|
| `0x01` | Audio metadata get | — |
| `0x02` | Audio file get | — |
| `0x03` | Note text write (unified add/edit/clear) | **yes** (2026-04-17 sniff) |
| `0x04` | Audio file delete | — |
| `0x05` | Audio record delete | — |
| `0x07` | Note status edit (checkmark toggle) | no |
| `0x08` | Note add | no |
| `0x0A` | Note status edit (variant 2) | no |

Per live capture of the official Even iOS app, `0x03` is the single
unified write — no sub-sub-commands. Add, edit, and clear are all
expressed as `0x03` with body content variation (populated body vs the
fixed 7-byte empty-slot template). Every user action writes exactly 4
packets back-to-back, one per slot (1..4). The declared `0x07` / `0x08`
/ `0x0A` sub-commands are never emitted in practice.

The glasses have on-device audio recording tied to quick notes. Files are
transferred via `0x02 AUDIO_FILE_GET`.

---

## Microphone

- `0x0E MICROPHONE_SET`: `0E 01` on / `0E 00` off
- Firmware then emits `0xF1 seq <lc3_audio>` packets on the notify channel
- Single long-press (`0xF5 0x17` → `0x18`) is the canonical start/stop trigger
- `0xF5 0x12 ACTION_LONG_PRESS` (no HELD/RELEASED split) is the short-form
  version; MentraOS treats it as a toggle

---

## Device info (queryable)

| Command | Byte | Returns |
|---------|------|---------|
| Battery + firmware | `0x2C` | `[frame_type(A/B), battery_%, …, major, …, minor]` |
| Serial (glasses) | `0x34` | 14-byte ASCII; bytes 0-4 = frame shape (`S100`/`S110`), 4-7 = color (`LAA`/`LBB`/`LCC`) |
| Serial (lens) | `0x33` | Lens serial |
| MAC address | `0x2D` | MAC |
| Firmware build string | `0x23 0x74` | Response prefix `0x6E` |
| ESB channel | `0x35` | Proprietary RF sub-protocol |
| ESB notification count | `0x36` | — |
| Time since boot | `0x37` | Uptime |
| Buried point | `0x3E` | Telemetry |
| Running app | `0x39` | Which built-in app is active |
| Apple notification status | `0x38` | iOS NCS state |

### Frame hardware codes

Parsed from glasses serial number (`S100 LAA` etc.):

| Code | Meaning |
|------|---------|
| `S100` | Round frame (G1A) |
| `S110` | Square frame (G1B) |
| `LAA` | Grey |
| `LBB` | Brown |
| `LCC` | Green |

---

## System control (`0x23`)

| Sub-byte | Action |
|----------|--------|
| `0x6C` | Debug logging set (payload `0x00` enable / `0x31` disable) |
| `0x72` | Reboot |
| `0x74` | Firmware build string get |

When debug logging is on, the glasses emit `0xF4` message packets containing
UTF-8 log strings from firmware.

---

## Language (`0x3D LANGUAGE_SET`)

`3D 06 00 seq 01 lang_byte`

| Byte | Language |
|------|----------|
| `0x01` | Chinese |
| `0x02` | English |
| `0x03` | Japanese |
| `0x04` | Korean |
| `0x05` | French |
| `0x06` | German |
| `0x07` | Spanish |
| `0x0E` | Italian |

Affects built-in transcribe/translate and probably HUD text rendering.

---

## Silent mode (`0x03 SILENT_MODE_SET` / `0x2B GET`)

- Payload byte: `0x0C` enable / `0x0A` disable
- Emitted as events: `0xF5 0x04` enabled / `0xF5 0x05` disabled
- When on, firmware suppresses notification HUD wake but still delivers gesture events

---

## Observations / what COGOS currently ignores

Things the firmware reports that we don't yet use:

- **Battery events** (`0xF5 0x09`/`0x0A`) — glasses battery %, charging state
- **Case events** (`0xF5 0x08`/`0x0B`/`0x0E`/`0x0F`) — lid state, case battery, case charging
- **Binding success** (`0xF5 0x11`) — BLE bind ack
- **Wear state** (`0xF5 0x06`/`0x07`) — could drive auto-show/hide of HUD
- **Dashboard show/close** (`0xF5 0x1E`/`0x1F`) — distinct from generic double-tap
- **Debug log stream** (`0xF4`) — full-text firmware logs

Things the firmware can do that COGOS currently does phone-side:
- Dashboard panes (time/weather/calendar/stocks/news/map) — we render our
  own bitmap instead to fit the AI-centric layout
- Notifications — partially used via the whitelist + `0x4B`
- Calendar — firmware can display 8 events natively; we show 3 in the glance
