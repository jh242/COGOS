import Foundation

/// JSON-backed durable memory store. Provider sessions are not source of
/// truth; COGOS persists recent turns itself under Application Support.
actor AgentMemoryStore {
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileURL: URL? = nil) {
        let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let appDir = supportDir.appendingPathComponent("COGOS", isDirectory: true)
        self.fileURL = fileURL ?? appDir.appendingPathComponent("agent-memory.json")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func load() async -> AgentMemory {
        do {
            let data = try Data(contentsOf: fileURL)
            return try decoder.decode(AgentMemory.self, from: data)
        } catch {
            return AgentMemory()
        }
    }

    func save(_ memory: AgentMemory) async throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try encoder.encode(memory)
        try data.write(to: fileURL, options: [.atomic])
    }

    func reset() async throws {
        let empty = AgentMemory()
        try await save(empty)
    }
}
