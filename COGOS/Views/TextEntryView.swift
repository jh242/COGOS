import SwiftUI

struct TextEntryView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var bluetooth: BluetoothManager
    @State private var text: String = """
Welcome to G1.

You're holding the first eyewear ever designed to blend stunning aesthetics, amazing wearability and useful functionality.

At Even Realities we continuously explore the human relationship with technology.
"""

    var body: some View {
        VStack(spacing: 16) {
            TextEditor(text: $text)
                .frame(height: 300)
                .padding(8)
                .background(Color(.secondarySystemBackground).cornerRadius(5))
            Button(action: sendToGlasses) {
                Text("Send to Glasses")
                    .foregroundColor(bluetooth.isConnected && !text.isEmpty ? .primary : .gray)
                    .frame(maxWidth: .infinity).frame(height: 60)
                    .background(Color(.secondarySystemBackground).cornerRadius(5))
            }
            .buttonStyle(.plain)
            .disabled(!bluetooth.isConnected || text.isEmpty)
            Spacer()
        }
        .padding()
        .navigationTitle("Text Transfer")
    }

    private func sendToGlasses() {
        let snapshot = text
        Task {
            _ = await appState.proto.sendEvenAITextPrepare()
            _ = await appState.proto.sendEvenAIText("\n\n" + snapshot)
        }
    }
}
