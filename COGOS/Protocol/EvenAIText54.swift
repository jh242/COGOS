import Foundation

/// Encoder for the firmware-native streaming TEXT command (0x54).
///
/// Supersedes the legacy 0x4E multi-packet flow. Observed from the official
/// Even AI app: each AI reply begins with a `prepare` packet, followed by
/// cumulative text updates (each update carries the entire answer so far).
/// The firmware appends / replaces the displayed buffer and paginates on
/// its own — the phone never manages line wrapping or page state.
///
/// Header layout (12 bytes, little-endian fields are single-byte):
/// ```
/// 0:  0x54                 — cmd
/// 1:  total_length         — header + payload, ≤ 0xFF
/// 2:  0x00
/// 3:  seq                  — one per logical message; all chunks of a
///                            multi-chunk update share the same seq
/// 4:  sub                  — 0x02 prepare, 0x03 text
/// 5:  chunk_count          — total chunks in this update
/// 6:  0x00
/// 7:  chunk_index          — 1-based
/// 8:  0x00
/// 9:  0x00 (text) / 0x01 (prepare)
/// 10: 0x00
/// 11: 0xFF (text body marker) / 0x00 (prepare)
/// 12+: UTF-8 text           — only for sub=0x03
/// ```
///
/// ACK: glasses reply with `54 0A 00 <seq> <sub> <count> 00 <idx> 00 C9`.
/// `BleRequestQueue` matches on the first byte, so a generic reply is fine.
enum EvenAIText54 {
    /// Max UTF-8 bytes per chunk. Observed max packet length is ~0x70 (112
    /// bytes); header is 12 bytes so payload ≤ 100 bytes.
    static let maxChunkPayload = 100

    /// Byte-11 state values observed in Even app captures:
    /// - `0xFF` while the reply is still arriving (firmware keeps viewport
    ///    pinned to the bottom)
    /// - `0x64` (100) on the final re-send of a complete reply — this is
    ///    what flips firmware into scrollable mode. Without it, single-tap
    ///    scroll does nothing and the user can only see the last 3 lines.
    /// - `0x00..0x64` carries a scroll position percentage when the phone
    ///    is driving scroll from user taps (sub-byte 9 set to 0x01).
    enum Status: UInt8 {
        case streaming = 0xFF
        case complete = 0x64
    }

    /// Prepare packet. Signals "text incoming" — sent once at the start of
    /// a reply, before the first text update.
    static func preparePacket(seq: UInt8) -> Data {
        Data([0x54, 0x0C, 0x00, seq, 0x02, 0x01, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00])
    }

    /// Text-update packets. Splits `text` into ≤100-byte chunks and emits
    /// one packet per chunk. All share the same `seq`. `status` controls
    /// byte 11 — use `.complete` only for the final re-send that enables
    /// native scroll.
    static func textPackets(seq: UInt8, text: String, status: Status = .streaming) -> [Data] {
        let payload = Data(text.utf8)
        if payload.isEmpty {
            return [headerOnlyText(seq: seq, chunkCount: 1, chunkIndex: 1, status: status)]
        }
        let chunkCount = max(1, Int((payload.count + maxChunkPayload - 1) / maxChunkPayload))
        var packets: [Data] = []
        packets.reserveCapacity(chunkCount)
        for i in 0..<chunkCount {
            let start = i * maxChunkPayload
            let end = min(start + maxChunkPayload, payload.count)
            let slice = payload.subdata(in: start..<end)
            let totalLen = 12 + slice.count
            var pack = Data([
                0x54, UInt8(totalLen & 0xFF), 0x00,
                seq, 0x03,
                UInt8(chunkCount & 0xFF), 0x00,
                UInt8((i + 1) & 0xFF), 0x00,
                0x00, 0x00, status.rawValue
            ])
            pack.append(slice)
            packets.append(pack)
        }
        return packets
    }

    private static func headerOnlyText(seq: UInt8, chunkCount: Int, chunkIndex: Int, status: Status) -> Data {
        Data([
            0x54, 0x0C, 0x00,
            seq, 0x03,
            UInt8(chunkCount & 0xFF), 0x00,
            UInt8(chunkIndex & 0xFF), 0x00,
            0x00, 0x00, status.rawValue
        ])
    }
}
