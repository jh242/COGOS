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
        let glance = GlanceService(proto: proto, location: location, session: session)
        let gestureRouter = GestureRouter(session: session, bluetooth: bluetooth)

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
            glance.startTimer()
            Task {
                await whitelist.pushToGlasses(proto: proto)
                await proto.setHeadUpAngle(settings.headUpAngle)
                await proto.setWearDetection(enabled: true)
                await proto.queryBatteryAndFirmware()
                _ = await proto.setDashboardMode(.dual, paneMode: .quickNotes)
            }
        case .disconnected, .scanning, .connecting:
            glance.stopTimer()
        }
    }

    /// Exit AI session (bound to double-tap from gesture router).
    func exitAll() {
        if session.isRunning {
            Task { await session.stopEvenAIByOS() }
        }
    }
}
