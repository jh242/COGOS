import SwiftUI

@main
struct COGOSApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .environmentObject(appState.bluetooth)
                .environmentObject(appState.session)
                .environmentObject(appState.history)
                .environmentObject(appState.settings)
                .environmentObject(appState.whitelist)
                .environmentObject(appState.glance)
                .onAppear { appState.start() }
        }
    }
}
