# Even Realities G1 — BLE Protocol Reference

Compiled from the official EvenDemoApp, MentraOS `G1.swift`, `G1.java`, and `Enums.swift`.

---

## Transport

| Property | Value |
|----------|-------|
| UART Service UUID | `6E400001-B5A3-F393-E0A9-E50E24DCCA9E` |
| TX Characteristic (write) | `6E400002-B5A3-F393-E0A9-E50E24DCCA9E` |
| RX Characteristic (notify) | `6E400003-B5A3-F393-E0A9-E50E24DCCA9E` |
| Client Characteristic Config descriptor | `00002902-0000-1000-8000-00805f9b34fb` |
| Negotiated MTU | 251 bytes |
| Max practical chunk | ~194 bytes (BMP) / ~176 bytes (JSON) |
| ACK byte | `0xC9` |
| CONTINUE byte | `0xCB` |

The G1 has **two independent BLE connections**, one per arm (L/R). Always send L first; wait for ACK before sending R. `BleManager.sendBoth()` / `BleManager.requestList()` handle this.

---

## Enums

### `Commands` (outbound command byte)
| Name | Hex |
|------|-----|
| `BRIGHTNESS` | `0x01` |
| `SILENT_MODE` | `0x03` |
| `WHITELIST` | `0x04` |
| `DASHBOARD_SHOW` | `0x06` |
| `HEAD_UP_ANGLE` | `0x0B` |
| `BLE_REQ_MIC_ON` | `0x0E` |
| `CRC_CHECK` | `0x16` |
| `BLE_EXIT_ALL_FUNCTIONS` | `0x18` |
| `QUICK_NOTE_ADD` | `0x1E` |
| `BMP_END` | `0x20` |
| `BLE_REQ_HEARTBEAT` | `0x25` |
| `DASHBOARD_LAYOUT_COMMAND` | `0x26` |
| `BLE_REQ_BATTERY` | `0x2C` |
| `UNK_2` | `0x39` |
| `BLE_REQ_INIT` | `0x4D` |
| `NOTIFICATION` | `0x4B` |
| `BLE_REQ_EVENAI` | `0x4E` |
| `UNK_1` | `0x50` |
| `BLE_REQ_TRANSFER_MIC_DATA` | `0xF1` |
| `BLE_REQ_DEVICE_ORDER` | `0xF5` |

### `DeviceOrders` (inbound `0xF5` sub-byte)
| Name | Hex | Meaning |
|------|-----|---------|
| `DISPLAY_READY` | `0x00` | Display ready for content |
| `TRIGGER_CHANGE_PAGE` | `0x01` | Single tap — page change |
| `HEAD_UP2` | `0x02` | Head tilted up (R arm) |
| `HEAD_DOWN2` | `0x03` | Head tilted down (R arm) |
| `SILENCED` | `0x04` | Glasses silenced |
| `ACTIVATED` | `0x05` | Glasses activated |
| `CASE_REMOVED2` | `0x06` | Removed from case (alt) |
| `CASE_REMOVED` | `0x07` | Removed from case |
| `CASE_OPEN` | `0x08` | Case lid opened |
| `G1_IS_READY` | `0x09` | Glasses boot complete |
| `CASE_CLOSED` | `0x0B` | Case lid closed |
| `CASE_CHARGING_STATUS` | `0x0E` | Case charging state, `data[2]=0x01` charging |
| `CASE_CHARGE_INFO` | `0x0F` | Case battery %, `data[2]` = level |
| `TRIGGER_FOR_AI` | `0x17` | Long-press L / "Hey Even" — start recording |
| `TRIGGER_FOR_STOP_RECORDING` | `0x18` | Release — stop recording |
| `HEAD_UP` | `0x1E` | Head up (alternate event) |
| `HEAD_DOWN` | `0x1F` | Head down (alternate, rarely fired) |
| `DOUBLE_TAP` | `0x20` | Double tap |

### `DisplayStatus` (upper nibble of `newScreen` byte in `0x4E` packets)
| Name | Hex | Meaning |
|------|-----|---------|
| `NORMAL_TEXT` | `0x30` | Even AI displaying (auto mode) |
| `FINAL_TEXT` | `0x40` | Even AI last page (auto) |
| `MANUAL_PAGE` | `0x50` | Even AI manual page mode |
| `ERROR_TEXT` | `0x60` | Network error |
| `SIMPLE_TEXT` | `0x70` | Plain text show |

### `DashboardHeight` (0x26 height byte)
`0x00` = bottom … `0x08` = top

### `DashboardDepth` (0x26 depth byte)
`0x01` = shallowest … `0x09` = deepest

### `DashboardMode`
| Name | Hex |
|------|-----|
| `full` | `0x00` |
| `dual` | `0x01` |
| `minimal` | `0x02` |

---

## ⚠️ Critical Correction vs EvenDemoApp

The EvenDemoApp maps `0xF5 0x00` as double-tap. **This is incorrect.**

Per MentraOS `Enums.swift` and `G1.java`:
- `0xF5 0x00` = **DISPLAY_READY** (glasses display is ready for content)
- `0xF5 0x20` = **DOUBLE_TAP** (actual double-tap gesture)

MentraOS also notes the Android double-tap handling is "completely broken — clears the screen" and has it commented out. The EvenDemoApp likely re-purposed `0x00` empirically. On your specific firmware version, test what `0x00` actually fires, and whether `0x20` arrives on a real double-tap.

Similarly, MentraOS defines `0xF5 0x04` = SILENCED and `0xF5 0x05` = ACTIVATED — not triple-tap as mapped in EvenDemoApp. The triple-tap behaviour may vary by firmware version.

---

## Outbound Commands (App → Glasses)

### Connection init sequence
Sent after both arms connect, in this order. Allow 350ms after connect before beginning.

```
[0x6E, 0x74]              → both   — firmware version request (Android only)
[0x4D, 0x01]              → both   — init
[0x27, 0x00]              → both   — disable wear detection (Android)
[0x03, 0x0A]              → both   — silent mode off
whitelist 0x04            → both   — push app whitelist
brightness 0x01           → both   — restore brightness
head-up angle 0x0B        → both   — restore look-up angle
```

---

### Heartbeat — `0x25`
Sent every ~8–20 seconds.

```
iOS:     [0x25, seq]                           (2 bytes)
Android: [0x25, 0x06, seq, 0x00, 0x04, seq]   (6 bytes)
```

`seq` rolls 0–255. Also piggybacks battery query each cycle:
```
[0x2C, 0x01]    (both platforms; iOS may use 0x02 as second byte)
```

---

### Microphone — `0x0E`
```
[0x0E, 0x01]   mic on  → R arm only
[0x0E, 0x00]   mic off → R arm only
```

Android sends a **micbeat** — repeated `[0x0E, 0x01]` every few seconds while mic is active to prevent firmware timeout.

---

### Text / EvenAI Display — `0x4E`
Multi-packet. Packet builder in `EvenaiProto.evenaiMultiPackListV2()`.

```
[0x4E, seq, totalPkts, currentPkt, newScreen, charPos0, charPos1, pageNum, maxPages, ...utf8]
```

`newScreen` = `DisplayStatus` upper nibble | `0x01` new content. Example: `0x71` = text show + new content.
Max payload per chunk: ~176 bytes.
ACK: `[0x4E, 0xC9, seq]` matched by seq in `data[2]`.

---

### Brightness — `0x01`
```
[0x01, level, autoMode]
```
- `level`: 0–41 (iOS, 0x00–0x29) / 0–63 (Android, maps from 0–100%)
- `autoMode`: `0x01` auto on, `0x00` manual

ACK: `[0x01, 0xC9]`

---

### Head-Up Angle — `0x0B`
How far the user must tilt their head before `0xF5 0x02` fires.

```
[0x0B, angle, 0x01]
```
- `angle`: 0–60 degrees (clamped by firmware)

ACK: `[0x0B, 0xC9]`

---

### Dashboard Position — `0x26`
```
[0x26, 0x08, 0x00, counter, 0x02, 0x01, height, depth]
```
- `counter`: rolling `uint8`, must increment each call
- `height`: 0–8 (DashboardHeight)
- `depth`: 1–9 (DashboardDepth)

ACK: `[0x26, 0x06]` (hardcoded firmware value, noted as "seems arbitrary" in MentraOS source)

---

### Silent Mode — `0x03`
```
[0x03, 0x0C, 0x00]   silent on
[0x03, 0x0A, 0x00]   silent off
```

ACK: `[0x03, 0xC9]`

---

### Exit / Home — `0x18`
```
[0x18]
```
Returns glasses to dashboard. Both arms, ~100ms post-send delay.
ACK: `[0x18, 0xC9]`

---

### Notification Whitelist — `0x04`
Chunked JSON, max 176 bytes payload per chunk.

```
[0x04, totalChunks, chunkIndex, ...jsonPayload]
```

JSON:
```json
{
  "calendar_enable": false,
  "call_enable": false,
  "msg_enable": false,
  "ios_mail_enable": false,
  "app": {
    "list": [{"id": "com.example.app", "name": "App Name"}],
    "enable": true
  }
}
```

ACK sequence: `[0x04, 0xCB]` per intermediate chunk, then `[0x04, 0xC9]` final.

---

### Notification Send — `0x4B`
```
[0x4B, notifyId, totalChunks, chunkIndex, ...jsonPayload]
```
`notifyId` rolls 0–255. Max 176 bytes payload per chunk.

JSON:
```json
{
  "type": "Add",
  "ncs_notification": {
    "msg_id": 1234567890,
    "type": 1,
    "app_identifier": "com.example.app",
    "title": "Title",
    "subtitle": "Subtitle",
    "message": "Body text",
    "time_s": 1711234567,
    "date": "2024-01-01 12:00:00",
    "display_name": "App Name"
  }
}
```
> **Note:** The current `Proto.sendNotify` wraps in `{"ncs_notification": ...}` without the outer `"type": "Add"` key. MentraOS includes it. Test which the firmware requires.

---

### Quick Notes — `0x1E`

**Add / update** (slot is 0-based):
```
[0x1E, payloadLen, 0x00, versionByte,
 0x03, 0x01, 0x00, 0x01, 0x00,
 slotNumber, 0x01,
 nameLen, ...nameBytes,
 textLen, 0x00, ...textBytes]
```
`versionByte` = `unix_timestamp % 256` (firmware uses this to detect staleness).

**Delete** (by slot number):
```
[0x1E, 0x10, 0x00, 0xE0,
 0x03, 0x01, 0x00, 0x01, 0x00,
 noteNumber,
 0x00, 0x01, 0x00, 0x01, 0x00, 0x00]
```

ACK: `data[1] == 0x10` or `data[1] == 0x43`

---

### BMP Image — `0x15` + `0x20` + `0x16`
1-bit 576×136px BMP. 194-byte data chunks.

**Chunks:**
```
First:  [0x15, 0x00, 0x00, 0x1C, 0x00, 0x00, ...194 bytes BMP]
Others: [0x15, seqIndex, ...194 bytes BMP]
```
`seqIndex` = chunk index, 0-based uint8.

**End command:**
```
[0x20, 0x0D, 0x0E]
```
ACK: `[0x20, 0xC9]`

**CRC:**
```
[0x16, crc_byte3, crc_byte2, crc_byte1, crc_byte0]   (big-endian CRC32-XZ)
```
CRC input = `[0x00, 0x1C, 0x00, 0x00]` + full inverted BMP data.

> **Note:** Pixel bytes must be **bitwise inverted** (XOR `0xFF` on every byte after the 62-byte BMP header) before sending. EvenDemoApp does not do this; MentraOS does. Test both on your firmware.

BMP chunks are sent to both arms simultaneously (not L→R sequentially).
ACK: `[0x16, seqNum]` — always success.

---

### Quick Restart — `0x23 0x72` (Android only)
```
[0x23, 0x72]   → both arms
```
Undocumented restart command found in MentraOS G1.java.

---

## Inbound Events (Glasses → App)

### `0xF5 0xNN` — Device orders

See DeviceOrders enum table above for full mapping.

Key events for this app:

| Pattern | Event | Notes |
|---------|-------|-------|
| `0xF5 0x02` | Head up | R arm only. Configure threshold with `0x0B`. |
| `0xF5 0x03` | Head down | R arm only. |
| `0xF5 0x17` | Start recording | Long-press L or "Hey Even" wake word |
| `0xF5 0x18` | Stop recording | Release |
| `0xF5 0x20` | Double tap | See correction note above |
| `0xF5 0x01` | Single tap | Page navigation |
| `0xF5 0x1E` | Head up (alt) | Alternate head-up event |

---

### `0xF1` — LC3 Audio
```
[0xF1, seq, ...200 bytes LC3 data]
```
R arm only. LC3 config: **16 kHz, 10 ms frame duration, 20 bytes/frame (16 kbps)**.
`seq` = `data[1]`. LC3 payload = `data[2..201]`.

---

### `0x2C 0x66` — Battery response
```
[0x2C, 0x66, batteryPercent, flags, voltage_lo, voltage_hi, ...]
```
- `data[2]` = battery %
- `data[3]` = flags
- `data[4..5]` = voltage in 0.1 mV units, little-endian: `((data[5] << 8) | data[4]) / 10` mV

---

### `0x25` — Heartbeat response
```
[0x25, counter]
```

---

### `0x4E` — EvenAI display ACK
```
[0x4E, 0xC9, seq]
```
Matched by `seq` in `data[2]`.

---

### `0x4D` — Init ACK
```
[0x4D, 0xC9]
```
Triggers full boot sequence when received from both arms.

---

## Unknown Commands

| Hex | Enum | Notes |
|-----|------|-------|
| `0x39` | `UNK_2` | ACKs with `0xC9`. Purpose unknown. |
| `0x50` | `UNK_1` | ACKs with `0xC9`. Purpose unknown. |

Worth probing: send `[0x39]` and `[0x50]` while watching display and sensors to discover function.
Use the BLE Probe page in the app (Features → BLE Probe).

---

## Timing Constants

| Constant | Android | iOS |
|----------|---------|-----|
| Heartbeat interval | 15 s | 20 s |
| Delay between BLE chunks (general) | 5 ms | 8 ms |
| Delay between BMP chunks | 8 ms | 8 ms |
| Initial connection delay | 350 ms | 350 ms |
| Reconnect base delay | 3 s | 30 s |
| BMP end command timeout | 3 s | 1 s |

## Display / Hardware Constants

| Constant | Value |
|----------|-------|
| Display width | 488 px |
| Font size | 21 px |
| Lines per screen | 5 |
| Max text chunk payload | 176 bytes |
| BMP dimensions | 576 × 136 px |
| BMP format | 1-bit monochrome |
| BMP header size | 62 bytes |
| BMP chunk size | 194 bytes |
| LC3 sample rate | 16 kHz |
| LC3 frame duration | 10 ms |
| LC3 frame size | 20 bytes (16 kbps) |

---

## Connection Sequencing

1. L arm connects first. R arm GATT connect waits until L is connected.
   Android: R starts at t=2 s (first connect) or t=400 ms (reconnect).
2. Notifications enabled on RX characteristic. Write CCCD descriptor `[0x01, 0x00]` after 500 ms sleep.
3. Init sequence fires only when **both** sides have acknowledged `0x4D` with `0xC9`.
4. Allow 350 ms after connect before sending the init sequence.

---

## Sources

- [MentraOS G1.swift](https://github.com/Mentra-Community/MentraOS/blob/main/mobile/modules/core/ios/Source/sgcs/G1.swift)
- [MentraOS G1.java](https://github.com/Mentra-Community/MentraOS/blob/main/mobile/modules/core/android/src/main/java/com/mentra/core/sgcs/G1.java)
- [MentraOS Enums.swift](https://github.com/Mentra-Community/MentraOS/blob/main/mobile/modules/core/ios/Source/utils/Enums.swift)
- [even-realities/EvenDemoApp](https://github.com/even-realities/EvenDemoApp)
