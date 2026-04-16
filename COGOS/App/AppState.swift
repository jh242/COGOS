import Foundation
import Combine

/// Top-level holder of long-lived app services.
@MainActor
final class AppState: ObservableObject {
    let bluetooth: BluetoothManager
    let requestQueue: BleRequestQueue
    let gestureRouter: GestureRouter
    let proto: Proto
    let session: EvenAISession
    let history: HistoryStore
    let settings: Settings
    let whitelist: NotificationWhitelist
    let glance: GlanceService
    let location: NativeLocation
    let speech: SpeechStreamRecognizer

    private var cancellables: Set<AnyCancellable> = []
    private var heartbeatTask: Task<Void, Never>?
    private var started = false

    init() {
        let settings = Settings()
        let history = HistoryStore()
        let bluetooth = BluetoothManager()
        let speech = SpeechStreamRecognizer()
        let location = NativeLocation()
        let whitelist = NotificationWhitelist()
        let requestQueue = BleRequestQueue(bluetooth: bluetooth)
        let proto = Proto(queue: requestQueue)
        let session = EvenAISession(proto: proto, speech: speech, settings: settings)
        let glance = GlanceService(proto: proto, location: location, session: session,
                                    requestQueue: requestQueue, bluetooth: bluetooth,
                                    settings: settings)
        let gestureRouter = GestureRouter(session: session, glance: glance, bluetooth: bluetooth)

        self.settings = settings
        self.history = history
        self.bluetooth = bluetooth
        self.speech = speech
        self.location = location
        self.whitelist = whitelist
        self.requestQueue = requestQueue
        self.proto = proto
        self.session = session
        self.glance = glance
        self.gestureRouter = gestureRouter

        session.historyStore = history
        bluetooth.speechRecognizer = speech
    }

    func start() {
        guard !started else { return }
        started = true

        // Route incoming non-audio packets into request queue + gesture router.
        bluetooth.packets
            .sink { [weak self] packet in
                guard let self = self else { return }
                if packet.data.first == 0xF5, packet.data.count >= 2 {
                    Task { @MainActor in
                        self.gestureRouter.handle(lr: packet.lr, data: packet.data)
                    }
                } else {
                    self.requestQueue.deliver(packet: packet)
                }
            }
            .store(in: &cancellables)

        // React to connection changes.
        bluetooth.$connectionState
            .sink { [weak self] state in
                Task { @MainActor in
                    self?.handleConnectionStateChange(state)
                }
            }
            .store(in: &cancellables)

        // Attempt auto-reconnect on launch.
        Task { await bluetooth.tryReconnectLastDevice() }
    }

    private func handleConnectionStateChange(_ state: BluetoothManager.ConnectionState) {
        switch state {
        case .connected:
            startHeartbeat()
            glance.startTimer()
            Task {
                await whitelist.pushToGlasses(proto: proto)
                await proto.setHeadUpAngle(settings.headUpAngle)
                await proto.setWearDetection(enabled: true)
                await proto.queryBatteryAndFirmware()
                if settings.useFirmwareDashboard {
                    // Phase 2: configure DUAL dashboard with the calendar
                    // pane we can populate. Quick Notes/News/Stocks panes
                    // remain blocked on the sniff session.
                    _ = await proto.setDashboardMode(.dual, paneMode: .calendar)
                }
            }
        case .disconnected, .scanning, .connecting:
            stopHeartbeat()
            glance.stopTimer()
        }
    }

    private func startHeartbeat() {
        stopHeartbeat()
        heartbeatTask = Task.detached { [weak self] in
            guard let self = self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 8 * 1_000_000_000)
                if Task.isCancelled { break }
                var ok = await self.proto.sendHeartBeat()
                if !ok { ok = await self.proto.sendHeartBeat() }
                _ = ok
            }
        }
    }

    private func stopHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    /// Exit AI + glance screens (bound to double-tap from gesture router).
    func exitAll() {
        glance.dismiss()
        if session.isRunning {
            Task { await session.stopEvenAIByOS() }
        }
    }
}
