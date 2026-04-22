import Foundation

struct EvenaiModel: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let content: String
    let createdTime: Date
}
