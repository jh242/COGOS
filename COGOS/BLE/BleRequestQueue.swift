import Foundation

/// BLE request/response queue with timeout and retry support.
/// Ports `BleManager.request`, `sendBoth`, `requestRetry`, `requestList`.
///
/// Requests are keyed by `"<lr><firstByte>"` (e.g. "L25" for heartbeat on L).
/// When a matching response arrives, the waiting continuation is resumed.
actor BleRequestQueue {
    private let bluetooth: BluetoothManager
    private var waiters: [String: CheckedContinuation<BluetoothManager.ReceivedPacket?, Never>] = [:]
    private var nextReceive: CheckedContinuation<BluetoothManager.ReceivedPacket?, Never>?

    init(bluetooth: BluetoothManager) {
        self.bluetooth = bluetooth
    }

    /// Called by the upstream packet stream (non-isolated entry point).
    nonisolated func deliver(packet: BluetoothManager.ReceivedPacket) {
        Task { await self._deliver(packet: packet) }
    }

    private func _deliver(packet: BluetoothManager.ReceivedPacket) {
        guard !packet.data.isEmpty else { return }
        let key = "\(packet.lr)\(String(format: "%02x", packet.data[0]))"
        if let cont = waiters.removeValue(forKey: key) {
            cont.resume(returning: packet)
        }
        if let cont = nextReceive {
            nextReceive = nil
            cont.resume(returning: packet)
        }
    }

    /// Send `data` and wait for a reply. Returns nil on timeout.
    func request(_ data: Data, lr: String, timeoutMs: Int = 1000, useNext: Bool = false) async -> BluetoothManager.ReceivedPacket? {
        let key = "\(lr)\(String(format: "%02x", data[0]))"

        // If a previous waiter exists for the same key, fail it immediately.
        if !useNext, let prev = waiters.removeValue(forKey: key) {
            prev.resume(returning: nil)
        }

        let result = await withCheckedContinuation { (cont: CheckedContinuation<BluetoothManager.ReceivedPacket?, Never>) in
            if useNext {
                // Replace any existing nextReceive
                nextReceive?.resume(returning: nil)
                nextReceive = cont
            } else {
                waiters[key] = cont
            }
            // Dispatch the write.
            bluetooth.send(data, lr: lr)

            // Timeout task
            if timeoutMs > 0 {
                Task { [key, useNext, timeoutMs] in
                    try? await Task.sleep(nanoseconds: UInt64(timeoutMs) * 1_000_000)
                    await self.timeoutFire(key: key, useNext: useNext)
                }
            }
        }
        return result
    }

    private func timeoutFire(key: String, useNext: Bool) {
        if useNext {
            if let cont = nextReceive {
                nextReceive = nil
                cont.resume(returning: nil)
            }
        } else if let cont = waiters.removeValue(forKey: key) {
            cont.resume(returning: nil)
        }
    }

    /// Retrying variant: returns nil on final timeout.
    func requestRetry(_ data: Data, lr: String, timeoutMs: Int = 200, retry: Int = 3) async -> BluetoothManager.ReceivedPacket? {
        for _ in 0...retry {
            if let ret = await request(data, lr: lr, timeoutMs: timeoutMs) {
                return ret
            }
        }
        return nil
    }

    /// Send to L then R and wait for responses from both. Returns true only
    /// if both arms reply (not nil).
    /// NOTE: the 0x06 (dashboard) and 0x1E (quick notes) command families do
    /// NOT use the standard `<cmd> 0xC9` ACK convention — firmware echoes the
    /// packet header back. So we only require non-nil responses; caller is
    /// responsible for interpreting response bytes if it needs to.
    func sendBoth(_ data: Data, timeoutMs: Int = 250, retry: Int = 0) async -> Bool {
        let lRes = await requestRetry(data, lr: "L", timeoutMs: timeoutMs, retry: retry)
        let rRes = await requestRetry(data, lr: "R", timeoutMs: timeoutMs, retry: retry)
        return lRes != nil && rRes != nil
    }

    /// Sequentially send a list of packets, expecting 0xC9 / 0xCB acks on each.
    /// When `lr` is nil, sends to L and R concurrently (keeping last packet)
    /// then sends the last packet via `sendBoth`.
    func requestList(_ packets: [Data], lr: String?, timeoutMs: Int = 350) async -> Bool {
        if let lr = lr {
            return await _requestList(packets, lr: lr, keepLast: false, timeoutMs: timeoutMs)
        } else {
            async let l = _requestList(packets, lr: "L", keepLast: true, timeoutMs: timeoutMs)
            async let r = _requestList(packets, lr: "R", keepLast: true, timeoutMs: timeoutMs)
            let (okL, okR) = await (l, r)
            guard okL, okR, let last = packets.last else { return false }
            return await sendBoth(last, timeoutMs: timeoutMs)
        }
    }

    private func _requestList(_ packets: [Data], lr: String, keepLast: Bool, timeoutMs: Int) async -> Bool {
        let len = keepLast ? packets.count - 1 : packets.count
        for i in 0..<len {
            guard let resp = await request(packets[i], lr: lr, timeoutMs: timeoutMs) else { return false }
            if resp.data.count < 2 { return false }
            let b = resp.data[1]
            if b != 0xc9 && b != 0xcB { return false }
        }
        return true
    }
}
