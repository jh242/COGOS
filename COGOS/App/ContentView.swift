import SwiftUI

struct ContentView: View {
    var body: some View {
        NavigationView {
            HomeView()
        }
        .navigationViewStyle(.stack)
    }
}
