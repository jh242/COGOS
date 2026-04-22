import SwiftUI

struct FeaturesView: View {
    var body: some View {
        VStack(spacing: 12) {
            NavigationLink("Settings", destination: SettingsView()).buttonStyle(.plain)
                .frame(maxWidth: .infinity).frame(height: 60).background(Color(.secondarySystemBackground).cornerRadius(5))
            NavigationLink("Notifications", destination: NotificationSettingsView()).buttonStyle(.plain)
                .frame(maxWidth: .infinity).frame(height: 60).background(Color(.secondarySystemBackground).cornerRadius(5))
            NavigationLink("BLE Probe", destination: BleProbeView()).buttonStyle(.plain)
                .frame(maxWidth: .infinity).frame(height: 60).background(Color(.secondarySystemBackground).cornerRadius(5))
            NavigationLink("Text Send", destination: TextEntryView()).buttonStyle(.plain)
                .frame(maxWidth: .infinity).frame(height: 60).background(Color(.secondarySystemBackground).cornerRadius(5))
            Spacer()
        }
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 44)
        .navigationTitle("Features")
    }
}
