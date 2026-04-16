import Foundation

/// Packet builders for the `0x06 DASHBOARD_SET` command family.
/// Byte layouts ported from Gadgetbridge `G1Communications.java`.
/// See `docs/G1_PROTOCOL_REFERENCE.md` for the pinned wire format.
enum DashboardProto {

    /// Max packet size observed by firmware (header + body).
    private static let maxPacketSize = 180

    // MARK: - 0x06 0x01 TIME_AND_WEATHER

    /// Fixed 21-byte packet. `seq` is caller-assigned (wraps every 256).
    static func timeAndWeatherPacket(now: Date, weather: WeatherInfo, seq: UInt8) -> Data {
        let ms = UInt64(now.timeIntervalSince1970 * 1000)
        let secs = UInt32(ms / 1000)

        // 21-byte packet. Byte 1 = total length (0x15 = 21), byte 2 = pad.
        var pack = Data(count: 21)
        pack[0] = 0x06        // DASHBOARD_SET
        pack[1] = 0x15        // total length
        pack[2] = 0x00
        pack[3] = seq
        pack[4] = 0x01        // TIME_AND_WEATHER sub-command

        writeU32LE(secs, into: &pack, at: 5)
        writeU64LE(ms, into: &pack, at: 9)

        // Firmware swaps SUNNY ↔ NIGHT itself based on sunrise/sunset lookup,
        // so we just forward the app's notion of the condition.
        pack[17] = weather.icon.rawValue
        // Int8 temperature — encode two's complement into UInt8.
        pack[18] = UInt8(bitPattern: weather.temperatureCelsius)
        pack[19] = weather.displayFahrenheit ? 0x01 : 0x00
        pack[20] = weather.hour24 ? 0x01 : 0x00
        return pack
    }

    // MARK: - 0x06 0x06 MODE

    /// Fixed 7-byte mode packet.
    static func modePacket(_ mode: DashboardMode, paneMode: DashboardPaneMode, seq: UInt8) -> Data {
        Data([
            0x06,            // DASHBOARD_SET
            0x07,            // total length
            0x00,
            seq,
            0x06,            // MODE sub-command
            mode.rawValue,
            paneMode.rawValue
        ])
    }

    // MARK: - 0x06 0x03 CALENDAR

    /// Build the chunked calendar packets. Caller supplies a starting `seq`
    /// and receives back `(packets, nextSeq)` — each chunk consumes one seq.
    static func calendarPackets(_ events: [CalendarEvent], startingSeq: UInt8) -> (packets: [Data], nextSeq: UInt8) {
        let body = calendarBody(events)
        // 9-byte per-chunk header → body capacity = 180 − 9 = 171.
        let bodyCap = maxPacketSize - 9
        var chunks: [Data] = []
        var offset = 0
        while offset < body.count {
            let end = min(offset + bodyCap, body.count)
            chunks.append(body.subdata(in: offset..<end))
            offset = end
        }
        if chunks.isEmpty { chunks = [Data()] } // should not happen — body always has prefix

        let chunkCount = UInt8(min(chunks.count, 255))
        var packets: [Data] = []
        var seq = startingSeq
        for (i, chunk) in chunks.enumerated() {
            let chunkIndex = UInt8(i + 1) // 1-based per Gadgetbridge
            var header = Data(count: 9)
            header[0] = 0x06
            header[1] = UInt8(9 + chunk.count)   // total chunk length incl. header
            header[2] = 0x00
            header[3] = seq
            header[4] = 0x03                      // CALENDAR sub-command
            header[5] = chunkCount
            header[6] = 0x00
            header[7] = chunkIndex
            header[8] = 0x00
            var pack = header
            pack.append(chunk)
            packets.append(pack)
            seq = seq &+ 1
        }
        return (packets, seq)
    }

    /// Assemble the pre-chunking TLV body. Public for testing / introspection.
    static func calendarBody(_ events: [CalendarEvent]) -> Data {
        var body = Data()
        body.append(contentsOf: [0x01, 0x03, 0x03]) // 3-byte magic (purpose unknown per GB)

        let clamped = Array(events.prefix(8))
        if clamped.isEmpty {
            // Empty-state placeholder event — matches Gadgetbridge behaviour.
            body.append(0x01) // event_count
            appendTLV(type: 0x01, string: "No events", into: &body)
            appendTLV(type: 0x02, string: "", into: &body)
            appendTLV(type: 0x03, string: "", into: &body)
        } else {
            body.append(UInt8(clamped.count))
            for ev in clamped {
                appendTLV(type: 0x01, string: ev.title, into: &body)
                appendTLV(type: 0x02, string: ev.timeString, into: &body)
                appendTLV(type: 0x03, string: ev.location, into: &body)
            }
        }
        return body
    }

    // MARK: - Helpers

    private static func appendTLV(type: UInt8, string: String, into body: inout Data) {
        let utf8 = truncatedUTF8(string, max: 0xFF)
        body.append(type)
        body.append(UInt8(utf8.count))
        body.append(utf8)
    }

    /// Truncate a UTF-8 string so it fits in `max` bytes without splitting a
    /// multi-byte code point.
    private static func truncatedUTF8(_ s: String, max: Int) -> Data {
        let full = Data(s.utf8)
        if full.count <= max { return full }
        var end = max
        // Back up past continuation bytes (10xxxxxx) so we land on a lead byte.
        while end > 0 && (full[end] & 0xC0) == 0x80 { end -= 1 }
        return full.prefix(end)
    }

    private static func writeU32LE(_ v: UInt32, into data: inout Data, at offset: Int) {
        data[offset]     = UInt8(v         & 0xff)
        data[offset + 1] = UInt8((v >> 8)  & 0xff)
        data[offset + 2] = UInt8((v >> 16) & 0xff)
        data[offset + 3] = UInt8((v >> 24) & 0xff)
    }

    private static func writeU64LE(_ v: UInt64, into data: inout Data, at offset: Int) {
        for i in 0..<8 {
            data[offset + i] = UInt8((v >> (8 * i)) & 0xff)
        }
    }
}
