import SwiftUI
import Combine

struct BleProbeView: View {
    @EnvironmentObject var bluetooth: BluetoothManager
    @EnvironmentObject var appState: AppState

    @State private var log: [String] = ["Listening for BLE events..."]
    @State private var sending = false
    @State private var cancellable: AnyCancellable?

    var body: some View {
        VStack(alignment: .leading) {
            Text("Send unknown commands; watch the log.")
                .font(.system(size: 13)).foregroundColor(.gray)
            HStack {
                probeButton("Send 0x39", 0x39)
                probeButton("Send 0x50", 0x50)
            }
            HStack {
                rawProbeButton("0x0B off", [0x0B, 30, 0x00])
                rawProbeButton("0x0B on", [0x0B, 30, 0x01])
            }
            ScrollView {
                VStack(alignment: .leading) {
                    ForEach(log.indices, id: \.self) { i in
                        Text(log[i]).font(.system(size: 12, design: .monospaced))
                            .foregroundColor(Color(red: 0, green: 1, blue: 0.5))
                    }
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.black.opacity(0.85).cornerRadius(5))
        }
        .padding()
        .navigationTitle("BLE Probe")
        .toolbar {
            Button(action: { log.removeAll() }) {
                Image(systemName: "trash")
            }
        }
        .onAppear {
            cancellable = bluetooth.eventLog.sink { event in
                log.insert(event, at: 0)
            }
        }
        .onDisappear { cancellable?.cancel() }
    }

    private func probeButton(_ label: String, _ cmd: UInt8) -> some View {
        Button(label) {
            guard !sending else { return }
            sending = true
            log.insert("→ Sending [0x\(String(format: "%02X", cmd))] ...", at: 0)
            Task {
                let resp = await appState.proto.probeSend(cmd)
                log.insert("← [0x\(String(format: "%02X", cmd))] \(resp)", at: 0)
                sending = false
            }
        }
        .frame(maxWidth: .infinity).frame(height: 44).background(Color(.secondarySystemBackground).cornerRadius(5))
        .buttonStyle(.plain)
    }

    private func rawProbeButton(_ label: String, _ bytes: [UInt8]) -> some View {
        Button(label) {
            guard !sending else { return }
            sending = true
            log.insert("→ \(label) ...", at: 0)
            Task {
                let resp = await appState.proto.probeRaw(bytes)
                log.insert("← \(label): \(resp)", at: 0)
                sending = false
            }
        }
        .frame(maxWidth: .infinity).frame(height: 44).background(Color(.secondarySystemBackground).cornerRadius(5))
        .buttonStyle(.plain)
    }
}
