import Foundation

/// Encoder for the firmware-native `0x54` AI text command family.
///
/// Every prepare, text update, scroll update, and close consumes a fresh
/// sequence number. Only chunks belonging to the same text update share a
/// sequence number.
enum EvenAIText54 {
    static let maxChunkPayload = 100
    static let maxTextPayload = maxChunkPayload * Int(UInt8.max)

    /// The byte-9/byte-11 state carried by a text update.
    enum TextMode: Equatable, Sendable {
        /// Reply still fits the viewport; firmware keeps the newest text visible.
        case streaming
        /// Reply has exceeded the viewport; the phone sends one five-line page.
        case passiveScroll
        /// Completed reply controlled by TouchBar taps. Position is 0...100.
        case interactive(position: UInt8)

        fileprivate var scrollFlag: UInt8 {
            switch self {
            case .streaming, .passiveScroll: return 0x00
            case .interactive: return 0x01
            }
        }

        fileprivate var status: UInt8 {
            switch self {
            case .streaming: return 0xFF
            case .passiveScroll: return 0x64
            case .interactive(let position): return min(position, 100)
            }
        }
    }

    /// Opens a new AI reply.
    static func preparePacket(seq: UInt8) -> Data {
        Data([0x54, 0x0C, 0x00, seq, 0x02, 0x01, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00])
    }

    /// Ends the current reply or interactive viewer.
    static func closePacket(seq: UInt8) -> Data {
        Data([0x54, 0x06, 0x00, seq, 0x01, 0x00])
    }

    /// Encodes one cumulative or windowed text update.
    static func textPackets(
        seq: UInt8,
        text: String,
        mode: TextMode = .streaming
    ) -> [Data] {
        let payload = text.utf8Truncated(max: maxTextPayload)
        if payload.isEmpty {
            return [headerOnlyText(seq: seq, mode: mode)]
        }

        let slices = utf8Slices(payload, maxBytes: maxChunkPayload)
        let chunkCount = max(1, slices.count)
        var packets: [Data] = []
        packets.reserveCapacity(chunkCount)

        for (index, slice) in slices.enumerated() {
            var packet = Data([
                0x54, UInt8(12 + slice.count), 0x00,
                seq, 0x03,
                UInt8(chunkCount), 0x00,
                UInt8(index + 1), 0x00,
                mode.scrollFlag, 0x00, mode.status
            ])
            packet.append(slice)
            packets.append(packet)
        }
        return packets
    }

    private static func headerOnlyText(seq: UInt8, mode: TextMode) -> Data {
        Data([
            0x54, 0x0C, 0x00,
            seq, 0x03,
            0x01, 0x00,
            0x01, 0x00,
            mode.scrollFlag, 0x00, mode.status
        ])
    }

    /// Split on UTF-8 code-point boundaries so a 100-byte BLE chunk never
    /// ends in the middle of a character. Firmware concatenates chunks as
    /// text; a torn code point dropped the last word of a page.
    private static func utf8Slices(_ data: Data, maxBytes: Int) -> [Data] {
        guard !data.isEmpty else { return [] }

        var slices: [Data] = []
        var start = 0
        while start < data.count, slices.count < Int(UInt8.max) {
            var end = min(start + maxBytes, data.count)
            if end < data.count {
                while end > start && (data[end] & 0xC0) == 0x80 {
                    end -= 1
                }
                if end == start {
                    end = min(start + maxBytes, data.count)
                }
            }
            slices.append(data.subdata(in: start..<end))
            start = end
        }
        return slices
    }
}
