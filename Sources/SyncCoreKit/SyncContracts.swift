import Foundation

public protocol HashableContent {
    var contentHash: String { get }
    var deduplicationID: String { get }
}

public protocol LocalFirstSyncStore: AnyObject {
    associatedtype Entity: Codable & Identifiable & HashableContent & Sendable

    static var entityType: String { get }
    var localStorageKey: String { get }
    var entities: [Entity] { get set }
    var syncQueue: SyncOperationQueue { get }

    func entityIdentifier(for entity: Entity) -> String
}

public extension LocalFirstSyncStore {
    func entityIdentifier(for entity: Entity) -> String {
        String(describing: entity.id)
    }

    func loadFromLocal(
        userDefaults: UserDefaults = .standard,
        decoder: JSONDecoder = JSONDecoder()
    ) -> [Entity] {
        guard let data = userDefaults.data(forKey: localStorageKey) else {
            return []
        }

        return (try? decoder.decode([Entity].self, from: data)) ?? []
    }

    func saveToLocal(
        _ entities: [Entity],
        userDefaults: UserDefaults = .standard,
        encoder: JSONEncoder = JSONEncoder()
    ) throws {
        let data = try encoder.encode(entities)
        userDefaults.set(data, forKey: localStorageKey)
    }

    func queueCreate(_ entity: Entity) async {
        await syncQueue.enqueue(
            SyncOperation(
                entityType: Self.entityType,
                entityID: entityIdentifier(for: entity),
                operationType: .create,
                contentHash: entity.contentHash
            )
        )
    }

    func queueUpdate(_ entity: Entity) async {
        await syncQueue.enqueue(
            SyncOperation(
                entityType: Self.entityType,
                entityID: entityIdentifier(for: entity),
                operationType: .update,
                contentHash: entity.contentHash
            )
        )
    }

    func queueDelete(entityID: String, contentHash: String? = nil) async {
        await syncQueue.enqueue(
            SyncOperation(
                entityType: Self.entityType,
                entityID: entityID,
                operationType: .delete,
                contentHash: contentHash
            )
        )
    }
}
