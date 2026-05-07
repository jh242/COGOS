import Foundation

/// Compacted, app-owned agent state. Phase 2 starts with durable recent
/// conversation turns; rolling summary and bindings are placeholders for
/// later phases without changing the runtime shape.
struct AgentMemory: Codable, Sendable {
    static let maxRecentTurns = 20

    var rollingSummary: String
    var recentTurns: [ConversationTurn]
    var sidebarBindings: [SidebarBinding]

    init(
        rollingSummary: String = "",
        recentTurns: [ConversationTurn] = [],
        sidebarBindings: [SidebarBinding] = []
    ) {
        self.rollingSummary = rollingSummary
        self.recentTurns = recentTurns
        self.sidebarBindings = sidebarBindings
    }

    mutating func addTurn(userText: String, assistantText: String, at date: Date = Date()) {
        recentTurns.append(ConversationTurn(userText: userText, assistantText: assistantText, createdAt: date))
        if recentTurns.count > Self.maxRecentTurns {
            recentTurns = Array(recentTurns.suffix(Self.maxRecentTurns))
        }
    }
}

struct ConversationTurn: Codable, Sendable, Identifiable {
    let id: UUID
    let userText: String
    let assistantText: String
    let createdAt: Date

    init(id: UUID = UUID(), userText: String, assistantText: String, createdAt: Date = Date()) {
        self.id = id
        self.userText = userText
        self.assistantText = assistantText
        self.createdAt = createdAt
    }
}

struct SidebarBinding: Codable, Sendable {
    let sidebarID: String
    var action: String?
}
