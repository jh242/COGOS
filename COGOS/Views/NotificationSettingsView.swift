import SwiftUI

struct NotificationSettingsView: View {
    @EnvironmentObject var whitelist: NotificationWhitelist
    @EnvironmentObject var appState: AppState
    @State private var newAppId: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("App whitelist (empty = all apps)")
                .font(.system(size: 13)).foregroundColor(.gray)
            if whitelist.appIds.isEmpty {
                Text("No apps in whitelist.\nAll notifications will be forwarded.")
                    .multilineTextAlignment(.center).foregroundColor(.gray)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(whitelist.appIds, id: \.self) { id in
                        HStack {
                            Text(id).font(.system(size: 14))
                            Spacer()
                            Button(action: { remove(id) }) {
                                Image(systemName: "trash").foregroundColor(.red)
                            }.buttonStyle(.plain)
                        }
                    }
                }.listStyle(.plain)
            }
            HStack {
                TextField("com.example.app", text: $newAppId).padding(.horizontal, 12)
                    .frame(height: 44).background(Color(.secondarySystemBackground).cornerRadius(5))
                Button("Add") { add() }
                    .padding(.horizontal, 16).frame(height: 44).background(Color(.secondarySystemBackground).cornerRadius(5))
                    .buttonStyle(.plain)
            }
            Button("Push whitelist to glasses") {
                Task { await whitelist.pushToGlasses(proto: appState.proto) }
            }
            .frame(maxWidth: .infinity).frame(height: 44).background(Color(.secondarySystemBackground).cornerRadius(5))
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 44)
        .navigationTitle("Notification Settings")
    }

    private func add() {
        let id = newAppId.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty, !whitelist.appIds.contains(id) else { return }
        whitelist.set(whitelist.appIds + [id])
        newAppId = ""
    }

    private func remove(_ id: String) {
        whitelist.set(whitelist.appIds.filter { $0 != id })
    }
}
