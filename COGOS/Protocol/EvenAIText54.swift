import Foundation

/// Encoder for the `0x54` text-command family used by the Even AI reply flow.
///
/// Three sub-commands, distinguished by header byte 4:
/// - `0x02` prepare — opens a reply
/// - `0x03` text    — cumulative or windowed UTF-8 payload
/// - `0x01` close   — 6-byte terminator ending a reply
///
/// Header layout for prepare and text (12 bytes + optional UTF-8):
/// ```
/// 0:  0x54
/// 1:  total length (header + payload)
/// 2:  0x00
/// 3:  seq
/// 4:  sub (0x02 | 0x03)
/// 5:  chunk_count
/// 6:  0x00
/// 7:  chunk_index (1-based)
/// 8:  0x00
/// 9:  scroll flag — 0x00 streaming/auto-scroll, 0x01 interactive viewer
/// 10: 0x00
/// 11: status
///     prepare:    0x00
///     streaming:  0xFF (firmware tails, shows last ~3 lines)
///     auto-scroll: 0x64 with scroll=0x00 (phone re-sends a shrinking
///                  window to simulate reading pace)
///     interactive: 0x00..0x64 with scroll=0x01 (scroll-position percent)
/// 12+: UTF-8 text (sub=0x03 only)
/// ```
///
/// Close packet: `54 06 00 <seq> 01 00` (6 bytes, no payload).
///
/// ACK: `54 0A 00 <seq> <sub> <count> 00 <idx> 00 C9`. `BleRequestQueue`
/// matches on the first byte, so a generic reply is fine.
enum EvenAIText54 {
    /// Conservative per-chunk payload cap. Firmware accepts up to ~169
    /// bytes in one write; we stick to 100 to match older captures.
    static let maxChunkPayload = 100

    /// Well-known status byte values. Any `UInt8` is accepted by
    /// `textPackets` — in interactive mode the byte carries a 0–100
    /// scroll-position percent.
    enum Status {
        static let streaming: UInt8 = 0xFF
        static let complete: UInt8 = 0x64
    }

    /// Well-known scroll-flag (header byte 9) values.
    enum ScrollFlag {
        /// Streaming or phone-driven auto-scroll.
        static let passive: UInt8 = 0x00
        /// User-controlled scroll viewer; `status` byte carries the percent.
        static let interactive: UInt8 = 0x01
    }

    /// Prepare packet. Signals "text incoming" — sent once at the start of
    /// a reply, before the first text update.
    static func preparePacket(seq: UInt8) -> Data {
        Data([0x54, 0x0C, 0x00, seq, 0x02, 0x01, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00])
    }

    /// 6-byte close packet — ends a reply. Sent after the last text
    /// update (short replies) or after the user exits the scroll viewer.
    static func closePacket(seq: UInt8) -> Data {
        Data([0x54, 0x06, 0x00, seq, 0x01, 0x00])
    }

    /// Text-update packets. Splits `text` into ≤100-byte chunks and emits
    /// one packet per chunk. All chunks of one update share the same
    /// `seq`, `scrollFlag`, and `status`.
    static func textPackets(
        seq: UInt8,
        text: String,
        status: UInt8 = Status.streaming,
        scrollFlag: UInt8 = ScrollFlag.passive
    ) -> [Data] {
        let payload = Data(text.utf8)
        if payload.isEmpty {
            return [headerOnlyText(seq: seq, chunkCount: 1, chunkIndex: 1, scrollFlag: scrollFlag, status: status)]
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
                scrollFlag, 0x00, status
            ])
            pack.append(slice)
            packets.append(pack)
        }
        return packets
    }

    private static func headerOnlyText(seq: UInt8, chunkCount: Int, chunkIndex: Int, scrollFlag: UInt8, status: UInt8) -> Data {
        Data([
            0x54, 0x0C, 0x00,
            seq, 0x03,
            UInt8(chunkCount & 0xFF), 0x00,
            UInt8(chunkIndex & 0xFF), 0x00,
            scrollFlag, 0x00, status
        ])
    }
}
