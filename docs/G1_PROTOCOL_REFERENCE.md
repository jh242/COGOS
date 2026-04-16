# G1 BLE Protocol — Code Reference

Comprehensive reference for all known byte codes used in the Even Realities G1
BLE protocol. Compiled from the Gadgetbridge reverse-engineered driver
(`G1Constants.java`, PR #4553), the MentraOS Android driver, and the Even
Realities EvenDemoApp.

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
| MTU | 251 |
| Max payload size | 180 bytes (observed firmware limit) |
| Heartbeat interval | 8 s (glasses disconnect at ~32 s idle) |
| Device name format | `G1_XX_[L\|R]_YYYYY` |

---

## Message ID (top-level packet type)

The first byte of every packet identifies its category.

| Byte | Name | Notes |
|------|------|-------|
| `0x22` | `STATUS` | Status response |
| `0xF1` | `AUDIO` | LC3 audio chunk (`F1 seq data...`) |
| `0xF4` | `DEBUG` | Debug log output from glasses |
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
| `0x25` | `TELEPROMPTER_POSITION_SET` | |
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

These are the values that appear as `packet.data[1]` when the first byte is `0xF5`. **This is where the previously-unknown codes live.**

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
| `0x12` | `ACTION_LONG_PRESS` | Short-form long-press |
| `0x17` | `ACTION_LONG_PRESS_HELD` | Long-press started (Even AI start) |
| `0x18` | `ACTION_LONG_PRESS_RELEASED` | Long-press released (Even AI stop) |
| `0x1E` | `ACTION_DOUBLE_TAP_DASHBOARD_SHOW` | |
| `0x1F` | `ACTION_DOUBLE_TAP_DASHBOARD_CLOSE` | |
| `0x20` | `ACTION_DOUBLE_TAP` | Generic double-tap event |

---

## Display text — `0x4E` packet header byte

The upper 4 bits encode display status; lower 4 bits encode the action.

**Status (upper nibble):**

| Byte | Name |
|------|------|
| `0x30` | `AI_DISPLAY_AUTO_SCROLL` |
| `0x40` | `AI_DISPLAY_COMPLETE` |
| `0x50` | `AI_DISPLAY_MANUAL_SCROLL` |
| `0x60` | `AI_NETWORK_ERROR` |
| `0x70` | `TEXT_ONLY` |

**Action (lower nibble):** `0x01` = display new content.

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

#### `0x06 0x01 TIME_AND_WEATHER` — fixed 21-byte packet

```
[0]    0x06                   DASHBOARD_SET
[1]    0x15                   total packet length (21), not a payload-length
[2]    0x00                   pad / reserved
[3]    seq : u8               command sequence id
[4]    0x01                   TIME_AND_WEATHER
[5..8]  unix_seconds : u32 LE   (= timeMs / 1000)
[9..16] unix_millis  : u64 LE
[17]   weather_icon : u8      (see WeatherId)
[18]   temp_celsius : i8      signed; Kelvin − 273
[19]   unit : u8              0x00 = °C, 0x01 = °F (display only)
[20]   hour_fmt : u8          0x00 = 12h, 0x01 = 24h
```

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
0x01 0x03 0x03            3 magic prefix bytes (purpose unknown per Gadgetbridge)
event_count : u8          min(events.count, 8); if 0, written as 1 + dummy event
per event (TLV):
  0x01 len:u8 title_utf8
  0x02 len:u8 time_str_utf8     pre-formatted by app ("HH:mm" / "h:mma" / …)
  0x03 len:u8 location_utf8
```

Chunking: max body per chunk = `180 − 9 = 171` bytes. Firmware renders
`time_str` verbatim — it does not parse timestamps. Events auto-clear 5 min
after start time. Empty-events case: one dummy event
`0x01 <len> "No events" 0x02 0x00 0x03 0x00`.

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
Even Realities app.

### DashboardQuickNoteSubcommand (second byte after `0x1E`)

| Byte | Name |
|------|------|
| `0x01` | `AUDIO_METADATA_GET` |
| `0x02` | `AUDIO_FILE_GET` |
| `0x03` | `NOTE_TEXT_EDIT` |
| `0x04` | `AUDIO_FILE_DELETE` |
| `0x05` | `AUDIO_RECORD_DELETE` |
| `0x07` | `NOTE_STATUS_EDIT` |
| `0x08` | `NOTE_ADD` |
| `0x09` | *Unknown* |
| `0x0A` | `NOTE_STATUS_EDIT_2` |

**⚠ Payload layouts for `0x1E` sub-commands are NOT documented in any public
source.** Gadgetbridge, MentraOS, and the official `EvenDemoApp` all declare
the sub-command constants but none implement a serializer. Gadgetbridge's
own comment at `G1Constants.java:220` is speculative ("Does this delete the
metadata?"). To pin these down we need to sniff traffic from the official
Even Realities app while it adds / edits / deletes a quick note. Until
then, treat Quick Notes as unimplementable.

That the spec/firmware-features docs reference a concrete payload shape
for `0x1E 0x03` (add/update/delete sub-sub-commands, note-id) was based on
inference from the constant names, not on traced bytes.

Max calendar events: 8 (4 pages × 2 events).

### `0x58 DASHBOARD_CALENDAR_NEXT_UP_SET` — layout unknown

Declared in `G1Constants.java:140` and never used in Gadgetbridge,
MentraOS, or the EvenDemoApp. Name suggests a dedicated "next up" pane
distinct from the 8-event list in `0x06 0x03`. Also needs live sniffing
before we can touch it.

---

## Hardware sub-commands (second byte after `0x26`)

| Byte | Name |
|------|------|
| `0x02` | `DISPLAY` |
| `0x04` | `LUM_GEAR` |
| `0x05` | `DOUBLE_TAP_ACTION` |
| `0x06` | `LUM_COEFFICIENT` |
| `0x07` | `LONG_PRESS_ACTION` |
| `0x08` | `HEAD_UP_MIC_ACTIVATION` |

---

## System sub-commands (second byte after `0x23`)

| Byte | Name |
|------|------|
| `0x6C` | `DEBUG_LOGGING_SET` |
| `0x72` | `REBOOT` |
| `0x74` | `FIRMWARE_BUILD_STRING_GET` |

Firmware build-string response prefix: `0x6E`.

---

## Navigation sub-commands (second byte after `0x0A`)

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

## Silent mode status

| Byte | Name |
|------|------|
| `0x0A` | `DISABLE` |
| `0x0C` | `ENABLE` |

## Debug logging status

| Byte | Name |
|------|------|
| `0x00` | `ENABLE` |
| `0x31` | `DISABLE` |

---

## Language IDs

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
| `0x10` | Sunny |

---

## Hardware description (parsed from device info)

| Key | Meaning |
|-----|---------|
| `S100` | Round frame |
| `S110` | Square frame |
| `LAA` | Grey color |
| `LBB` | Brown color |
| `LCC` | Green color |
