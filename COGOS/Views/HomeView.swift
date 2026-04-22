import SwiftUI

struct HomeView: View {
    @EnvironmentObject var bluetooth: BluetoothManager
    @EnvironmentObject var session: EvenAISession

    var body: some View {
        VStack(spacing: 16) {
            Button(action: {
                if case .disconnected = bluetooth.connectionState {
                    bluetooth.startScan()
                }
            }) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5).fill(Color(.secondarySystemBackground))
                    Text(bluetooth.status).font(.system(size: 16)).foregroundColor(.primary)
                }.frame(height: 100)
            }
            .buttonStyle(.plain)

            if case .disconnected = bluetooth.connectionState {
                pairedList
            } else if case .scanning = bluetooth.connectionState {
                pairedList
            }

            if bluetooth.isConnected {
                NavigationLink(destination: HistoryListView()) {
                    ScrollView {
                        Group {
                            if session.isSyncing {
                                ProgressView().padding()
                            } else {
                                Text(session.dynamicText)
                                    .font(.system(size: 14))
                                    .multilineTextAlignment(.center)
                                    .foregroundColor(bluetooth.isConnected ? .primary : .gray)
                                    .padding(16)
                            }
                        }
                    }
                    .background(Color(.secondarySystemBackground).cornerRadius(5))
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 44)
        .navigationTitle("Even AI Demo")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                NavigationLink(destination: FeaturesView()) {
                    Image(systemName: "line.3.horizontal")
                }
            }
        }
    }

    private var pairedList: some View {
        ScrollView {
            VStack(spacing: 5) {
                ForEach(bluetooth.pairedDevices) { g in
                    Button(action: {
                        bluetooth.connectToGlasses(deviceName: "Pair_\(g.channelNumber)")
                    }) {
                        HStack {
                            VStack(alignment: .leading) {
                                Text("Pair: \(g.channelNumber)")
                                Text("Left: \(g.leftDeviceName)\nRight: \(g.rightDeviceName)")
                                    .font(.system(size: 12))
                            }
                            Spacer()
                        }.padding(16)
                         .background(Color(.secondarySystemBackground).cornerRadius(5))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
