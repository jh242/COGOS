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

In PacketLogger, the capture should already be filtered to:

- ATT handle `0x0403` (left arm write)
- ATT handle `0x0405` (right arm write)

Each row in the filtered view is one `ATT Write Command` from phone → glasses.
Export or copy the visible rows. The relevant columns are **Timestamp** and
**Value** (the raw hex payload).

If the log is unfiltered, apply in PacketLogger's filter bar:
```
att.handle == 0x0403 || att.handle == 0x0405
```
Then `File → Save` to export only the filtered packets.

---

## Step 2 — Group by command family

The first byte of the Value column is the top-level command byte. Bucket
every row by that byte:

| First byte | Family | Status |
|------------|--------|--------|
| `0x06` | Dashboard panes | Partially pinned — see below |
| `0x1E` | Quick Notes | **Unknown** — target |
| `0x58` | Dashboard next-up | **Unknown** — target |
| `0x25` | Heartbeat | Known, ignore |
| `0x0E` | Mic control | Known, ignore |
| `0x4E` | Even AI text | Known, ignore |
| anything else | Unknown | Note but don't block on it |

Within `0x06`, the second byte is the sub-command:

| `0x06` sub | Surface | Status |
|------------|---------|--------|
| `0x01` | Time + weather | **Pinned** — layout in reference doc |
| `0x03` | Calendar | **Pinned** — layout in reference doc |
| `0x04` | Stocks | **Unknown** — target |
| `0x05` | News | **Unknown** — target |
| `0x06` | Dashboard mode | **Pinned** — layout in reference doc |

---

## Step 3 — Correlate bytes to test actions

Match the packet timestamps to the test log (the written record of what was
done in the Even app and when). This is what separates "this byte is a
timestamp" from "this byte is a string length".

For each unknown packet family, the minimum test sequence to decode it:

### `0x1E` Quick Notes

| Action | What it tells you |
|--------|------------------|
| Add note with title "A", body "B" | Baseline encoding: find title and body bytes, find length prefix or delimiters, find note-id field |
| Add second note, title "CD", body "EFG" | Confirm length encoding pattern, find id=1 vs id=0 |
| Edit note 0: change body to "HIJKLMN" | Find which bytes changed → isolates body field |
| Delete note 0 | Find delete sub-command and its arguments |
| Clear all notes | Find clear-all vs delete-by-id distinction |

For each packet: write out the bytes with field annotations once you've
decoded them, e.g.:
```
1E 03 00 41 42 43 ...
│  │  │  └─ title bytes ("ABC")
│  │  └─ note_id
│  └─ sub-command (03 = add? edit?)
└─ command byte
```

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

This likely fires when a calendar event transitions to "next up". If the test
log shows it firing, note exact byte layout. Cross-reference with the
`CalendarEvent` struct already in `DashboardTypes.swift` — the fields may
overlap.

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
enum QuickNoteProto {
    static func addNotePacket(id: UInt8, title: String, body: String, seq: UInt8) -> Data
    static func deleteNotePacket(id: UInt8, seq: UInt8) -> Data
    static func clearNotesPacket(seq: UInt8) -> Data
}
```

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
