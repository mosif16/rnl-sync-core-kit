import XCTest
@testable import SyncCoreKit

private final class InMemorySyncOperationStore: SyncOperationStore {
    var pending: [SyncOperation] = []
    var failed: [SyncOperation] = []
    var lastProcessedDate: Date?

    func loadPendingOperations() -> [SyncOperation] {
        pending
    }

    func loadFailedOperations() -> [SyncOperation] {
        failed
    }

    func loadLastProcessedDate() -> Date? {
        lastProcessedDate
    }

    func save(
        pendingOperations: [SyncOperation],
        failedOperations: [SyncOperation],
        lastProcessedDate: Date?
    ) {
        pending = pendingOperations
        failed = failedOperations
        self.lastProcessedDate = lastProcessedDate
    }
}

private actor InvocationCounter {
    private(set) var value: Int = 0

    func increment() {
        value += 1
    }
}

final class SyncOperationQueueTests: XCTestCase {
    func testCoalescesUpdateIntoPendingCreate() async {
        let store = InMemorySyncOperationStore()
        let queue = SyncOperationQueue(
            configuration: .init(debounceInterval: 1000),
            store: store,
            availabilityProvider: { true }
        )

        await queue.enqueue(
            SyncOperation(entityType: "Deck", entityID: "1", operationType: .create, contentHash: "a")
        )
        await queue.enqueue(
            SyncOperation(entityType: "Deck", entityID: "1", operationType: .update, contentHash: "b")
        )

        let snapshot = await queue.snapshot()
        XCTAssertEqual(snapshot.pendingOperations.count, 1)
        XCTAssertEqual(snapshot.pendingOperations.first?.operationType, .create)
        XCTAssertEqual(snapshot.pendingOperations.first?.contentHash, "b")
    }

    func testDeleteDropsUnsyncedPendingCreate() async {
        let store = InMemorySyncOperationStore()
        let queue = SyncOperationQueue(
            configuration: .init(debounceInterval: 1000),
            store: store,
            availabilityProvider: { true }
        )

        await queue.enqueue(
            SyncOperation(entityType: "Deck", entityID: "1", operationType: .create, contentHash: nil)
        )
        await queue.enqueue(
            SyncOperation(entityType: "Deck", entityID: "1", operationType: .delete, contentHash: nil)
        )

        let snapshot = await queue.snapshot()
        XCTAssertTrue(snapshot.pendingOperations.isEmpty)
    }

    func testProcessNowInvokesHandlerAndDequeuesOperation() async {
        let store = InMemorySyncOperationStore()
        let queue = SyncOperationQueue(
            configuration: .init(debounceInterval: 1000),
            store: store,
            availabilityProvider: { true }
        )

        let counter = InvocationCounter()

        await queue.registerHandler(for: "Deck") { _ in
            await counter.increment()
        }

        await queue.enqueue(
            SyncOperation(entityType: "Deck", entityID: "1", operationType: .create)
        )
        await queue.processNow()

        let snapshot = await queue.snapshot()
        let invocationCount = await counter.value

        XCTAssertEqual(invocationCount, 1)
        XCTAssertTrue(snapshot.pendingOperations.isEmpty)
        XCTAssertFalse(snapshot.isProcessing)
    }

    func testMovesOperationToFailedAfterMaxRetries() async {
        let store = InMemorySyncOperationStore()
        let queue = SyncOperationQueue(
            configuration: .init(
                maxRetryCount: 2,
                debounceInterval: 1000,
                retryDelays: [0, 0]
            ),
            store: store,
            availabilityProvider: { true }
        )

        struct DummyFailure: Error {}

        await queue.registerHandler(for: "Deck") { _ in
            throw DummyFailure()
        }

        await queue.enqueue(
            SyncOperation(entityType: "Deck", entityID: "1", operationType: .create)
        )

        await queue.processNow()
        var snapshot = await queue.snapshot()
        XCTAssertEqual(snapshot.pendingOperations.count, 1)
        XCTAssertEqual(snapshot.pendingOperations.first?.retryCount, 1)

        await queue.processNow()
        snapshot = await queue.snapshot()
        XCTAssertTrue(snapshot.pendingOperations.isEmpty)
        XCTAssertEqual(snapshot.failedOperations.count, 1)
        XCTAssertEqual(snapshot.failedOperations.first?.retryCount, 2)
    }

    func testSyncCoordinatorThrottlesAndReportsFailures() async {
        let queue = SyncOperationQueue(
            configuration: .init(debounceInterval: 1000),
            store: InMemorySyncOperationStore(),
            availabilityProvider: { true }
        )
        let coordinator = SyncCoordinator(
            syncQueue: queue,
            availabilityProvider: { true },
            syncThreshold: 600
        )

        await coordinator.registerStore("Deck") {}

        struct StoreFailure: Error {}
        await coordinator.registerStore("Quiz") {
            throw StoreFailure()
        }

        let first = await coordinator.performFullSync(force: true)
        XCTAssertTrue(first.started)
        XCTAssertEqual(first.succeededSteps, 1)
        XCTAssertEqual(first.failedSteps, 1)
        XCTAssertEqual(first.failures.count, 1)

        let second = await coordinator.performFullSync(force: false)
        XCTAssertFalse(second.started)
    }
}
