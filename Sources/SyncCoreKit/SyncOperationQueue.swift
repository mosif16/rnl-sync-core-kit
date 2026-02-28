import Foundation

public struct SyncOperationQueueConfiguration: Sendable {
    public var maxRetryCount: Int
    public var batchSize: Int
    public var debounceInterval: TimeInterval
    public var retryDelays: [TimeInterval]

    public init(
        maxRetryCount: Int = 3,
        batchSize: Int = 50,
        debounceInterval: TimeInterval = 2.0,
        retryDelays: [TimeInterval] = [1, 5, 15]
    ) {
        self.maxRetryCount = maxRetryCount
        self.batchSize = batchSize
        self.debounceInterval = debounceInterval
        self.retryDelays = retryDelays
    }
}

public actor SyncOperationQueue {
    public typealias SyncHandler = @Sendable (SyncOperation) async throws -> Void

    private let configuration: SyncOperationQueueConfiguration
    private let store: SyncOperationStore
    private let availabilityProvider: @Sendable () async -> Bool

    private var pendingOperations: [SyncOperation]
    private var failedOperations: [SyncOperation]
    private var lastProcessedDate: Date?
    private var isProcessing = false
    private var handlers: [String: SyncHandler] = [:]
    private var debounceTask: Task<Void, Never>?

    public init(
        configuration: SyncOperationQueueConfiguration = .init(),
        store: SyncOperationStore = UserDefaultsSyncOperationStore(),
        availabilityProvider: @escaping @Sendable () async -> Bool = { true }
    ) {
        self.configuration = configuration
        self.store = store
        self.availabilityProvider = availabilityProvider
        self.pendingOperations = store.loadPendingOperations()
        self.failedOperations = store.loadFailedOperations()
        self.lastProcessedDate = store.loadLastProcessedDate()
    }

    public func registerHandler(for entityType: String, handler: @escaping SyncHandler) {
        handlers[entityType] = handler

        if pendingOperations.contains(where: { $0.entityType == entityType }) {
            scheduleProcessing()
        }
    }

    public func enqueue(_ operation: SyncOperation) {
        if let existingIndex = pendingOperations.firstIndex(where: {
            $0.entityType == operation.entityType && $0.entityID == operation.entityID
        }) {
            let existing = pendingOperations[existingIndex]

            switch operation.operationType {
            case .delete:
                pendingOperations.remove(at: existingIndex)

                if existing.contentHash != nil || operation.contentHash != nil {
                    pendingOperations.append(operation)
                }

            case .update where existing.operationType == .create:
                pendingOperations[existingIndex] = SyncOperation(
                    id: existing.id,
                    entityType: existing.entityType,
                    entityID: existing.entityID,
                    operationType: .create,
                    contentHash: operation.contentHash ?? existing.contentHash,
                    timestamp: existing.timestamp,
                    retryCount: existing.retryCount,
                    lastError: existing.lastError
                )

            default:
                pendingOperations[existingIndex] = SyncOperation(
                    id: existing.id,
                    entityType: operation.entityType,
                    entityID: operation.entityID,
                    operationType: operation.operationType,
                    contentHash: operation.contentHash,
                    timestamp: existing.timestamp,
                    retryCount: existing.retryCount,
                    lastError: operation.lastError
                )
            }
        } else {
            pendingOperations.append(operation)
        }

        persistState()
        scheduleProcessing()
    }

    public func enqueueBatch(_ operations: [SyncOperation]) {
        for operation in operations {
            enqueue(operation)
        }
    }

    public func processNow() async {
        debounceTask?.cancel()
        await processQueue()
    }

    public func retryFailed() async {
        let reset = failedOperations.map {
            SyncOperation(
                id: $0.id,
                entityType: $0.entityType,
                entityID: $0.entityID,
                operationType: $0.operationType,
                contentHash: $0.contentHash,
                timestamp: $0.timestamp,
                retryCount: 0,
                lastError: nil
            )
        }

        failedOperations.removeAll()
        pendingOperations.append(contentsOf: reset)
        persistState()
        await processNow()
    }

    public func clearQueue() {
        pendingOperations.removeAll()
        persistState()
    }

    public func clearFailed() {
        failedOperations.removeAll()
        persistState()
    }

    public func clearAll() {
        pendingOperations.removeAll()
        failedOperations.removeAll()
        persistState()
    }

    public func snapshot() -> SyncQueueSnapshot {
        SyncQueueSnapshot(
            pendingOperations: pendingOperations,
            failedOperations: failedOperations,
            isProcessing: isProcessing,
            lastProcessedDate: lastProcessedDate
        )
    }

    public func pendingCount() -> Int {
        pendingOperations.count
    }

    public func failedCount() -> Int {
        failedOperations.count
    }

    public func operationsForEntity(type: String, id: String) -> [SyncOperation] {
        pendingOperations.filter {
            $0.entityType == type && $0.entityID == id
        }
    }

    private func scheduleProcessing() {
        debounceTask?.cancel()
        let debounceInterval = configuration.debounceInterval

        debounceTask = Task { [weak self] in
            let sleepNS = UInt64(max(0, debounceInterval) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: sleepNS)
            guard !Task.isCancelled else { return }
            await self?.processQueue()
        }
    }

    private func processQueue() async {
        guard !isProcessing else { return }
        guard !pendingOperations.isEmpty else { return }

        let processable = pendingOperations.filter { handlers[$0.entityType] != nil }
        guard !processable.isEmpty else { return }

        let isAvailable = await availabilityProvider()
        guard isAvailable else { return }

        isProcessing = true
        defer {
            isProcessing = false
            lastProcessedDate = Date()
            persistState()
        }

        let batch = Array(processable.prefix(configuration.batchSize))
        var completedIDs: Set<UUID> = []
        var retries: [SyncOperation] = []
        var permanentlyFailed: [SyncOperation] = []

        for operation in batch {
            do {
                try await processOperation(operation)
                completedIDs.insert(operation.id)
            } catch {
                var failed = operation
                failed.retryCount += 1
                failed.lastError = error.localizedDescription

                completedIDs.insert(operation.id)

                if failed.retryCount >= configuration.maxRetryCount {
                    permanentlyFailed.append(failed)
                } else {
                    retries.append(failed)
                }
            }
        }

        pendingOperations.removeAll { completedIDs.contains($0.id) }
        pendingOperations.append(contentsOf: retries)
        failedOperations.append(contentsOf: permanentlyFailed)

        if pendingOperations.contains(where: { handlers[$0.entityType] != nil }) {
            scheduleProcessing()
        }
    }

    private func processOperation(_ operation: SyncOperation) async throws {
        guard let handler = handlers[operation.entityType] else {
            throw SyncQueueError.noHandler(operation.entityType)
        }

        if operation.retryCount > 0 && !configuration.retryDelays.isEmpty {
            let index = min(operation.retryCount - 1, configuration.retryDelays.count - 1)
            let delay = max(0, configuration.retryDelays[index])
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }

        try await handler(operation)
    }

    private func persistState() {
        store.save(
            pendingOperations: pendingOperations,
            failedOperations: failedOperations,
            lastProcessedDate: lastProcessedDate
        )
    }
}
