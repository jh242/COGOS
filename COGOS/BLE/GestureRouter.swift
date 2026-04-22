import Foundation

/// Routes `0xF5 0xXX` gesture and state events from the glasses.
/// Event IDs follow Gadgetbridge's `G1Constants.EventId` — see
/// `docs/G1_PROTOCOL_REFERENCE.md`.
@MainActor
final class GestureRouter {
    private let session: EvenAISession
    private weak var bluetooth: BluetoothManager?

    init(session: EvenAISession, bluetooth: BluetoothManager) {
        self.session = session
        self.bluetooth = bluetooth
    }

    func handle(lr: String, data: Data) {
        guard data.count >= 2, data[0] == 0xF5 else { return }
        let notifyIndex = data[1]
        let payload = data.count > 2 ? data[2] : 0

        switch notifyIndex {
        case 0x00: // ACTION_DOUBLE_TAP_FOR_EXIT (legacy)
            break
        case 0x01:
            // ACTION_SINGLE_TAP — firmware paginates 0x54 text natively
            // (L = prev page, R = next page). No app-side action needed.
            break
        case 0x02, 0x03:
            // ACTION_HEAD_UP / ACTION_HEAD_DOWN — firmware renders the
            // dashboard on head-up from the latched state we refresh each
            // tick. No app-side action needed.
            break
        case 0x04, 0x05:
            // ACTION_SILENT_MODE_{ENABLED,DISABLED} — firmware telemetry,
            // not a user action we want to react to.
            break
        case 0x06: // STATE_WORN
            break
        case 0x07, 0x08: // STATE_NOT_WORN_NO_CASE / STATE_IN_CASE_LID_OPEN
            if session.isRunning { session.exitAll() }
        case 0x0B: // STATE_IN_CASE_LID_CLOSED
            break
        case 0x09: // STATE_CHARGING, payload 00/01
            updateBattery { state in
                if lr == "L" { state.leftCharging = payload == 0x01 }
                else { state.rightCharging = payload == 0x01 }
            }
        case 0x0A: // INFO_BATTERY_LEVEL, payload 0..100
            let pct = Int(min(payload, 100))
            updateBattery { state in
                if lr == "L" { state.leftPercent = pct }
                else { state.rightPercent = pct }
            }
        case 0x0E: // STATE_CASE_CHARGING
            updateBattery { $0.caseCharging = payload == 0x01 }
        case 0x0F: // INFO_CASE_BATTERY_LEVEL
            updateBattery { $0.casePercent = Int(min(payload, 100)) }
        case 0x11: // ACTION_BINDING_SUCCESS
            break
        case 0x17: // ACTION_LONG_PRESS_HELD — start Even AI
            Task { await session.toStartEvenAIByOS() }
        case 0x18: // ACTION_LONG_PRESS_RELEASED
            Task { await session.recordOverByOS() }
        case 0x1E, 0x1F:
            // ACTION_DOUBLE_TAP_DASHBOARD_{SHOW,CLOSE} — firmware dashboard
            // gesture; we render our own HUD, so ignore.
            break
        case 0x20: // ACTION_DOUBLE_TAP
            if session.isRunning {
                session.exitAll()
            }
        default:
            print("Unhandled 0xF5 event: 0x\(String(format: "%02x", notifyIndex))")
        }
    }

    private func updateBattery(_ mutate: (inout BluetoothManager.BatteryState) -> Void) {
        guard let bt = bluetooth else { return }
        var state = bt.battery
        mutate(&state)
        if state != bt.battery { bt.battery = state }
    }
}
