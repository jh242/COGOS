# G1 BLE Protocol — Reference

Comprehensive reference for the Even Realities G1 BLE protocol: byte codes,
wire layouts, firmware capabilities, and what COGOS currently uses vs.
ignores. Compiled from the Gadgetbridge reverse-engineered driver
(`G1Constants.java`, PR #4553), the MentraOS Android driver, the Even
Realities EvenDemoApp, and live PacketLogger captures of the official
Even iOS app.

**Sources:**
- [Gadgetbridge — Even Realities driver (Codeberg PR #4553)](https://codeberg.org/Freeyourgadget/Gadgetbridge/pulls/4553)
- [MentraOS — G1.java](https://github.com/Mentra-Community/MentraOS)
- [Even Realities EvenDemoApp](https://github.com/even-realities/EvenDemoApp)

---

## Transport

| Item | Value |
|------|-------|
| BLE service (Nordic UART) | `6e400001-b5a3-f393-e0a9-e50e24dcca9e` |
| TX characteristic (write) | `6e400002-b5a3-f393-e0a9-e50e24dcca9e` |
| RX characteristic (notify) | `6e400003-b5a3-f393-e0a9-e50e24dcca9e` |
| ATT handle — write (phone → glasses) | `0x0015` (both arms) |
| ATT handle — notify (glasses → phone) | `0x0012` (both arms) |
| MTU | 251 |
| Max payload size | 180 bytes (observed firmware limit) |
| Heartbeat interval | 8 s (glasses disconnect at ~32 s idle) |
| Device name format | `G1_XX_[L\|R]_YYYYY` |

**Arm identification:** both arms expose the same ATT handles. The left vs
right distinction is made at the HCI layer — each arm gets its own HCI
connection handle (observed: `0x0401` = L, `0x0404` = R, though these vary
per pairing session). Older third-party drivers (Gadgetbridge, MentraOS)
reference ATT handles `0x0403 / 0x0405` — those are stale / wrong.

**Wireshark filter for G1 downlink (phone → glasses) only:**
```
btatt.handle == 0x0015 && btatt.opcode == 0x52
```
(`0x52` = ATT Write Command opcode.) Distinguish arms by the preceding HCI
connection handle, not by ATT handle.

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
   - Start heartbeat loop (critical — glasses auto-disconnect after ~32 s
     of BLE silence)
   - Push notification app whitelist to **left only** (large payload)
   - Sync calendar events

Gadgetbridge sends a heartbeat every 8 s with a 25 s target and 10 s jitter
budget. COGOS matches at 8 s.

---

## Message ID (top-level packet type)

The first byte of every packet identifies its category.

| Byte | Name | Notes |
|------|------|-------|
| `0x22` | `STATUS` | Status response |
| `0xF1` | `AUDIO` | LC3 audio chunk (`F1 seq data...`) |
| `0xF4` | `DEBUG` | Debug log output from glasses (UTF-8 strings when debug logging enabled) |
| `0xF5` | `EVENT` | Gesture / state event (see EventId table) |

Everything else in the [Command ID](#command-id-app--glasses) table is a top-level command byte sent from the app.

---

## Command ID (App → Glasses)

| Byte | Name | Notes |
|------|------|-------|
| `0x01` | `BRIGHTNESS_SET` | |
| `0x03` | `SILENT_MODE_SET` | |
| `0x04` | `NOTIFICATION_APP_LIST_SET` | Whitelist JSON |
| `0x06` | `DASHBOARD_SET` | Has sub-commands |
| `0x07` | `TIMER_CONTROL` | |
| `0x08` | `HEAD_UP_ACTION_SET` | |
| `0x09` | `TELEPROMPTER_CONTROL` | |
| `0x0A` | `NAVIGATION_CONTROL` | Has sub-commands |
| `0x0B` | `HEAD_UP_ANGLE_SET` | `0B angle 01` |
| `0x0D` | `TRANSCRIBE_CONTROL` | |
| `0x0E` | `MICROPHONE_SET` | `0E 01` on / `0E 00` off |
| `0x0F` | `TRANSLATE_CONTROL` | |
| `0x10` | `HEAD_UP_CALIBRATION_CONTROL` | |
| `0x15` | `FILE_UPLOAD` | BMP chunk |
| `0x16` | `BITMAP_SHOW` | Also serves as CRC verify |
| `0x17` | `UPGRADE_CONTROL` | Firmware upgrade |
| `0x18` | `BITMAP_HIDE` | Exit to dashboard |
| `0x1E` | `DASHBOARD_QUICK_NOTE_CONTROL` | |
| `0x1F` | `TUTORIAL_CONTROL` | |
| `0x20` | `FILE_UPLOAD_COMPLETE` | BMP finalize |
| `0x22` | `STATUS_GET` | |
| `0x23` | `SYSTEM_CONTROL` | Has sub-commands |
| `0x24` | `TELEPROMPTER_SUSPEND` | |
| `0x25` | `TELEPROMPTER_POSITION_SET` / `HEARTBEAT` | Gadgetbridge names this `TELEPROMPTER_POSITION_SET`; EvenDemoApp (and our COGOS `Proto.sendHeartBeat`) uses the same byte as a heartbeat with payload `[length_lo, length_hi, seq, 0x04, seq]`. The Even Realities iOS app does **not** send `0x25` at all — it keeps the link alive via the ~5 s full dashboard re-push (`0x06 0x06` → `0x06 0x01` → `0x06 0x03` → `0x22 0x05`). Firmware appears to accept both strategies. |
| `0x26` | `HARDWARE_SET` | Has sub-commands |
| `0x27` | `WEAR_DETECTION_SET` | |
| `0x29` | `BRIGHTNESS_GET` | |
| `0x2A` | `ANTI_SHAKE_GET` | |
| `0x2B` | `SILENT_MODE_GET` | |
| `0x2C` | `INFO_BATTERY_AND_FIRMWARE_GET` | |
| `0x2D` | `INFO_MAC_ADDRESS_GET` | |
| `0x2E` | `NOTIFICATION_APP_LIST_GET` | |
| `0x32` | `HEAD_UP_ANGLE_GET` | |
| `0x33` | `INFO_SERIAL_NUMBER_LENS_GET` | |
| `0x34` | `INFO_SERIAL_NUMBER_GLASSES_GET` | |
| `0x35` | `INFO_ESB_CHANNEL_GET` | |
| `0x36` | `INFO_ESB_NOTIFICATION_COUNT_GET` | |
| `0x37` | `INFO_TIME_SINCE_BOOT_GET` | |
| `0x38` | `NOTIFICATION_APPLE_GET` | |
| `0x39` | `STATUS_RUNNING_APP_GET` | |
| `0x3A` | `WEAR_DETECTION_GET` | |
| `0x3B` | `HARDWARE_DISPLAY_GET` | |
| `0x3C` | `NOTIFICATION_AUTO_DISPLAY_GET` | |
| `0x3D` | `LANGUAGE_SET` | |
| `0x3E` | `INFO_BURIED_POINT_GET` | |
| `0x3F` | `HARDWARE_GET` | |
| `0x47` | `UNPAIR` | |
| `0x4B` | `NOTIFICATION_SEND_CONTROL` | Push notify |
| `0x4C` | `NOTIFICATION_CLEAR_CONTROL` | |
| `0x4D` | `MTU_SET` | |
| `0x4E` | `TEXT_SET` | AI result / text page |
| `0x4F` | `NOTIFICATION_AUTO_DISPLAY_SET` | |
| `0x50` | `UNKNOWN` | |
| `0x58` | `DASHBOARD_CALENDAR_NEXT_UP_SET` | |

### Command status responses (Glasses → App)

| Byte | Meaning |
|------|---------|
| `0xC9` | `SUCCESS` |
| `0xCA` | `FAIL` |
| `0xCB` | `DATA_CONTINUES` |

---

## EventId (0xF5 payload byte)

These are the values that appear as `packet.data[1]` when the first byte is `0xF5`.

| Byte | Name | Notes |
|------|------|-------|
| `0x00` | `ACTION_DOUBLE_TAP_FOR_EXIT` | Legacy double-tap exit |
| `0x01` | `ACTION_SINGLE_TAP` | Page turn |
| `0x02` | `ACTION_HEAD_UP` | |
| `0x03` | `ACTION_HEAD_DOWN` | |
| `0x04` | `ACTION_SILENT_MODE_ENABLED` | |
| `0x05` | `ACTION_SILENT_MODE_DISABLED` | |
| `0x06` | `STATE_WORN` | Glasses on head |
| `0x07` | `STATE_NOT_WORN_NO_CASE` | Removed, not in case |
| `0x08` | `STATE_IN_CASE_LID_OPEN` | |
| `0x09` | `STATE_CHARGING` | Payload: `00` not charging, `01` charging |
| `0x0A` | `INFO_BATTERY_LEVEL` | Payload: `00`–`64` (0–100 %) |
| `0x0B` | `STATE_IN_CASE_LID_CLOSED` | |
| `0x0C` | *Unknown* | — |
| `0x0D` | *Unknown* | — |
| `0x0E` | `STATE_CASE_CHARGING` | Payload: `00`/`01` |
| `0x0F` | `INFO_CASE_BATTERY_LEVEL` | Payload: `00`–`64` |
| `0x10` | *Unknown* | — |
| `0x11` | `ACTION_BINDING_SUCCESS` | BLE bind confirmation |
| `0x12` | `ACTION_LONG_PRESS` | Short-form long-press (MentraOS treats as toggle) |
| `0x17` | `ACTION_LONG_PRESS_HELD` | Long-press started (Even AI start) |
| `0x18` | `ACTION_LONG_PRESS_RELEASED` | Long-press released (Even AI stop) |
| `0x1E` | `ACTION_DOUBLE_TAP_DASHBOARD_SHOW` | |
| `0x1F` | `ACTION_DOUBLE_TAP_DASHBOARD_CLOSE` | |
| `0x20` | `ACTION_DOUBLE_TAP` | Generic double-tap event |

---

## Display text — `0x4E` (AI result / text page)

Multi-packet text rendering for AI responses. The header byte's upper
4 bits encode display status; lower 4 bits encode the action.

**Status (upper nibble):**

| Byte | Name | Behavior |
|------|------|----------|
| `0x30` | `AI_DISPLAY_AUTO_SCROLL` | Auto-advance pages |
| `0x40` | `AI_DISPLAY_COMPLETE` | Final page, auto mode |
| `0x50` | `AI_DISPLAY_MANUAL_SCROLL` | User tap-through |
| `0x60` | `AI_NETWORK_ERROR` | Error state |
| `0x70` | `TEXT_ONLY` | Plain page (no scroll semantics) |

**Action (lower nibble):** `0x01` = display new content.

**Display hard limits:** **488 px wide, 21 px font, 5 lines per screen.**

---

## Dashboard

### DashboardMode

| Byte | Name |
|------|------|
| `0x00` | `FULL` |
| `0x01` | `DUAL` |
| `0x02` | `MINIMAL` |

### DashboardPaneMode

| Byte | Name |
|------|------|
| `0x00` | `QUICK_NOTES` |
| `0x01` | `STOCKS` |
| `0x02` | `NEWS` |
| `0x03` | `CALENDAR` |
| `0x04` | `MAP` |
| `0x05` | `EMPTY` |

### DashboardSetSubcommand (second byte after `0x06`)

| Byte | Name |
|------|------|
| `0x01` | `TIME_AND_WEATHER` |
| `0x02` | `WEATHER` |
| `0x03` | `CALENDAR` |
| `0x04` | `STOCKS` |
| `0x05` | `NEWS` |
| `0x06` | `MODE` |
| `0x07` | `MAP` |

Byte layouts pinned from Gadgetbridge
(`G1Communications.java`, `G1Constants.java`):

#### `0x06 0x01 TIME_AND_WEATHER` — fixed 22-byte packet

```
[0]    0x06                   DASHBOARD_SET
[1]    0x16                   total packet length (22), not a payload-length
[2]    0x00                   pad / reserved
[3]    seq : u8               command sequence id
[4]    0x01                   TIME_AND_WEATHER
[5..8]  unix_seconds : u32 LE   (= timeMs / 1000)
[9..16] unix_millis  : u64 LE
[17]   weather_icon : u8      (see WeatherId)
[18]   temp_celsius : i8      signed; Kelvin − 273
[19]   unit : u8              0x00 = °C, 0x01 = °F (display only)
[20]   hour_fmt : u8          0x00 = 12h, 0x01 = 24h
[21]   0x00                   trailing byte; purpose unknown, always 0x00 in captures
```

**Length correction:** Gadgetbridge's source documents this as 21 bytes
(`0x15`), but the live Even-app capture shows 22 bytes (`0x16`) with a
trailing `0x00` at byte `[21]`. Firmware appears to accept both; write 22 to
match the official app's behavior.

Quirk: firmware re-maps `SUNNY (0x10)` → `NIGHT (0x01)` based on sunrise/sunset
vs. the supplied timestamp (Gadgetbridge mirrors this; we should match).

#### `0x06 0x03 CALENDAR` — chunked TLV

Per-chunk wire header (9 bytes):

```
[0] 0x06                  DASHBOARD_SET
[1] chunk_length : u8     this chunk's total length incl. header
[2] 0x00
[3] seq : u8              per-chunk sequence id
[4] 0x03                  CALENDAR
[5] chunk_count : u8      total number of chunks
[6] 0x00
[7] chunk_index : u8      **1-based** (first chunk = 1)
[8] 0x00
[9..] body_slice
```

Body (before chunking):

```
<magic prefix: 3 bytes>   value varies; see below
event_count : u8          min(events.count, 8)
per event (TLV):
  0x01 len:u8 title_utf8
  0x02 len:u8 time_str_utf8     pre-formatted by app ("HH:mm" / "h:mma" / …)
  0x03 len:u8 location_utf8
```

**Magic prefix correction (2026-04-17 Even-app capture):** Gadgetbridge's
source shows `01 03 03` as a fixed prefix, but the live Even app sends
`00 00 02` for the empty-calendar case. Concretely, the full empty-calendar
packet observed is:

```
06 0C 00 <seq> 03 01 00 01 00 00 00 02
└header────┘   └sub + chunk(1/1)┘ └body: 00 00 02┘
```

We don't yet have a non-empty calendar capture from the Even app, so the
prefix for populated calendars is still unconfirmed — it may differ again
from Gadgetbridge's `01 03 03`. Capture a non-empty calendar before
committing the prefix bytes in Swift.

Chunking: max body per chunk = `180 − 9 = 171` bytes. Firmware renders
`time_str` verbatim — it does not parse timestamps. Events auto-clear 5 min
after start time. Max events: **8** (4 pages × 2 events).

#### `0x06 0x06 MODE` — fixed 7-byte packet

```
[0] 0x06                  DASHBOARD_SET
[1] 0x07                  total length = 7
[2] 0x00
[3] seq : u8
[4] 0x06                  MODE
[5] mode : u8             FULL=0x00 | DUAL=0x01 | MINIMAL=0x02
[6] secondary_pane : u8   QUICK_NOTES=0x00 | STOCKS=0x01 | NEWS=0x02 |
                          CALENDAR=0x03 | MAP=0x04 | EMPTY=0x05
```

`secondary_pane` is always written, even in FULL/MINIMAL modes — pass
`EMPTY` when you don't care (Gadgetbridge pattern).

#### `0x06 0x04 STOCKS` and `0x06 0x05 NEWS` — layouts unknown

Declared in `G1Constants.java:208-209` and never serialized. Same public-source
gap as the `0x1E` Quick Notes family — the firmware has the panes (addressable
via `DashboardPaneMode.STOCKS = 0x01` and `DashboardPaneMode.NEWS = 0x02`) but
no app implements the payload. Pinning needs a BLE sniff against the official
Even Realities app with stocks/news panes enabled.

### DashboardQuickNoteSubcommand (second byte after `0x1E`)

| Byte | Name | Status |
|------|------|--------|
| `0x01` | `AUDIO_METADATA_GET` | Constant declared; wire layout not captured |
| `0x02` | `AUDIO_FILE_GET` | Constant declared; wire layout not captured |
| `0x03` | `NOTE_TEXT_EDIT` | **Pinned 2026-04-17** — see below |
| `0x04` | `AUDIO_FILE_DELETE` | Constant declared; wire layout not captured |
| `0x05` | `AUDIO_RECORD_DELETE` | Constant declared; wire layout not captured |
| `0x07` | `NOTE_STATUS_EDIT` | Constant declared; never observed from Even app |
| `0x08` | `NOTE_ADD` | Constant declared; **never observed** — Even app uses `0x03` for add too |
| `0x09` | *Unknown* | — |
| `0x0A` | `NOTE_STATUS_EDIT_2` | Constant declared; never observed from Even app |

**Key finding from the 2026-04-17 Even-app capture:** the Even app uses
`0x1E 0x03` (NOTE_TEXT_EDIT) as the single unified write for add, edit, and
clear operations on text notes. Sub-commands `0x07`, `0x08`, `0x0A` never
fire in practice — they're constants the firmware accepts but that the
official app doesn't emit. Our Swift implementation should mirror that:
only emit `0x03`, and treat "add" and "clear" as the same sub-command with
different body contents.

The glasses also have on-device audio recording tied to quick notes
(`0x01`/`0x02`/`0x04`/`0x05` sub-commands). Layouts not yet captured.

#### `0x1E 0x03 NOTE_TEXT_EDIT` — replace-all-4-slots, chunked-TLV body

**Protocol semantics:** every note update writes **4 packets** back-to-back,
one per slot (`1..4`), whether or not each slot has changed. There is no
incremental per-slot update and no "delete slot N" command. Slots without
a note are written with the fixed "empty" body below.

**Wire header (9 bytes, identical structure to `0x06 0x03 CALENDAR`):**

```
[0] 0x1E                      cmd
[1] total_length : u8         includes header + body
[2] 0x00                      pad
[3] seq : u8                  global monotonic sequence
[4] 0x03                      sub = NOTE_TEXT_EDIT
[5] chunk_count : u8          observed: always 0x01
[6] 0x00                      pad
[7] chunk_index : u8          1-based; observed: always 0x01
[8] 0x00                      pad
```

**Non-empty slot body:**

```
[9]       slot_id : u8              1..4
[10]      title_tag : u8 = 0x01
[11]      title_len : u8            utf-8 byte count
[12..]    title_utf8
[12+tl]   body_len : u16 LE
[14+tl..] body_utf8
```

Title is TLV-style (`tag 0x01 + u8 length`); body is length-prefixed with
a `u16 LE` length and **no tag byte**. `title_len` fits in one byte; the
observed max title width on screen is short but the wire encoding allows up
to 255 bytes. Body supports up to 65535 bytes in theory — actual firmware
limit not yet probed.

**Empty slot body (fixed 7-byte template):**

```
[9]       slot_id : u8              1..4
[10..15]  00 01 00 01 00 00         literal — always these 6 bytes
```

Full empty-slot packet (16 bytes total):
```
1E 10 00 <seq> 03  01 00 01 00  <slot>  00 01 00 01 00 00
```

Treat the 6-byte tail as a literal — don't try to reinterpret it as TLVs.

**Worked examples (from live capture):**

Slot 1, title "Title", body "This is the body":
```
1E 23 00 90 03  01 00 01 00   01 01 05 54 69 74 6C 65   10 00  54 68 69 73 20 69 73 20 74 68 65 20 62 6F 64 79
```

Slot 1, title "Test note", body "Hi, this is the body of the test \nnote" (38 bytes):
```
1E 3D 00 B0 03  01 00 01 00   01 01 09 "Test note"   26 00 "Hi, this is the body of the test \nnote"
```

Clear slot 2:
```
1E 10 00 92 03  01 00 01 00   02  00 01 00 01 00 00
```

### `0x58 DASHBOARD_CALENDAR_NEXT_UP_SET` — layout unknown

Declared in `G1Constants.java:140` and never used in Gadgetbridge,
MentraOS, or the EvenDemoApp. Name suggests a dedicated "next up" pane
distinct from the 8-event list in `0x06 0x03`. Not observed in any
capture so far. To trigger: schedule a calendar event starting in ~5
minutes and capture across the transition boundary — that should cause
the Even app to emit a `0x58` write.

### `0x22 0x05` — right-arm status/handshake

Observed on every dashboard-ping cycle, sent to the **right arm only**,
immediately after the three `0x06 ...` dashboard packets:

```
Write:    22 05 00 <seq> 01                       (5 bytes)
Notify:   22 05 00 <seq> 01 0A 01 01              (9 bytes)
```

- Byte `[1] = 0x05` is the total length (matches the write).
- Byte `[4] = 0x01` is likely a sub-command or "apply" flag.
- Response trailing bytes `0A 01 01` are unexplained — may be
  status/ack/battery. Needs further probing (vary battery level, silent
  mode, etc., and diff the response).

`0x22` is already pinned as `STATUS_GET` for the single-byte form (`22`
alone, no sub). The `22 05 ...` form is a different beast — it's a
parameterized write, not a status read. Whether these share the same
command-ID semantics is unclear; treat them as distinct surfaces.

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

### Head-up mic activation (`0x26 HARDWARE_SET` + `0x08`)

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

### Anti-shake (`0x2A ANTI_SHAKE_GET`)

Get only — stabilization/drift-correction setting.

---

## Hardware sub-commands (second byte after `0x26`)

| Byte | Name |
|------|------|
| `0x02` | `DISPLAY` (geometry — see above) |
| `0x04` | `LUM_GEAR` (luminance step) |
| `0x05` | `DOUBLE_TAP_ACTION` (rebind on-device action) |
| `0x06` | `LUM_COEFFICIENT` |
| `0x07` | `LONG_PRESS_ACTION` (rebind on-device action) |
| `0x08` | `HEAD_UP_MIC_ACTIVATION` |

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

## Microphone

- `0x0E MICROPHONE_SET`: `0E 01` on / `0E 00` off
- Firmware then emits `0xF1 seq <lc3_audio>` packets on the notify channel
- Single long-press (`0xF5 0x17` → `0x18`) is the canonical start/stop trigger
- `0xF5 0x12 ACTION_LONG_PRESS` (no HELD/RELEASED split) is the short-form
  version; MentraOS treats it as a toggle

---

## Built-in apps (firmware-native)

These are full features the glasses can run themselves. COGOS currently
doesn't use any of them — listed for future reference.

| Command | Byte | Notes |
|---------|------|-------|
| Teleprompter control | `0x09` | Firmware renders scrolling script |
| Teleprompter suspend | `0x24` | Pause |
| Teleprompter position | `0x25` | Seek |
| Transcribe control | `0x0D` | Native STT (language-dependent) |
| Translate control | `0x0F` | Native translation |
| Navigation | `0x0A` | Turn-by-turn (sub-commands below) |
| Quick note control | `0x1E` | Dashboard note editor + audio recorder (layouts above) |
| Timer control | `0x07` | Countdown timer |
| Tutorial control | `0x1F` | Built-in onboarding |
| Firmware upgrade | `0x17` | OTA |
| Unpair | `0x47` | Factory unpair |

### Navigation sub-commands (second byte after `0x0A`)

| Byte | Name |
|------|------|
| `0x00` | `INIT` |
| `0x01` | `TRIP_STATUS` |
| `0x02` | `MAP_OVERVIEW` |
| `0x03` | `PANORAMIC_MAP` |
| `0x04` | `SYNC` |
| `0x05` | `EXIT` |
| `0x06` | `ARRIVED` |

---

## System control (`0x23`) sub-commands

| Byte | Action |
|------|--------|
| `0x6C` | `DEBUG_LOGGING_SET` (payload `0x00` enable / `0x31` disable) |
| `0x72` | `REBOOT` |
| `0x74` | `FIRMWARE_BUILD_STRING_GET` — response prefix `0x6E` |

When debug logging is on, the glasses emit `0xF4` message packets containing
UTF-8 log strings from firmware.

---

## Silent mode (`0x03 SILENT_MODE_SET` / `0x2B GET`)

- Payload byte: `0x0C` enable / `0x0A` disable
- Emitted as events: `0xF5 0x04` enabled / `0xF5 0x05` disabled
- When on, firmware suppresses notification HUD wake but still delivers gesture events

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

## Temperature unit / Time format

| Byte | TemperatureUnit | TimeFormat |
|------|-----------------|------------|
| `0x00` | Celsius | 12-hour |
| `0x01` | Fahrenheit | 24-hour |

---

## WeatherId (dashboard weather icons)

| Byte | Condition |
|------|-----------|
| `0x00` | None |
| `0x01` | Night |
| `0x02` | Clouds |
| `0x03` | Drizzle |
| `0x04` | Heavy drizzle |
| `0x05` | Rain |
| `0x06` | Heavy rain |
| `0x07` | Thunder |
| `0x08` | Thunderstorm |
| `0x09` | Snow |
| `0x0A` | Mist |
| `0x0B` | Fog |
| `0x0C` | Sand |
| `0x0D` | Squalls |
| `0x0E` | Tornado |
| `0x0F` | Freezing rain |
| `0x10` | Sunny (firmware auto-substitutes `0x01 NIGHT` after sunset) |

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

## What COGOS currently ignores

Things the firmware reports that we don't yet use:

- **Battery events** (`0xF5 0x09`/`0x0A`) — glasses battery %, charging state
- **Case events** (`0xF5 0x08`/`0x0B`/`0x0E`/`0x0F`) — lid state, case battery, case charging
- **Binding success** (`0xF5 0x11`) — BLE bind ack
- **Wear state** (`0xF5 0x06`/`0x07`) — could drive auto-show/hide of HUD
- **Dashboard show/close** (`0xF5 0x1E`/`0x1F`) — distinct from generic double-tap
- **Debug log stream** (`0xF4`) — full-text firmware logs

Things the firmware can do that COGOS currently does phone-side:

- Dashboard panes (time/weather/calendar/stocks/news/map) — the
  firmware-dashboard migration plan is retiring our bitmap in favor of
  these native panes
- Notifications — partially used via the whitelist + `0x4B`
- Calendar — firmware can display 8 events natively; current glance shows 3
