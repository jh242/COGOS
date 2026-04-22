import Foundation

/// Packet builders for the `0x06 DASHBOARD_SET` command family.
/// Byte layouts ported from Gadgetbridge `G1Communications.java`.
/// See `docs/G1_PROTOCOL_REFERENCE.md` for the pinned wire format.
enum DashboardProto {

    /// Max packet size observed by firmware (header + body).
    private static let maxPacketSize = 180

    // MARK: - 0x06 0x01 TIME_AND_WEATHER

    /// Fixed 22-byte packet (matches the 2026-04-17 Even-app sniff — Gadgetbridge
    /// documents 21, but the live capture shows 22 with a trailing `0x00`).
    /// `seq` is caller-assigned (wraps every 256).
    static func timeAndWeatherPacket(now: Date, weather: WeatherInfo, seq: UInt8) -> Data {
        // Firmware renders the epoch as wall-clock in the device's own frame,
        // so we ship local time by folding the current UTC offset into the
        // epoch before encoding (NY in EDT otherwise shows up ~4h ahead).
        let tzOffsetMs = Double(TimeZone.current.secondsFromGMT(for: now)) * 1000
        let ms = UInt64(now.timeIntervalSince1970 * 1000 + tzOffsetMs)
        let secs = UInt32(ms / 1000)

        var pack = Data(count: 22)
        pack[0] = 0x06        // DASHBOARD_SET
        pack[1] = 0x16        // total length = 22
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
        pack[21] = 0x00       // trailing pad — observed in Even-app capture
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

    /// Assemble the pre-chunking calendar body. Layout depends on whether
    /// there are events: the 2026-04-17 Even-app sniff pinned the empty body
    /// as literal `00 00 02` — not a TLV form. Non-empty layout is still
    /// unconfirmed from the sniff; we follow Gadgetbridge's `01 03 03` +
    /// event_count + TLV entries until proven otherwise.
    static func calendarBody(_ events: [CalendarEvent]) -> Data {
        let clamped = Array(events.prefix(8))
        if clamped.isEmpty {
            return Data([0x00, 0x00, 0x02])
        }
        var body = Data()
        body.append(contentsOf: [0x01, 0x03, 0x03])
        body.append(UInt8(clamped.count))
        for ev in clamped {
            appendTLV(type: 0x01, string: ev.title, into: &body)
            appendTLV(type: 0x02, string: ev.timeString, into: &body)
            appendTLV(type: 0x03, string: ev.location, into: &body)
        }
        return body
    }

    // MARK: - Helpers

    private static func appendTLV(type: UInt8, string: String, into body: inout Data) {
        let utf8 = string.utf8Truncated(max: 0xFF)
        body.append(type)
        body.append(UInt8(utf8.count))
        body.append(utf8)
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
