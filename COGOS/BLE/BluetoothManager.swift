import Foundation
import CoreBluetooth
import Combine

/// Dual-peripheral BLE manager for Even Realities G1 glasses.
final class BluetoothManager: NSObject, ObservableObject {

    enum ConnectionState: Equatable {
        case disconnected
        case scanning
        case connecting
        case connected(name: String)
    }

    struct PairedGlasses: Identifiable, Hashable {
        var id: String { channelNumber }
        let channelNumber: String
        let leftDeviceName: String
        let rightDeviceName: String
    }

    struct ReceivedPacket {
        let lr: String
        let data: Data
        let peripheralId: String
    }

    struct BatteryState: Equatable {
        var leftPercent: Int?
        var rightPercent: Int?
        var casePercent: Int?
        var leftCharging: Bool = false
        var rightCharging: Bool = false
        var caseCharging: Bool = false
    }

    // MARK: - Published state

    @Published private(set) var connectionState: ConnectionState = .disconnected
    @Published private(set) var pairedDevices: [PairedGlasses] = []
    @Published private(set) var status: String = "Not connected"
    @Published var battery: BatteryState = BatteryState()

    /// Incoming non-audio packets. Consumed by `BleRequestQueue` and gesture router.
    let packets = PassthroughSubject<ReceivedPacket, Never>()

    /// Event log stream (hex dumps of all packets). Consumed by `BleProbeView`.
    let eventLog = PassthroughSubject<String, Never>()

    var isConnected: Bool {
        if case .connected = connectionState { return true }
        return false
    }

    // MARK: - Internal state

    private var centralManager: CBCentralManager!
    private let uartService = CBUUID(string: ServiceIdentifiers.uartServiceUUIDString)
    private let uartTX = CBUUID(string: ServiceIdentifiers.uartTXCharacteristicUUIDString)
    private let uartRX = CBUUID(string: ServiceIdentifiers.uartRXCharacteristicUUIDString)

    // Discovery pool: channelNumber → (L?, R?)
    private var discoveredPairs: [String: (CBPeripheral?, CBPeripheral?)] = [:]

    // Currently paired/connecting device
    private var currentConnectingDeviceName: String?
    private var leftPeripheral: CBPeripheral?
    private var rightPeripheral: CBPeripheral?
    private var leftUUIDStr: String?
    private var rightUUIDStr: String?
    private var leftWChar: CBCharacteristic?
    private var rightWChar: CBCharacteristic?
    private var leftRChar: CBCharacteristic?
    private var rightRChar: CBCharacteristic?

    // Pending auto-reconnect if bluetooth isn't on yet
    private var pendingReconnect: (() -> Void)?

    /// Weakly held speech recognizer so we can route PCM frames directly.
    weak var speechRecognizer: SpeechStreamRecognizer?

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }

    // MARK: - Public API

    func startScan() {
        guard centralManager.state == .poweredOn else {
            print("BluetoothManager: cannot scan; BT state = \(centralManager.state.rawValue)")
            return
        }
        connectionState = .scanning
        status = "Scanning..."
        centralManager.scanForPeripherals(withServices: nil, options: nil)
    }

    func stopScan() {
        centralManager.stopScan()
        if case .scanning = connectionState { connectionState = .disconnected; status = "Not connected" }
    }

    func connectToGlasses(deviceName: String) {
        centralManager.stopScan()
        guard let pair = discoveredPairs[deviceName],
              let left = pair.0, let right = pair.1 else {
            print("BluetoothManager: device not found: \(deviceName)")
            return
        }
        connectionState = .connecting
        status = "Connecting..."
        currentConnectingDeviceName = deviceName
        centralManager.connect(left, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true])
        centralManager.connect(right, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true])
    }

    func disconnect() {
        if let l = leftPeripheral { centralManager.cancelPeripheralConnection(l) }
        if let r = rightPeripheral { centralManager.cancelPeripheralConnection(r) }
    }

    func tryReconnectLastDevice() async -> Bool {
        let defaults = UserDefaults.standard
        guard let deviceName = defaults.string(forKey: "lastDeviceName"),
              let leftUUIDStr = defaults.string(forKey: "lastLeftUUID"),
              let rightUUIDStr = defaults.string(forKey: "lastRightUUID"),
              let leftUUID = UUID(uuidString: leftUUIDStr),
              let rightUUID = UUID(uuidString: rightUUIDStr) else {
            return false
        }
        if centralManager.state != .poweredOn {
            return await withCheckedContinuation { cont in
                pendingReconnect = { [weak self] in
                    guard let self = self else { cont.resume(returning: false); return }
                    let ok = self.performReconnect(deviceName: deviceName, leftUUID: leftUUID, rightUUID: rightUUID,
                                                   leftUUIDStr: leftUUIDStr, rightUUIDStr: rightUUIDStr)
                    cont.resume(returning: ok)
                }
            }
        }
        return performReconnect(deviceName: deviceName, leftUUID: leftUUID, rightUUID: rightUUID,
                                leftUUIDStr: leftUUIDStr, rightUUIDStr: rightUUIDStr)
    }

    @discardableResult
    private func performReconnect(deviceName: String, leftUUID: UUID, rightUUID: UUID,
                                  leftUUIDStr: String, rightUUIDStr: String) -> Bool {
        let peripherals = centralManager.retrievePeripherals(withIdentifiers: [leftUUID, rightUUID])
        var foundLeft: CBPeripheral?
        var foundRight: CBPeripheral?
        for p in peripherals {
            if p.identifier.uuidString == leftUUIDStr { foundLeft = p }
            if p.identifier.uuidString == rightUUIDStr { foundRight = p }
        }
        guard let left = foundLeft, let right = foundRight else { return false }
        discoveredPairs[deviceName] = (left, right)
        currentConnectingDeviceName = deviceName
        connectionState = .connecting
        status = "Connecting..."
        centralManager.connect(left, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true])
        centralManager.connect(right, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true])
        return true
    }

    // MARK: - Writing

    /// Send raw bytes to L or R (or both). `lr` = "L", "R", or nil for both.
    /// Returns true if the write was dispatched.
    @discardableResult
    func send(_ bytes: Data, lr: String?) -> Bool {
        if lr == "L" {
            guard let ch = leftWChar, let p = leftPeripheral else { return false }
            p.writeValue(bytes, for: ch, type: .withoutResponse)
            return true
        }
        if lr == "R" {
            guard let ch = rightWChar, let p = rightPeripheral else { return false }
            p.writeValue(bytes, for: ch, type: .withoutResponse)
            return true
        }
        if let ch = leftWChar, let p = leftPeripheral {
            p.writeValue(bytes, for: ch, type: .withoutResponse)
        }
        if let ch = rightWChar, let p = rightPeripheral {
            p.writeValue(bytes, for: ch, type: .withoutResponse)
        }
        return true
    }

    // MARK: - Helpers

    private func saveLastConnected(deviceName: String, leftUUID: String, rightUUID: String) {
        let d = UserDefaults.standard
        d.set(deviceName, forKey: "lastDeviceName")
        d.set(leftUUID, forKey: "lastLeftUUID")
        d.set(rightUUID, forKey: "lastRightUUID")
    }

    private func publishPairedDevices() {
        let arr = discoveredPairs.compactMap { (k, v) -> PairedGlasses? in
            guard let l = v.0, let r = v.1 else { return nil }
            return PairedGlasses(channelNumber: k.replacingOccurrences(of: "Pair_", with: ""),
                                 leftDeviceName: l.name ?? "",
                                 rightDeviceName: r.name ?? "")
        }
        DispatchQueue.main.async { self.pairedDevices = arr }
    }
}

// MARK: - CBCentralManagerDelegate

extension BluetoothManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn, let pending = pendingReconnect {
            pendingReconnect = nil
            pending()
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard let name = peripheral.name else { return }
        let components = name.components(separatedBy: "_")
        guard components.count > 1 else { return }
        let channelNumber = components[1]
        let key = "Pair_\(channelNumber)"

        var entry = discoveredPairs[key] ?? (nil, nil)
        if name.contains("_L_") { entry.0 = peripheral }
        else if name.contains("_R_") { entry.1 = peripheral }
        discoveredPairs[key] = entry

        if entry.0 != nil && entry.1 != nil {
            publishPairedDevices()
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard let deviceName = currentConnectingDeviceName,
              let pair = discoveredPairs[deviceName] else { return }

        if pair.0 === peripheral {
            leftPeripheral = peripheral
            peripheral.delegate = self
            peripheral.discoverServices([uartService])
            leftUUIDStr = peripheral.identifier.uuidString
        } else if pair.1 === peripheral {
            rightPeripheral = peripheral
            peripheral.delegate = self
            peripheral.discoverServices([uartService])
            rightUUIDStr = peripheral.identifier.uuidString
        }

        if leftPeripheral != nil, rightPeripheral != nil {
            DispatchQueue.main.async {
                self.connectionState = .connected(name: deviceName)
                self.status = "Connected: \n\(self.leftPeripheral?.name ?? "")\n\(self.rightPeripheral?.name ?? "")"
            }
            saveLastConnected(deviceName: deviceName,
                              leftUUID: leftPeripheral!.identifier.uuidString,
                              rightUUID: rightPeripheral!.identifier.uuidString)
            currentConnectingDeviceName = nil
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        // Try to reconnect
        DispatchQueue.main.async {
            self.connectionState = .disconnected
            self.status = "Not connected"
        }
        central.connect(peripheral, options: nil)
    }
}

// MARK: - CBPeripheralDelegate

extension BluetoothManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        for service in services where service.uuid == uartService {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristics = service.characteristics else { return }
        guard service.uuid == uartService else { return }

        let isLeft = peripheral.identifier.uuidString == leftUUIDStr
        for c in characteristics {
            if c.uuid == uartRX {
                if isLeft { leftRChar = c } else { rightRChar = c }
            } else if c.uuid == uartTX {
                if isLeft { leftWChar = c } else { rightWChar = c }
            }
        }

        if isLeft, let r = leftRChar, leftWChar != nil {
            leftPeripheral?.setNotifyValue(true, for: r)
            send(Data([0x4d, 0x01]), lr: "L")
        } else if !isLeft, let r = rightRChar, rightWChar != nil {
            rightPeripheral?.setNotifyValue(true, for: r)
            send(Data([0x4d, 0x01]), lr: "R")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value, !data.isEmpty else { return }
        let cmd = AG_BLE_REQ(rawValue: data[0])

        switch cmd {
        case .BLE_REQ_TRANSFER_MIC_DATA:
            // Strip 2-byte header, LC3-decode, and forward PCM to recognizer.
            guard data.count > 2 else { return }
            let effective = data.subdata(in: 2..<data.count)
            let converter = PcmConverter()
            if let pcm = converter.decode(effective) as Data? {
                speechRecognizer?.appendPCMData(pcm)
            }
        default:
            let isLeft = peripheral.identifier.uuidString == leftUUIDStr
            let legStr = isLeft ? "L" : "R"
            let pkt = ReceivedPacket(lr: legStr, data: data, peripheralId: peripheral.identifier.uuidString)
            packets.send(pkt)
            if data[0] != 0xf1 {
                let hex = data.map { String(format: "%02x", $0) }.joined(separator: " ")
                let ts = Self.timestamp()
                eventLog.send("[\(ts)] ← \(legStr): \(hex)")
            }
        }
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: Date())
    }
}
