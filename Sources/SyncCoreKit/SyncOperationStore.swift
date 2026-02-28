import Foundation

public protocol SyncOperationStore: AnyObject {
    func loadPendingOperations() -> [SyncOperation]
    func loadFailedOperations() -> [SyncOperation]
    func loadLastProcessedDate() -> Date?
    func save(
        pendingOperations: [SyncOperation],
        failedOperations: [SyncOperation],
        lastProcessedDate: Date?
    )
}

public final class UserDefaultsSyncOperationStore: SyncOperationStore {
    private let userDefaults: UserDefaults
    private let pendingQueueKey: String
    private let failedQueueKey: String
    private let lastProcessedKey: String

    public init(prefix: String = "SyncOperationQueue", userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        self.pendingQueueKey = "\(prefix)_Pending"
        self.failedQueueKey = "\(prefix)_Failed"
        self.lastProcessedKey = "\(prefix)_LastProcessed"
    }

    public func loadPendingOperations() -> [SyncOperation] {
        guard let data = userDefaults.data(forKey: pendingQueueKey) else {
            return []
        }

        return (try? JSONDecoder().decode([SyncOperation].self, from: data)) ?? []
    }

    public func loadFailedOperations() -> [SyncOperation] {
        guard let data = userDefaults.data(forKey: failedQueueKey) else {
            return []
        }

        return (try? JSONDecoder().decode([SyncOperation].self, from: data)) ?? []
    }

    public func loadLastProcessedDate() -> Date? {
        userDefaults.object(forKey: lastProcessedKey) as? Date
    }

    public func save(
        pendingOperations: [SyncOperation],
        failedOperations: [SyncOperation],
        lastProcessedDate: Date?
    ) {
        if let pendingData = try? JSONEncoder().encode(pendingOperations) {
            userDefaults.set(pendingData, forKey: pendingQueueKey)
        }

        if let failedData = try? JSONEncoder().encode(failedOperations) {
            userDefaults.set(failedData, forKey: failedQueueKey)
        }

        if let lastProcessedDate {
            userDefaults.set(lastProcessedDate, forKey: lastProcessedKey)
        } else {
            userDefaults.removeObject(forKey: lastProcessedKey)
        }
    }
}
