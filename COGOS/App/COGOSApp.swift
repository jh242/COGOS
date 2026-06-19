import AppIntents
import SwiftUI

@main
struct COGOSApp: App {
    @StateObject private var appState: AppState

    init() {
        let appState = AppState()
        _appState = StateObject(wrappedValue: appState)
        // Expose live services to App Intents (@Dependency in COGOSAppIntents).
        AppDependencyManager.shared.add(dependency: appState)
        AppDependencyManager.shared.add(dependency: appState.settings)
    }

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
