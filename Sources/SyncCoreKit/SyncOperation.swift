import Foundation

public enum SyncOperationType: String, Codable, Sendable {
    case create
    case update
    case delete
}

public struct SyncOperation: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public let entityType: String
    public let entityID: String
    public let operationType: SyncOperationType
    public let contentHash: String?
    public let timestamp: Date
    public var retryCount: Int
    public var lastError: String?

    public init(
        id: UUID = UUID(),
        entityType: String,
        entityID: String,
        operationType: SyncOperationType,
        contentHash: String? = nil,
        timestamp: Date = Date(),
        retryCount: Int = 0,
        lastError: String? = nil
    ) {
        self.id = id
        self.entityType = entityType
        self.entityID = entityID
        self.operationType = operationType
        self.contentHash = contentHash
        self.timestamp = timestamp
        self.retryCount = retryCount
        self.lastError = lastError
    }

    public static func == (lhs: SyncOperation, rhs: SyncOperation) -> Bool {
        lhs.entityType == rhs.entityType &&
        lhs.entityID == rhs.entityID &&
        lhs.operationType == rhs.operationType
    }
}

public enum SyncQueueError: Error, LocalizedError, Sendable, Equatable {
    case noHandler(String)
    case operationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noHandler(let entityType):
            return "No sync handler registered for entity type: \(entityType)"
        case .operationFailed(let message):
            return "Sync operation failed: \(message)"
        }
    }
}

public struct SyncQueueSnapshot: Sendable {
    public let pendingOperations: [SyncOperation]
    public let failedOperations: [SyncOperation]
    public let isProcessing: Bool
    public let lastProcessedDate: Date?

    public var hasPendingOperations: Bool {
        !pendingOperations.isEmpty
    }

    public var hasFailedOperations: Bool {
        !failedOperations.isEmpty
    }
}
