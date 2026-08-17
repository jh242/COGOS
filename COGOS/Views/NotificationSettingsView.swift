import SwiftUI

struct NotificationSettingsView: View {
    @EnvironmentObject var whitelist: NotificationWhitelist
    @EnvironmentObject var appState: AppState
    @State private var newAppId: String = ""

    var body: some View {
        Form {
            Section {
                Toggle("Calls", isOn: $whitelist.callsEnabled)
                Toggle("Messages", isOn: $whitelist.messagesEnabled)
                Toggle("Mail", isOn: $whitelist.mailEnabled)
                Toggle("Calendar", isOn: $whitelist.calendarEnabled)
            } header: {
                Text("Apple Notifications")
            } footer: {
                Text("These categories are delivered directly to the glasses through Apple Notification Center Service (ANCS).")
            }

            Section {
                if whitelist.appIds.isEmpty {
                    ContentUnavailableView {
                        Label("All Third-Party Apps", systemImage: "bell.badge")
                    } description: {
                        Text("No app-specific filters are configured.")
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(whitelist.appIds, id: \.self) { id in
                        HStack(spacing: 12) {
                            Image(systemName: "app.badge")
                                .foregroundStyle(.tint)
                            Text(id)
                                .font(.body.monospaced())
                            Spacer()
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                remove(id)
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                    }
                }
            } header: {
                Text("Third-Party Apps")
            } footer: {
                Text("Leave this list empty to keep the glasses notification inbox enabled for all apps, or add bundle identifiers to filter it.")
            }

            Section {
                TextField("com.example.app", text: $newAppId)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button {
                    add()
                } label: {
                    Label("Add App", systemImage: "plus.circle.fill")
                }
                .disabled(trimmedNewAppId.isEmpty || whitelist.appIds.contains(trimmedNewAppId))
            } header: {
                Text("Add App")
            } footer: {
                Text("Use the app’s bundle identifier, for example `com.apple.MobileSMS`.")
            }

            Section {
                Toggle("Show on arrival", isOn: $whitelist.autoDisplayEnabled)
                Stepper(
                    "Display for \(whitelist.displayTimeoutSeconds) seconds",
                    value: $whitelist.displayTimeoutSeconds,
                    in: 1...30
                )
                .disabled(!whitelist.autoDisplayEnabled)
            } header: {
                Text("Display")
            } footer: {
                Text("When disabled, notifications remain available from the glasses notification viewer without interrupting the current screen.")
            }

            Section {
                Button {
                    sync()
                } label: {
                    if whitelist.isSyncing {
                        HStack {
                            ProgressView()
                            Text("Syncing…")
                        }
                    } else {
                        Label("Sync Notification Settings", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .disabled(!appState.bluetooth.isConnected || whitelist.isSyncing)

                if let status = whitelist.syncStatus {
                    Text(status)
                        .foregroundStyle(status.hasPrefix("Synced") ? Color.green : Color.gray)
                }
            } footer: {
                Text(appState.bluetooth.isConnected
                     ? "COGOS also syncs these settings after both glasses arms are fully ready."
                     : "Connect both glasses arms before syncing. iOS may ask permission to share notifications during the first ANCS connection.")
            }
        }
        .navigationTitle("Notifications")
    }

    private var trimmedNewAppId: String {
        newAppId.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func add() {
        let id = trimmedNewAppId
        guard !id.isEmpty, !whitelist.appIds.contains(id) else { return }
        whitelist.set(whitelist.appIds + [id])
        newAppId = ""
        syncIfConnected()
    }

    private func remove(_ id: String) {
        whitelist.set(whitelist.appIds.filter { $0 != id })
        syncIfConnected()
    }

    private func syncIfConnected() {
        guard appState.bluetooth.isConnected else { return }
        sync()
    }

    private func sync() {
        Task { await whitelist.pushToGlasses(proto: appState.proto) }
    }
}
