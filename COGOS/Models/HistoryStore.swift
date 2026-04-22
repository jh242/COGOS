import Foundation

@MainActor
final class HistoryStore: ObservableObject {
    @Published var items: [EvenaiModel] = []
    @Published var selectedIndex: Int? = nil

    func addItem(title: String, content: String) {
        items.insert(EvenaiModel(title: title, content: content, createdTime: Date()), at: 0)
    }

    func removeItem(at index: Int) {
        items.remove(at: index)
        if selectedIndex == index { selectedIndex = nil }
        else if let s = selectedIndex, s > index { selectedIndex = s - 1 }
    }

    func clear() {
        items.removeAll()
        selectedIndex = nil
    }

    func toggle(index: Int) {
        selectedIndex = (selectedIndex == index) ? nil : index
    }
}
