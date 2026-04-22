import Foundation

/// Packet builder for `0x1E 0x03 NOTE_TEXT_EDIT` (Quick Notes text slot).
/// Pinned 2026-04-17 via PacketLogger capture of the official Even iOS app;
/// wire layout in `docs/G1_PROTOCOL_REFERENCE.md`.
///
/// Protocol semantics: the firmware exposes **4 slots** (1-based). Every
/// update writes 4 packets back-to-back, one per slot, whether or not each
/// slot changed. There is no incremental per-slot update — absent slots use
/// the fixed 7-byte empty template.
enum QuickNoteProto {
    private static let cmd: UInt8 = 0x1E
    private static let subCmd: UInt8 = 0x03
    static let slotCount = 4

    /// Build the 4-packet write sequence for a single Quick Notes update.
    /// `slots` is indexed 0..3 for slot ids 1..4; entries past `slotCount`
    /// are ignored and missing entries are treated as `nil` (empty slot).
    static func setSlotsPackets(_ slots: [QuickNote?], startingSeq: UInt8) -> (packets: [Data], nextSeq: UInt8) {
        var packets: [Data] = []
        var seq = startingSeq
        for i in 0..<slotCount {
            let slotId = UInt8(i + 1)
            let note = i < slots.count ? slots[i] : nil
            packets.append(buildPacket(slotId: slotId, note: note, seq: seq))
            seq = seq &+ 1
        }
        return (packets, seq)
    }

    private static func buildPacket(slotId: UInt8, note: QuickNote?, seq: UInt8) -> Data {
        let body: Data = note.map { nonEmptyBody(slotId: slotId, note: $0) }
            ?? emptyBody(slotId: slotId)
        var pack = Data(count: 9)
        pack[0] = cmd
        pack[1] = UInt8(truncatingIfNeeded: 9 + body.count)
        pack[2] = 0x00
        pack[3] = seq
        pack[4] = subCmd
        pack[5] = 0x01                  // chunk_count — observed: always 1
        pack[6] = 0x00
        pack[7] = 0x01                  // chunk_index — observed: always 1
        pack[8] = 0x00
        pack.append(body)
        return pack
    }

    /// `[slot_id][0x01][title_len:u8][title_utf8][body_len:u16 LE][body_utf8]`
    private static func nonEmptyBody(slotId: UInt8, note: QuickNote) -> Data {
        let titleUtf8 = note.title.utf8Truncated(max: 0xFF)
        let fullBody = Data(note.body.utf8)
        let bodyLen = UInt16(min(fullBody.count, Int(UInt16.max)))
        let bodyUtf8 = fullBody.prefix(Int(bodyLen))

        var out = Data()
        out.append(slotId)
        out.append(0x01)                                  // title tag
        out.append(UInt8(titleUtf8.count))
        out.append(titleUtf8)
        out.append(UInt8(bodyLen & 0xFF))                 // u16 LE
        out.append(UInt8((bodyLen >> 8) & 0xFF))
        out.append(bodyUtf8)
        return out
    }

    /// Fixed 7-byte empty-slot template (`[slot_id] 00 01 00 01 00 00`).
    /// Treat the tail as literal — not a TLV encoding.
    private static func emptyBody(slotId: UInt8) -> Data {
        Data([slotId, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00])
    }
}

extension String {
    /// Encode to UTF-8, truncating to at most `max` bytes without splitting a
    /// multi-byte code point. Shared by the `0x06 0x03` calendar TLV builder
    /// and the `0x1E 0x03` Quick Notes title builder, both of which use a
    /// single-byte length prefix.
    func utf8Truncated(max: Int) -> Data {
        let full = Data(utf8)
        if full.count <= max { return full }
        var end = max
        while end > 0 && (full[end] & 0xC0) == 0x80 { end -= 1 }
        return full.prefix(end)
    }
}
