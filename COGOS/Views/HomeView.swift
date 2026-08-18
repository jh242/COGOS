import SwiftUI

struct HomeView: View {
    @EnvironmentObject var bluetooth: BluetoothManager
    @EnvironmentObject var session: EvenAISession

    private let tileColumns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                heroPanel

                if shouldShowPairedGlasses {
                    discoveryPanel
                }

                if bluetooth.isConnected {
                    statusGrid
                    currentSessionPanel
                }

                gestureGuidePanel
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 32)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Home")
    }

    private var heroPanel: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top) {
                Image(systemName: connectionIcon)
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(connectionTint)
                    .frame(width: 68, height: 68)
                    .background(.background.opacity(0.7), in: Circle())

                Spacer()

                StatusPill(title: connectionPillTitle, color: connectionTint)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("COGOS")
                    .font(.largeTitle.weight(.bold))
                Text(connectionDescription)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            primaryHeroAction
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [connectionTint.opacity(0.18), Color(.secondarySystemGroupedBackground)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 32, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06))
        )
    }

    @ViewBuilder
    private var primaryHeroAction: some View {
        switch bluetooth.connectionState {
        case .disconnected:
            Button {
                bluetooth.startScan()
            } label: {
                Label("Scan for Glasses", systemImage: "dot.radiowaves.left.and.right")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        case .scanning:
            HStack(spacing: 12) {
                Label("Scanning…", systemImage: "dot.radiowaves.left.and.right")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Stop") { bluetooth.stopScan() }
                    .buttonStyle(.bordered)
            }
        case .connecting:
            HStack(spacing: 12) {
                ProgressView()
                Text("Connecting both arms…")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .connected:
            Button(role: .destructive) {
                bluetooth.disconnect()
            } label: {
                Label("Disconnect Glasses", systemImage: "xmark.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
    }

    private var discoveryPanel: some View {
        HomeSection(
            title: "Available Glasses",
            subtitle: bluetooth.pairedDevices.isEmpty ? "COGOS is looking for a matched left and right arm." : "Choose a pair to connect.",
            systemImage: "antenna.radiowaves.left.and.right"
        ) {
            if bluetooth.pairedDevices.isEmpty {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Searching nearby…")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            } else {
                VStack(spacing: 8) {
                    ForEach(bluetooth.pairedDevices) { glasses in
                        Button {
                            bluetooth.connectToGlasses(deviceName: "Pair_\(glasses.channelNumber)")
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "eyeglasses")
                                    .font(.title3)
                                    .foregroundStyle(.tint)
                                    .frame(width: 40, height: 40)
                                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                                VStack(alignment: .leading, spacing: 3) {
                                    Text("G1 Pair \(glasses.channelNumber)")
                                        .font(.headline)
                                        .foregroundStyle(.primary)
                                    Text("Ready to connect")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(12)
                            .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Connect to G1 pair \(glasses.channelNumber)")
                    }
                }
            }
        }
    }

    private var statusGrid: some View {
        LazyVGrid(columns: tileColumns, alignment: .leading, spacing: 12) {
            MetricTile(
                title: "Connection",
                value: "Ready",
                systemImage: "checkmark.circle.fill",
                color: .green
            )
            MetricTile(
                title: "Assistant",
                value: session.isRunning ? "Listening" : "Idle",
                systemImage: session.isRunning ? "waveform" : "sparkles",
                color: session.isRunning ? .green : .blue
            )
            MetricTile(
                title: "Left Arm",
                value: batteryValue(bluetooth.battery.leftPercent, charging: bluetooth.battery.leftCharging),
                systemImage: bluetooth.battery.leftCharging ? "battery.100percent.bolt" : "battery.75percent",
                color: .mint
            )
            MetricTile(
                title: "Right Arm",
                value: batteryValue(bluetooth.battery.rightPercent, charging: bluetooth.battery.rightCharging),
                systemImage: bluetooth.battery.rightCharging ? "battery.100percent.bolt" : "battery.75percent",
                color: .mint
            )
        }
    }

    private var currentSessionPanel: some View {
        HomeSection(
            title: "On Glasses",
            subtitle: "The latest prompt or response sent to your display.",
            systemImage: "text.bubble"
        ) {
            if session.isSyncing {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Receiving response…")
                        .font(.headline)
                    Spacer()
                }
                .padding(.vertical, 8)
            }

            Text(session.dynamicText)
                .font(.body)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private var gestureGuidePanel: some View {
        HomeSection(title: "Gesture Guide", subtitle: "Use the glasses without opening your phone.", systemImage: "hand.tap") {
            VStack(spacing: 14) {
                InstructionRow(systemImage: "hand.point.up.left.fill", title: "Hold", detail: "Ask COGOS a question from the left TouchBar.")
                InstructionRow(systemImage: "pause.circle.fill", title: "Pause", detail: "COGOS sends after a short silence, or when you release.")
                InstructionRow(systemImage: "arrow.up.and.down.text.horizontal", title: "Tap", detail: "Scroll longer responses on the glasses display.")
            }
        }
    }

    private var shouldShowPairedGlasses: Bool {
        if case .disconnected = bluetooth.connectionState { return true }
        if case .scanning = bluetooth.connectionState { return true }
        return false
    }

    private var connectionDescription: String {
        switch bluetooth.connectionState {
        case .disconnected:
            return "Connect your G1 glasses to start using the COGOS assistant."
        case .scanning:
            return "Keep your glasses nearby while COGOS finds the left and right arms."
        case .connecting:
            return "Setting up both arms and preparing the display."
        case .connected(let name):
            return "\(cleanPairName(name)) is ready. Hold the left TouchBar to ask a question."
        }
    }

    private var connectionPillTitle: String {
        switch bluetooth.connectionState {
        case .disconnected: return "Offline"
        case .scanning: return "Scanning"
        case .connecting: return "Connecting"
        case .connected: return "Ready"
        }
    }

    private var connectionIcon: String {
        switch bluetooth.connectionState {
        case .disconnected: return "eyeglasses"
        case .scanning: return "dot.radiowaves.left.and.right"
        case .connecting: return "arrow.triangle.2.circlepath"
        case .connected: return "checkmark.circle.fill"
        }
    }

    private var connectionTint: Color {
        switch bluetooth.connectionState {
        case .connected: return .green
        case .connecting, .scanning: return .orange
        case .disconnected: return .blue
        }
    }

    private func batteryValue(_ percent: Int?, charging: Bool) -> String {
        guard let percent else { return "—" }
        return charging ? "\(percent)% ⚡" : "\(percent)%"
    }

    private func cleanPairName(_ name: String) -> String {
        name.replacingOccurrences(of: "Pair_", with: "G1 Pair ")
    }
}

private struct HomeSection<Content: View>: View {
    let title: String
    let subtitle: String?
    let systemImage: String
    let content: Content

    init(title: String, subtitle: String? = nil, systemImage: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: systemImage)
                    .font(.headline)
                    .foregroundStyle(.tint)
                    .frame(width: 32, height: 32)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                    if let subtitle {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

private struct StatusPill: View {
    let title: String
    let color: Color

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .textCase(.uppercase)
            .tracking(0.4)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .foregroundStyle(color)
            .background(color.opacity(0.14), in: Capsule())
    }
}

private struct MetricTile: View {
    let title: String
    let value: String
    let systemImage: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(color)
                .frame(width: 36, height: 36)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

private struct InstructionRow: View {
    let systemImage: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(.green)
                .frame(width: 28, height: 28)
                .background(Color.green.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
    }
}
