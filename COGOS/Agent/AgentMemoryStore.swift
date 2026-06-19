import Foundation

/// JSON-backed durable memory store. Provider sessions are not source of
/// truth; COGOS persists recent turns itself under Application Support.
///
/// Loading rules:
/// - Missing file → return empty memory silently.
/// - Decode failure or schema mismatch → rotate the bad file to
///   `agent-memory.json.bak-<epoch>` so it is recoverable, then return empty.
/// - The persisted file is excluded from iCloud / iTunes backup so
///   conversation transcripts stay on-device.
///
/// Single-process only: no cross-process locking. iOS extensions must not
/// touch this file directly.
actor AgentMemoryStore {
    private let fileURL: URL
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init(fileURL: URL? = nil) {
        let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let appDir = supportDir.appendingPathComponent("COGOS", isDirectory: true)
        self.fileURL = fileURL ?? appDir.appendingPathComponent("agent-memory.json")
    }

    func load() async -> AgentMemory {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
            && error.code == NSFileReadNoSuchFileError {
            return AgentMemory()
        } catch {
            print("AgentMemoryStore: failed to read \(fileURL.lastPathComponent) — \(error)")
            return AgentMemory()
        }

        do {
            let memory = try Self.decoder.decode(AgentMemory.self, from: data)
            if memory.schemaVersion != AgentMemory.currentSchemaVersion {
                rotateCorruptFile(reason: "schemaVersion=\(memory.schemaVersion) expected=\(AgentMemory.currentSchemaVersion)")
                return AgentMemory()
            }
            return memory
        } catch {
            rotateCorruptFile(reason: "decode failed: \(error)")
            return AgentMemory()
        }
    }

    func save(_ memory: AgentMemory) async throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(memory)
        try data.write(to: fileURL, options: [.atomic])
        excludeFromBackup(fileURL)
    }

    func reset() async throws {
        let empty = AgentMemory()
        try await save(empty)
    }

    // MARK: - Helpers

    private func rotateCorruptFile(reason: String) {
        let ts = Int(Date().timeIntervalSince1970)
        let backup = fileURL.appendingPathExtension("bak-\(ts)")
        do {
            try FileManager.default.moveItem(at: fileURL, to: backup)
            print("AgentMemoryStore: rotated unreadable memory file (\(reason)) to \(backup.lastPathComponent)")
        } catch {
            print("AgentMemoryStore: failed to rotate corrupt memory file (\(reason)) — \(error)")
        }
    }

    private func excludeFromBackup(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        do {
            try url.setResourceValues(values)
        } catch {
            print("AgentMemoryStore: failed to mark \(url.lastPathComponent) as excluded from backup — \(error)")
        }
    }
}
