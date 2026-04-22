import SwiftUI

struct HistoryListView: View {
    @EnvironmentObject var history: HistoryStore

    var body: some View {
        Group {
            if history.items.isEmpty {
                Text("Press and hold left TouchBar to engage Even AI.")
                    .foregroundColor(.gray)
                    .multilineTextAlignment(.center)
                    .padding()
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(Array(history.items.enumerated()), id: \.element.id) { idx, item in
                            Button(action: { history.toggle(index: idx) }) {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(item.title).font(.system(size: 20))
                                    if history.selectedIndex == idx {
                                        Text(item.content).font(.system(size: 15))
                                    }
                                }.padding(16)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.yellow.opacity(0.2).cornerRadius(5))
                            }
                            .buttonStyle(.plain)
                        }
                    }.padding(16)
                }
            }
        }
        .navigationTitle("History")
    }
}
