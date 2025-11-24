//
//  CloudKitService.swift
//  ayna
//
//  Created on 11/23/25.
//

import CloudKit
import Foundation
import os.log

final class CloudKitService: ObservableObject, Sendable {
    static let shared = CloudKitService()

    private let container = CKContainer.default()
    private lazy var database = container.privateCloudDatabase
    private let zoneId = CKRecordZone.ID(zoneName: "ConversationsZone", ownerName: CKCurrentUserDefaultName)

    private init() {
        Task {
            await createZoneIfNeeded()
        }
    }

    private func log(_ message: String, level: OSLogType = .default, metadata: [String: String] = [:]) {
        DiagnosticsLogger.log(.cloudKit, level: level, message: message, metadata: metadata)
    }

    private func createZoneIfNeeded() async {
        do {
            let zones = try await database.allRecordZones()
            if !zones.contains(where: { $0.zoneID == zoneId }) {
                let zone = CKRecordZone(zoneID: zoneId)
                try await database.save(zone)
                log("Created CloudKit zone")
            }
        } catch {
            log("Failed to check/create zone", level: .error, metadata: ["error": error.localizedDescription])
        }
    }

    func save(conversation: Conversation, fileURL: URL) async throws {
        let recordId = CKRecord.ID(recordName: conversation.id.uuidString, zoneID: zoneId)

        // 1. Fetch existing record or create new
        let record: CKRecord
        do {
            record = try await database.record(for: recordId)
        } catch {
            record = CKRecord(recordType: "Conversation", recordID: recordId)
        }

        // 2. Update fields
        record["title"] = conversation.title
        record["model"] = conversation.model
        record["updatedAt"] = conversation.updatedAt
        record["createdAt"] = conversation.createdAt
        if let systemPrompt = conversation.systemPrompt {
            record["systemPrompt"] = systemPrompt
        }
        record["temperature"] = conversation.temperature

        // 3. Attach encrypted file
        let asset = CKAsset(fileURL: fileURL)
        record["encryptedData"] = asset

        // 4. Save
        try await database.save(record)
        log("Saved conversation to CloudKit", metadata: ["id": conversation.id.uuidString])
    }

    func delete(conversationId: UUID) async throws {
        let recordId = CKRecord.ID(recordName: conversationId.uuidString, zoneID: zoneId)
        try await database.deleteRecord(withID: recordId)
        log("Deleted conversation from CloudKit", metadata: ["id": conversationId.uuidString])
    }

    func fetchChanges(since token: CKServerChangeToken?) async throws -> (
        changed: [CKRecord], deleted: [CKRecord.ID], newToken: CKServerChangeToken?
    ) {
        return try await withCheckedThrowingContinuation { continuation in
            var changedRecords: [CKRecord] = []
            var deletedRecordIDs: [CKRecord.ID] = []
            var newToken: CKServerChangeToken? = token

            let config = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
            config.previousServerChangeToken = token

            let operation = CKFetchRecordZoneChangesOperation(
                recordZoneIDs: [zoneId], configurationsByRecordZoneID: [zoneId: config])

            operation.recordWasChangedBlock = { recordID, result in
                switch result {
                case .success(let record):
                    changedRecords.append(record)
                case .failure(let error):
                    DiagnosticsLogger.log(
                        .cloudKit, level: .error, message: "Error fetching record",
                        metadata: ["id": recordID.recordName, "error": error.localizedDescription])
                }
            }

            operation.recordWithIDWasDeletedBlock = { recordID, _ in
                deletedRecordIDs.append(recordID)
            }

            operation.recordZoneFetchResultBlock = { _, result in
                switch result {
                case .success(let (token, _, _)):
                    newToken = token
                case .failure:
                    break
                }
            }

            operation.fetchRecordZoneChangesResultBlock = { result in
                switch result {
                case .success:
                    continuation.resume(returning: (changedRecords, deletedRecordIDs, newToken))
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            database.add(operation)
        }
    }
}
