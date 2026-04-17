# BLE Sniff Analysis — G1 Protocol Decoding

Instruction doc for Claude: given a PacketLogger capture from the official
Even Realities app, decode unknown G1 command payloads and update the
protocol reference + Swift implementation.

---

## Step 0 — Read context first

Before touching the log, read these files in full:

1. `docs/G1_PROTOCOL_REFERENCE.md` — all pinned byte layouts and known gaps
2. `COGOS/Protocol/DashboardTypes.swift` — Swift types for what's already wired
3. `COGOS/Protocol/DashboardProto.swift` — packet assemblers for the known `0x06` family
4. `docs/superpowers/plans/2026-04-16-firmware-dashboard-migration.md` — what we're trying to ship and why

This gives you the full picture of what's known vs blocked before you
interpret a single byte.

---

## Step 1 — Extract G1 packets from the log

**ATT handles (from live capture, 2026-04-17):**

- Write (phone → glasses): **`0x0015`** on both arms
- Notify (glasses → phone): **`0x0012`** on both arms
- Arm is distinguished by the **HCI connection handle**, not the ATT handle:
  - `0x0401` = left arm
  - `0x0404` = right arm
  (These vary per pairing session — confirm from the log's connect events.)

The `0x0403 / 0x0405` ATT handles referenced in older Gadgetbridge / MentraOS
sources are **not** what the G1 actually exposes; ignore them.

**PacketLogger workflow:**

1. `File → Export As → Text File`.
2. In the export dialog, enable **"Include Packet Bytes"** (raw mode). The
   default "summary" export truncates every Value column at 16 hex bytes with
   `…`, which is useless for multi-packet decoding. The raw export appends
   the full HCI payload after the Value column — that's what we parse.
3. Name the output `<scenario>_Raw.txt`.

**What each raw line looks like:**

```
Apr 17 08:08:53.682  ATT Send  0x0401  ...  Handle:0x0015 - Value: 1E23 ...  \
  01 04 2A 00 26 00 04 00 52 15 00 1E 23 00 90 03 01 00 01 00 01 01 05 54 …
```

The raw HCI trailer after the Value column is the full bytes. To extract the
G1 packet, strip everything up to and including the ATT opcode / handle
prefix (`52 15 00` = Write Command to handle 0x0015). Everything after is the
G1 payload.

**Wireshark alternative:** If you re-export the `.pklg` as `.pcap` and open
in Wireshark, the downlink filter is:
```
btatt.handle == 0x0015 && btatt.opcode == 0x52
```

---

## Step 2 — Group by command family

The first byte of the G1 payload is the top-level command byte. Bucket every
row by that byte:

| First byte | Family | Status |
|------------|--------|--------|
| `0x06` | Dashboard panes | Partially pinned — see below |
| `0x1E` | Quick Notes | **Pinned (2026-04-17)** — layout below |
| `0x22` | Status-get family | Sub `0x05` observed on right arm after every dashboard ping — layout below |
| `0x58` | Dashboard next-up | **Unknown** — not yet observed firing in any capture |
| `0x2C` | Battery + firmware GET | Known get, ignore |
| `0x2B` | Silent-mode GET | Known get, ignore |
| `0x29` | Brightness GET | Known get, ignore |
| `0x0E` | Mic control | Known, ignore |
| `0x4E` | Even AI text | Known, ignore |
| anything else | Unknown | Note but don't block on it |

Within `0x06`, the second byte is the sub-command:

| `0x06` sub | Surface | Status |
|------------|---------|--------|
| `0x01` | Time + weather | **Pinned** — note: reference doc says 21 bytes but live is **22 bytes** (one extra trailing `00`) |
| `0x03` | Calendar | **Pinned** — note: reference doc's `01 03 03` magic prefix is wrong; Even app's empty-calendar body is `00 00 02` |
| `0x04` | Stocks | **Unknown** — target |
| `0x05` | News | **Unknown** — target |
| `0x06` | Dashboard mode | **Pinned** — matches reference doc exactly |

**The Even app does a full dashboard re-push every ~5s**, sending (in order):
`06 06 MODE` → `06 01 TIME_WEATHER` → `06 03 CALENDAR` → `22 05 STATUS` (right arm only).
Same bytes go to both L and R, back-to-back. That's the steady-state traffic
you'll see between user actions.

---

## Step 3 — Correlate bytes to test actions

Match the packet timestamps to the test log (the written record of what was
done in the Even app and when). This is what separates "this byte is a
timestamp" from "this byte is a string length".

For each unknown packet family, the minimum test sequence to decode it:

### `0x1E` Quick Notes — pinned 2026-04-17

Wire layout (non-empty body, empty-slot template, chunked header, worked
examples) lives in [`docs/G1_PROTOCOL_REFERENCE.md`](G1_PROTOCOL_REFERENCE.md)
under the `0x1E 0x03 NOTE_TEXT_EDIT` section. Don't duplicate it here.

**Protocol-level findings from that session** (not byte-level — kept here
because these shape how Swift code consumes the protocol):

1. **Only sub-command `0x03` is ever emitted by the Even app**. The
   `0x08 NOTE_ADD` / `0x07 NOTE_STATUS_EDIT` / `0x0A` constants declared in
   Gadgetbridge are unused in practice — `0x03` handles add, edit, and clear.
2. **Replace-all-4-slots protocol.** Every user action writes exactly 4
   packets back-to-back, one per slot (1..4), whether or not each slot
   changed. There's no incremental per-slot update. Swift implementation
   should expose one "set all slots" entry point, not "add/delete/edit".
3. Each packet is sent to L then R with the same seq byte.

These three points stay in future sniff analyses because they're not
obvious from reading the reference doc alone — they're architectural
observations about how the Even app chose to use the primitives.

### `0x06 0x04` Stocks and `0x06 0x05` News

These are likely length-prefixed lists of strings (ticker symbols / headline
strings). Use the same method:

| Action | What it reveals |
|--------|----------------|
| Set 1 stock (3-letter ticker) | Baseline structure |
| Set 3 stocks | Confirm per-item encoding, list length field |
| Remove 1 stock | Update vs full-replace pattern |
| Clear | Clear sub-command |

Same for News — enable pane with one topic, swap topic, disable.

### `0x58` Next-up

Not yet observed in any capture. Theory: fires when a calendar event
transitions to "next up" within the dashboard's visible window. To trigger,
schedule a calendar event starting in ~5 minutes and capture across the
boundary.

If/when captured, cross-reference with the `CalendarEvent` struct in
`DashboardTypes.swift` — the fields may overlap.

### `0x22 0x05` — status/handshake (new, right arm only)

Observed after every dashboard-ping cycle, sent only on the right HCI handle:

```
22 05 00 <seq> 01         (5 bytes, matches length byte [1])
```

Response from glasses:
```
22 05 00 <seq> 01 0A 01 01
```

Not documented in the reference doc. Not present on the left arm. Appears to
be a lightweight "still alive / apply dashboard" acknowledgement. Worth
adding to `G1_PROTOCOL_REFERENCE.md` with an explicit note that this is
right-arm-only and what the response trailing bytes (`0A 01 01`) mean — still
unknown.

---

## Step 4 — Use pinned layouts as decoding templates

The three pinned `0x06` commands share structural patterns. Apply them as
priors before guessing:

### Chunk header pattern (from `0x06 0x03 CALENDAR`)

```
[cmd:1] [sub:1] [seq:1] [total_chunks:1] [chunk_index:1] [total_len:2 LE] [chunk_body_len:2 LE]
```
If an unknown packet has a 9-byte header that looks like this, it's a chunked
command. Body follows immediately after.

### Fixed-packet pattern (from `0x06 0x01` and `0x06 0x06`)

Short commands (≤ 32 bytes) are likely fixed-layout with no chunk header.
Look for:
- 4-byte or 8-byte integer fields (little-endian; probe by checking if
  re-interpreting as LE gives a plausible unix timestamp or integer value)
- 1-byte enum fields (small integer 0x00–0x0F, maps to a named value)
- 1-byte signed integers (temperature, percentage)

### TLV pattern (from `0x06 0x03 CALENDAR` body)

```
[type:1] [len:1] [value:len bytes]
```
If you see alternating small integers followed by ASCII-looking sequences,
it's TLV. Known TLV tag assignments for calendar:
- `0x01` = title (utf-8)
- `0x02` = time string (utf-8, pre-formatted)
- `0x03` = location (utf-8)

Quick Notes may use the same TLV structure with different tag assignments.

---

## Step 5 — Update `docs/G1_PROTOCOL_REFERENCE.md`

For each newly decoded command, add a pinned layout block in the reference
doc following the same format as the existing `0x06 0x01` / `0x06 0x03` /
`0x06 0x06` sections. Include:

- Fixed layout table **or** chunk header + TLV body description
- Any enums decoded (with their byte values)
- Known constraints (max items, max string length, encoding)
- A `> ⚠️ Gap` note for any fields still uncertain

Remove or replace the existing `> ⚠️ Gap` warnings for the commands you've
successfully decoded.

---

## Step 6 — Implement Swift helpers

Once layouts are pinned, add packet assemblers following the same pattern as
`DashboardProto.swift`:

**For Quick Notes** — new file `COGOS/Protocol/QuickNoteProto.swift`:
```swift
struct QuickNote { let title: String; let body: String }

enum QuickNoteProto {
    // Always emits exactly 4 packets (one per slot 1..4). Pass `nil` for
    // empty slots. Caller feeds `seq` as a contiguous 4-byte range.
    static func setSlotsPackets(_ slots: [QuickNote?], startingSeq: UInt8) -> [Data]
}
```
Single entry point because the firmware protocol is "replace all 4 slots" —
there's no per-slot add/delete. The implementation emits a non-empty body
(see pinned layout above) for `QuickNote` values and the fixed 7-byte empty
template for `nil` slots.

**For Stocks / News** — extend `DashboardProto.swift` with:
```swift
static func stocksPacket(_ tickers: [String], seq: UInt8) -> Data
static func newsPacket(_ headlines: [NewsHeadline], seq: UInt8) -> Data   // or whatever the payload turns out to be
```

**For `0x58` next-up** — extend `DashboardProto.swift` or `QuickNoteProto.swift`
depending on whether the payload resembles a calendar event or a note.

Then expose each as a `Proto` actor method in `Proto.swift`, following the
same `@discardableResult async -> Bool` pattern as `setDashboardCalendar`.

Finally, wire Quick Notes into `GlanceService.pushFirmwareDashboard(now:)` —
the contextual winner goes to slot 0 via `addQuickNote` / `deleteQuickNote`.

---

## Step 7 — Commit order

1. `docs/G1_PROTOCOL_REFERENCE.md` — pinned layouts (standalone, reviewable)
2. `COGOS/Protocol/DashboardTypes.swift` — any new Swift types (enums, structs)
3. `COGOS/Protocol/QuickNoteProto.swift` (if new file)
4. `COGOS/Protocol/DashboardProto.swift` — stocks / news / next-up assemblers
5. `COGOS/Protocol/Proto.swift` — new `Proto` actor methods
6. `COGOS/Glance/GlanceService.swift` — wire contextual winner to Quick Notes

Each commit message should cite the specific command byte(s) it covers so
the git log is self-documenting.
