import Foundation

/// Compacted, app-owned agent state. Recent turns are kept verbatim; once
/// they exceed `maxRecentTurns`, `MemoryCompactor` folds the oldest into
/// `rollingSummary` (Phase 6). Bindings remain a placeholder for Phase 7.
///
/// Bump `currentSchemaVersion` whenever the on-disk shape changes in a
/// non-additive way. The store rotates incompatible files to `.bak-<ts>`
/// rather than silently wiping conversation history.
struct AgentMemory: Codable, Sendable {
    /// Compaction trigger: above this, MemoryCompactor summarizes the oldest turns.
    static let maxRecentTurns = 20
    /// Turns kept verbatim after a compaction pass.
    static let retainedTurnsAfterCompaction = 10
    /// Safety bound if compaction keeps failing (e.g. backend offline):
    /// addTurn drops the oldest turns beyond this instead of growing forever.
    static let hardTurnCap = 60
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var rollingSummary: String
    var recentTurns: [ConversationTurn]
    var sidebarBindings: [SidebarBinding]

    init(
        schemaVersion: Int = AgentMemory.currentSchemaVersion,
        rollingSummary: String = "",
        recentTurns: [ConversationTurn] = [],
        sidebarBindings: [SidebarBinding] = []
    ) {
        self.schemaVersion = schemaVersion
        self.rollingSummary = rollingSummary
        self.recentTurns = recentTurns
        self.sidebarBindings = sidebarBindings
    }

    mutating func addTurn(userText: String, assistantText: String, at date: Date = Date()) {
        recentTurns.append(ConversationTurn(userText: userText, assistantText: assistantText, createdAt: date))
        if recentTurns.count > Self.hardTurnCap {
            recentTurns = Array(recentTurns.suffix(Self.hardTurnCap))
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
