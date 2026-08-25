import Foundation

/// Which backend handles a spoken glasses question.
enum SpokenBackend: String, CaseIterable, Identifiable, Hashable {
    case hermes
    case openRouter

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hermes: return "Hermes"
        case .openRouter: return "OpenRouter"
        }
    }
}
