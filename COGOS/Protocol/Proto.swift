import Foundation

/// High-level command helpers for the G1 glasses protocol.
/// Ports `lib/services/proto.dart`.
actor Proto {
    private let queue: BleRequestQueue
    private var textSeq: UInt8 = 0
    private var dashboardSeq: UInt8 = 0

    init(queue: BleRequestQueue) {
        self.queue = queue
    }

    // MARK: - Microphone

    /// Enable glasses microphone. Returns (startMs, success).
    @discardableResult
    func micOn(lr: String = "R") async -> (Int, Bool) {
        let begin = Int(Date().timeIntervalSince1970 * 1000)
        let data = Data([0x0E, 0x01])
        let ret = await queue.request(data, lr: lr)
        let end = Int(Date().timeIntervalSince1970 * 1000)
        let startMic = begin + ((end - begin) / 2)
        let ok = (ret?.data.count ?? 0) >= 2 && ret?.data[1] == 0xc9
        return (startMic, ok)
    }

    @discardableResult
    func micOff(lr: String = "R") async -> Bool {
        let data = Data([0x0E, 0x00])
        let ret = await queue.request(data, lr: lr)
        return (ret?.data.count ?? 0) >= 2 && ret?.data[1] == 0xc9
    }

    // MARK: - Even AI data transport (0x54 streaming)

    /// Emit a 0x54 prepare packet — sent once per reply, before any text
    /// updates. Reserves + returns the seq used for this message's
    /// subsequent text packets.
    @discardableResult
    func sendEvenAITextPrepare(timeoutMs: Int = 1500) async -> UInt8 {
        let seq = textSeq
        textSeq = textSeq &+ 1
        let pack = EvenAIText54.preparePacket(seq: seq)
        _ = await queue.request(pack, lr: "L", timeoutMs: timeoutMs)
        _ = await queue.request(pack, lr: "R", timeoutMs: timeoutMs)
        return seq
    }

    /// Send a cumulative text update. `text` should contain the full answer
    /// assembled so far — firmware replaces its buffer and paginates.
    /// Consumes one seq; chunks share it.
    @discardableResult
    func sendEvenAIText(_ text: String, timeoutMs: Int = 2000) async -> Bool {
        await sendEvenAIText54(text, status: .streaming, timeoutMs: timeoutMs)
    }

    /// Final re-send of the full answer with the "complete" status byte
    /// (0x64). Without this, firmware stays in streaming mode and single-tap
    /// page scroll is a no-op. See the `HeldLeftBar_AI_MultiLineWithScroll`
    /// capture: byte 11 flips `0xFF → 0x64` exactly once, after the last
    /// streaming chunk, to hand the text off to the scrollable viewer.
    @discardableResult
    func sendEvenAITextComplete(_ text: String, timeoutMs: Int = 2000) async -> Bool {
        await sendEvenAIText54(text, status: .complete, timeoutMs: timeoutMs)
    }

    private func sendEvenAIText54(_ text: String, status: EvenAIText54.Status, timeoutMs: Int) async -> Bool {
        let seq = textSeq
        textSeq = textSeq &+ 1
        let packets = EvenAIText54.textPackets(seq: seq, text: text, status: status)
        for pack in packets {
            if await queue.request(pack, lr: "L", timeoutMs: timeoutMs) == nil { return false }
            if await queue.request(pack, lr: "R", timeoutMs: timeoutMs) == nil { return false }
        }
        return true
    }

    // MARK: - Settings / control

    /// Head-up angle threshold (0..60 degrees). Fires 0xF5 0x02 above threshold.
    func setHeadUpAngle(_ angle: Int) async {
        let clamped = UInt8(max(0, min(60, angle)))
        let data = Data([0x0B, clamped, 0x01])
        _ = await queue.sendBoth(data)
    }

    /// Display brightness. Level 0..0x2A (0..42); `auto` toggles firmware
    /// ambient-light tracking. See G1 reference `0x01 BRIGHTNESS_SET`.
    func setBrightness(level: Int, auto: Bool) async {
        let clamped = UInt8(max(0, min(0x2A, level)))
        let data = Data([0x01, clamped, auto ? 0x01 : 0x00])
        _ = await queue.sendBoth(data)
    }

    /// Enable/disable on-device wear detection. Prerequisite for 0xF5 0x06/0x07.
    func setWearDetection(enabled: Bool) async {
        let data = Data([0x27, enabled ? 0x01 : 0x00])
        _ = await queue.sendBoth(data)
    }

    /// Query battery + firmware. Each arm replies with its own 0x2C payload.
    func queryBatteryAndFirmware() async {
        let data = Data([0x2C, 0x01])
        _ = await queue.sendBoth(data)
    }

    // MARK: - Firmware dashboard (0x06 + 0x1E + 0x22 0x05 families)
    //
    // Note on ACKs: unlike most commands, firmware does NOT respond to `0x06`
    // (dashboard) or `0x1E` (quick notes) with the `<cmd> 0xC9` convention —
    // it echoes the packet header back instead (e.g. `06 16 00 <seq> …` for a
    // 22-byte time+weather write). We only check for a non-nil response and
    // let sendBoth / per-arm loops drive both arms unconditionally.

    @discardableResult
    func setDashboardTimeAndWeather(now: Date = Date(), weather: WeatherInfo) async -> Bool {
        let seq = dashboardSeq; dashboardSeq = dashboardSeq &+ 1
        let pack = DashboardProto.timeAndWeatherPacket(now: now, weather: weather, seq: seq)
        return await queue.sendBoth(pack)
    }

    /// Configure dashboard layout + secondary pane. Secondary pane byte is
    /// always written — pass `.empty` when `mode` is not `.dual`.
    @discardableResult
    func setDashboardMode(_ mode: DashboardMode, paneMode: DashboardPaneMode) async -> Bool {
        let seq = dashboardSeq; dashboardSeq = dashboardSeq &+ 1
        let pack = DashboardProto.modePacket(mode, paneMode: paneMode, seq: seq)
        return await queue.sendBoth(pack)
    }

    /// Push up to 8 calendar events to the firmware calendar pane. Firmware
    /// renders `timeString` verbatim — it does not parse timestamps.
    @discardableResult
    func setDashboardCalendar(_ events: [CalendarEvent]) async -> Bool {
        let (packets, nextSeq) = DashboardProto.calendarPackets(events, startingSeq: dashboardSeq)
        dashboardSeq = nextSeq
        return await sendSequentialToBoth(packets, timeoutMs: 1000)
    }

    /// Write all 4 Quick Notes slots (`0x1E 0x03 NOTE_TEXT_EDIT`). Firmware
    /// protocol is replace-all-4-slots — every update emits 4 packets, one
    /// per slot. Entries past index 3 are ignored; missing entries use the
    /// empty-slot template.
    @discardableResult
    func setQuickNoteSlots(_ slots: [QuickNote?]) async -> Bool {
        let (packets, nextSeq) = QuickNoteProto.setSlotsPackets(slots, startingSeq: dashboardSeq)
        dashboardSeq = nextSeq
        return await sendSequentialToBoth(packets, timeoutMs: 1000)
    }

    /// Commit the current dashboard push. Even app sends this to the right
    /// arm after every 0x06 / 0x1E cycle; without it the glasses accept the
    /// packets but don't redraw. See G1 reference `0x22 0x05`.
    @discardableResult
    func commitDashboard() async -> Bool {
        let seq = dashboardSeq; dashboardSeq = dashboardSeq &+ 1
        let pack = Data([0x22, 0x05, 0x00, seq, 0x01])
        return await queue.request(pack, lr: "R", timeoutMs: 1500) != nil
    }

    /// Send every packet to L then R, accepting any non-nil response (the
    /// 0x06 / 0x1E families echo the header rather than sending 0xC9).
    private func sendSequentialToBoth(_ packets: [Data], timeoutMs: Int) async -> Bool {
        for arm in ["L", "R"] {
            for pack in packets {
                if await queue.request(pack, lr: arm, timeoutMs: timeoutMs) == nil {
                    return false
                }
            }
        }
        return true
    }

    /// Exit to dashboard.
    @discardableResult
    func exit() async -> Bool {
        let data = Data([0x18])
        guard let lRet = await queue.request(data, lr: "L", timeoutMs: 1500) else { return false }
        guard lRet.data.count >= 2, lRet.data[1] == 0xc9 else { return false }
        guard let rRet = await queue.request(data, lr: "R", timeoutMs: 1500) else { return false }
        return rRet.data.count >= 2 && rRet.data[1] == 0xc9
    }

    // MARK: - Probe

    func probeSend(_ cmd: UInt8) async -> String {
        let data = Data([cmd])
        let lRet = await queue.request(data, lr: "L", timeoutMs: 2000)
        let rRet = await queue.request(data, lr: "R", timeoutMs: 2000)
        return "L: \(lRet.flatMap { Self.hex($0.data) } ?? "timeout")\nR: \(rRet.flatMap { Self.hex($0.data) } ?? "timeout")"
    }

    func probeRaw(_ bytes: [UInt8]) async -> String {
        let data = Data(bytes)
        let lRet = await queue.request(data, lr: "L", timeoutMs: 2000)
        let rRet = await queue.request(data, lr: "R", timeoutMs: 2000)
        return "L: \(lRet.flatMap { Self.hex($0.data) } ?? "timeout")\nR: \(rRet.flatMap { Self.hex($0.data) } ?? "timeout")"
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    // MARK: - Whitelist / Notifications

    func sendNewAppWhiteListJson(_ json: String) async {
        let payload = Data(json.utf8)
        let packets = Self.getPackList(cmd: 0x04, data: payload, count: 180)
        for _ in 0..<3 {
            let ok = await queue.requestList(packets, lr: "L", timeoutMs: 300)
            if ok { return }
        }
    }

    func sendNotify(appData: [String: Any], notifyId: UInt8, retry: Int = 6) async {
        let dict = ["ncs_notification": appData]
        guard let json = try? JSONSerialization.data(withJSONObject: dict, options: []) else { return }
        let packets = Self.getNotifyPackList(cmd: 0x4B, msgId: notifyId, data: json)
        for _ in 0..<retry {
            let ok = await queue.requestList(packets, lr: "L", timeoutMs: 1000)
            if ok { return }
        }
    }

    // MARK: - Packet assembly helpers

    private static func getPackList(cmd: UInt8, data: Data, count: Int = 20) -> [Data] {
        let realCount = count - 3
        var send: [Data] = []
        var maxSeq = data.count / realCount
        if data.count % realCount > 0 { maxSeq += 1 }
        for seq in 0..<maxSeq {
            let start = seq * realCount
            var end = start + realCount
            if end > data.count { end = data.count }
            var pack = Data([cmd, UInt8(maxSeq), UInt8(seq)])
            pack.append(data.subdata(in: start..<end))
            send.append(pack)
        }
        return send
    }

    private static func getNotifyPackList(cmd: UInt8, msgId: UInt8, data: Data) -> [Data] {
        var send: [Data] = []
        var maxSeq = data.count / 176
        if data.count % 176 > 0 { maxSeq += 1 }
        for seq in 0..<maxSeq {
            let start = seq * 176
            var end = start + 176
            if end > data.count { end = data.count }
            var pack = Data([cmd, msgId, UInt8(maxSeq), UInt8(seq)])
            pack.append(data.subdata(in: start..<end))
            send.append(pack)
        }
        return send
    }

    /// Expose queue so higher-level modules can issue direct requests.
    func getQueue() -> BleRequestQueue { queue }
}
