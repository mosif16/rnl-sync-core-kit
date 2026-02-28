import Foundation

public struct SyncStepFailure: Sendable {
    public let step: String
    public let message: String
    public let timestamp: Date

    public init(step: String, message: String, timestamp: Date = Date()) {
        self.step = step
        self.message = message
        self.timestamp = timestamp
    }
}

public struct SyncRunResult: Sendable {
    public let started: Bool
    public let succeededSteps: Int
    public let failedSteps: Int
    public let failures: [SyncStepFailure]
    public let completedAt: Date?

    public init(
        started: Bool,
        succeededSteps: Int,
        failedSteps: Int,
        failures: [SyncStepFailure],
        completedAt: Date?
    ) {
        self.started = started
        self.succeededSteps = succeededSteps
        self.failedSteps = failedSteps
        self.failures = failures
        self.completedAt = completedAt
    }
}

public actor SyncCoordinator {
    public typealias StoreSync = @Sendable () async throws -> Void

    private let syncQueue: SyncOperationQueue
    private let availabilityProvider: @Sendable () async -> Bool
    private let syncThreshold: TimeInterval

    private var registeredStores: [String: StoreSync] = [:]
    private var isSyncing = false
    private var lastFullSync: Date?

    public init(
        syncQueue: SyncOperationQueue,
        availabilityProvider: @escaping @Sendable () async -> Bool = { true },
        syncThreshold: TimeInterval = 300
    ) {
        self.syncQueue = syncQueue
        self.availabilityProvider = availabilityProvider
        self.syncThreshold = syncThreshold
    }

    public func registerStore(_ entityType: String, fullSync: @escaping StoreSync) {
        registeredStores[entityType] = fullSync
    }

    public func removeStore(_ entityType: String) {
        registeredStores.removeValue(forKey: entityType)
    }

    public func performFullSync(force: Bool = false) async -> SyncRunResult {
        guard !isSyncing else {
            return SyncRunResult(
                started: false,
                succeededSteps: 0,
                failedSteps: 0,
                failures: [],
                completedAt: nil
            )
        }

        if !force,
           let lastFullSync,
           Date().timeIntervalSince(lastFullSync) < syncThreshold {
            return SyncRunResult(
                started: false,
                succeededSteps: 0,
                failedSteps: 0,
                failures: [],
                completedAt: lastFullSync
            )
        }

        let isAvailable = await availabilityProvider()
        guard isAvailable else {
            return SyncRunResult(
                started: false,
                succeededSteps: 0,
                failedSteps: 0,
                failures: [SyncStepFailure(step: "availability", message: "Sync transport unavailable")],
                completedAt: nil
            )
        }

        isSyncing = true
        defer { isSyncing = false }

        var successes = 0
        var failures: [SyncStepFailure] = []

        let orderedStores = registeredStores.keys.sorted()
        for entityType in orderedStores {
            guard let sync = registeredStores[entityType] else {
                continue
            }

            do {
                try await sync()
                successes += 1
            } catch {
                failures.append(
                    SyncStepFailure(
                        step: entityType,
                        message: error.localizedDescription
                    )
                )
            }
        }

        await syncQueue.processNow()

        let completedAt = Date()
        lastFullSync = completedAt

        return SyncRunResult(
            started: true,
            succeededSteps: successes,
            failedSteps: failures.count,
            failures: failures,
            completedAt: completedAt
        )
    }

    public func processQueueNow() async {
        await syncQueue.processNow()
    }

    public func hasPendingOperations() async -> Bool {
        let snapshot = await syncQueue.snapshot()
        return snapshot.hasPendingOperations
    }

    public func pendingCount() async -> Int {
        await syncQueue.pendingCount()
    }

    public func currentLastFullSync() -> Date? {
        lastFullSync
    }
}
