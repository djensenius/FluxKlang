import CloudKit
import Foundation

protocol AssistantHistoryBackend: Sendable {
    func loadRecords() async throws -> [AssistantConversationRecord]
    func save(_ record: AssistantConversationRecord) async throws
}

actor LocalAssistantHistoryBackend: AssistantHistoryBackend {
    private let directory: URL
    private let legacyFileURL: URL?

    init(directory: URL? = nil, legacyFileURL: URL? = nil) {
        let base = directory ?? ((try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL.temporaryDirectory)
            .appendingPathComponent("FluxKlang", isDirectory: true)
            .appendingPathComponent("AssistantHistory", isDirectory: true)
        self.directory = base
        self.legacyFileURL = legacyFileURL
    }

    func loadRecords() throws -> [AssistantConversationRecord] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        var records = files.compactMap { url -> AssistantConversationRecord? in
            guard url.pathExtension == "json",
                  let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(AssistantConversationRecord.self, from: data)
        }
        if records.isEmpty, let legacyFileURL,
           let data = try? Data(contentsOf: legacyFileURL),
           let conversations = try? JSONDecoder().decode([AssistantConversation].self, from: data) {
            records = conversations.map(AssistantConversationRecord.init)
            for record in records {
                try save(record)
            }
            try? FileManager.default.removeItem(at: legacyFileURL)
        }
        return records
    }

    func save(_ record: AssistantConversationRecord) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(record)
        try data.write(to: fileURL(for: record.id), options: .atomic)
    }

    private func fileURL(for id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathExtension("json")
    }
}

actor CloudKitAssistantHistoryBackend: AssistantHistoryBackend {
    private static let recordType = "AssistantConversation"
    private let database: CKDatabase

    init(containerIdentifier: String = "iCloud.org.davidjensenius.FluxKlang") {
        database = CKContainer(identifier: containerIdentifier).privateCloudDatabase
    }

    func loadRecords() async throws -> [AssistantConversationRecord] {
        var records: [AssistantConversationRecord] = []
        var cursor: CKQueryOperation.Cursor?
        repeat {
            let result: (
                matchResults: [(CKRecord.ID, Result<CKRecord, any Error>)],
                queryCursor: CKQueryOperation.Cursor?
            )
            if let cursor {
                result = try await database.records(
                    continuingMatchFrom: cursor,
                    desiredKeys: ["payload"]
                )
            } else {
                result = try await database.records(
                    matching: CKQuery(
                        recordType: Self.recordType,
                        predicate: NSPredicate(value: true)
                    ),
                    desiredKeys: ["payload"]
                )
            }
            records += result.matchResults.compactMap { _, result in
                guard case .success(let record) = result,
                      let data = record["payload"] as? Data else { return nil }
                return try? JSONDecoder().decode(AssistantConversationRecord.self, from: data)
            }
            cursor = result.queryCursor
        } while cursor != nil
        return records
    }

    func save(_ value: AssistantConversationRecord) async throws {
        let recordID = CKRecord.ID(recordName: value.id.uuidString)
        let record = try await existingRecord(id: recordID)
            ?? CKRecord(recordType: Self.recordType, recordID: recordID)
        record["payload"] = try JSONEncoder().encode(value) as CKRecordValue
        _ = try await database.save(record)
    }

    private func existingRecord(id: CKRecord.ID) async throws -> CKRecord? {
        do {
            return try await database.record(for: id)
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
    }
}

actor AssistantConversationStore {
    private let local: any AssistantHistoryBackend
    private let cloud: (any AssistantHistoryBackend)?
    private(set) var diagnostics: [String] = []

    init(
        local: any AssistantHistoryBackend = LocalAssistantHistoryBackend(),
        cloud: (any AssistantHistoryBackend)? = nil,
        initialDiagnostics: [String] = []
    ) {
        self.local = local
        self.cloud = cloud
        diagnostics = initialDiagnostics
    }

    static func live() -> AssistantConversationStore {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
            return AssistantConversationStore(initialDiagnostics: [
                """
                Private iCloud sync is inactive in the unsigned test host. Conversations remain available in \
                the injectable local offline store.
                """
            ])
        }
        return AssistantConversationStore(cloud: CloudKitAssistantHistoryBackend())
    }

    func load() async -> [AssistantConversation] {
        let localRecords = await load(from: local, label: "Local assistant history")
        let cloudRecords = cloud.map { backend in
            Task { await self.load(from: backend, label: "Private iCloud assistant history") }
        }
        let remoteRecords = await cloudRecords?.value ?? []
        let merged = merge(localRecords + remoteRecords)
        await persistMerged(merged)
        return merged.compactMap(\.conversation).sorted { $0.modifiedAt > $1.modifiedAt }
    }

    func save(_ conversation: AssistantConversation) async {
        await saveRecord(AssistantConversationRecord(conversation: conversation))
    }

    func delete(id: UUID, at date: Date = Date()) async {
        await saveRecord(AssistantConversationRecord(tombstone: id, deletedAt: date))
    }

    func clearAll(_ conversations: [AssistantConversation], at date: Date = Date()) async {
        for conversation in conversations {
            await delete(id: conversation.id, at: date)
        }
    }

    private func load(
        from backend: any AssistantHistoryBackend,
        label: String
    ) async -> [AssistantConversationRecord] {
        do {
            return try await backend.loadRecords()
        } catch {
            diagnostics.append("\(label): \(error.localizedDescription)")
            return []
        }
    }

    private func merge(_ records: [AssistantConversationRecord]) -> [AssistantConversationRecord] {
        var byID: [UUID: AssistantConversationRecord] = [:]
        for record in records {
            guard let existing = byID[record.id] else {
                byID[record.id] = record
                continue
            }
            if record.modifiedAt > existing.modifiedAt
                || (record.modifiedAt == existing.modifiedAt && record.deletedAt != nil) {
                byID[record.id] = record
            }
        }
        return Array(byID.values)
    }

    private func persistMerged(_ records: [AssistantConversationRecord]) async {
        for record in records {
            do {
                try await local.save(record)
            } catch {
                diagnostics.append("Local assistant history: \(error.localizedDescription)")
            }
            if let cloud {
                do {
                    try await cloud.save(record)
                } catch {
                    diagnostics.append("Private iCloud assistant history: \(error.localizedDescription)")
                }
            }
        }
    }

    private func saveRecord(_ record: AssistantConversationRecord) async {
        do {
            try await local.save(record)
        } catch {
            diagnostics.append("Local assistant history: \(error.localizedDescription)")
        }
        if let cloud {
            do {
                try await cloud.save(record)
            } catch {
                diagnostics.append("Private iCloud assistant history: \(error.localizedDescription)")
            }
        }
    }
}
