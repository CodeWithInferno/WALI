import Foundation
import WALIModel

public enum EngineAction: Sendable {
    case beginImports([(id: UUID, fileName: String, bookmark: Data)])
    case updateImport(id: UUID, phase: EngineImportJob.Phase, progress: Double, detail: String?)
    case finishImport(jobID: UUID, item: EngineLibraryItem)
    case cancelImport(UUID)
    case replaceDisplays([EngineDisplay])
    case apply(itemID: UUID, displayIDs: [String])
    case setPaused(Bool)
    case rename(itemID: UUID, name: String)
    case remove(itemID: UUID)
    case setPreferences(EnginePreferences)
    case setResourceUsage(EngineResourceUsage)
}

public enum EngineEffect: Sendable, Hashable {
    case startImport(jobID: UUID, bookmark: Data)
    case cancelImport(jobID: UUID)
    case render(item: EngineLibraryItem, displayIDs: [String])
    case stopRendering(itemID: UUID)
    case setPlaybackPaused(Bool)
    case removeArtifacts(itemID: UUID)
    case updateLaunchAtLogin(Bool)
    case persist
}

public struct EngineTransaction: Sendable, Hashable {
    public let snapshot: EngineSnapshot
    public let effects: [EngineEffect]

    public init(snapshot: EngineSnapshot, effects: [EngineEffect]) {
        self.snapshot = snapshot
        self.effects = effects
    }
}

public enum EngineError: Error, Sendable, Equatable {
    case staleRevision(expected: UInt64, actual: UInt64)
    case itemNotFound(UUID)
    case displayNotFound(String)
    case importNotFound(UUID)
    case invalidName
}

/// Serializes all state transitions and makes repeated commands idempotent.
public actor RuntimeEngine {
    private var state: EngineSnapshot
    private var completedTransactions: [UUID: EngineTransaction] = [:]
    private var completionOrder: [UUID] = []
    private let maximumRememberedTransactions = 256

    public init(restoring snapshot: EngineSnapshot = .init()) {
        state = snapshot
    }

    public func snapshot() -> EngineSnapshot {
        state
    }

    @discardableResult
    public func perform(
        _ action: EngineAction,
        idempotencyKey: UUID = UUID(),
        expectedRevision: EngineRevision? = nil
    ) throws -> EngineTransaction {
        if let prior = completedTransactions[idempotencyKey] {
            return prior
        }

        if let expectedRevision, expectedRevision.rawValue != state.revision.rawValue {
            throw EngineError.staleRevision(
                expected: expectedRevision.rawValue,
                actual: state.revision.rawValue
            )
        }

        let effects = try reduce(action)
        state.revision = EngineRevision(rawValue: state.revision.rawValue &+ 1)
        let transaction = EngineTransaction(snapshot: state, effects: effects + [.persist])
        remember(transaction, for: idempotencyKey)
        return transaction
    }

    private func reduce(_ action: EngineAction) throws -> [EngineEffect] {
        switch action {
        case let .beginImports(inputs):
            let existingIDs = Set(state.imports.map(\.id))
            var effects: [EngineEffect] = []
            for input in inputs where !existingIDs.contains(input.id) {
                state.imports.append(
                    .init(
                        id: input.id,
                        fileName: input.fileName,
                        phase: .queued,
                        progress: 0
                    )
                )
                effects.append(.startImport(jobID: input.id, bookmark: input.bookmark))
            }
            return effects

        case let .updateImport(id, phase, progress, detail):
            guard let index = state.imports.firstIndex(where: { $0.id == id }) else {
                throw EngineError.importNotFound(id)
            }
            state.imports[index].phase = phase
            state.imports[index].progress = min(max(progress, 0), 1)
            state.imports[index].detail = detail
            return []

        case let .finishImport(jobID, item):
            guard let index = state.imports.firstIndex(where: { $0.id == jobID }) else {
                throw EngineError.importNotFound(jobID)
            }
            if let duplicateIndex = state.items.firstIndex(where: { $0.contentDigest == item.contentDigest }) {
                state.imports[index].detail = "Already in your library as \(state.items[duplicateIndex].name)"
            } else {
                state.items.append(item)
                state.items.sort { $0.createdAt > $1.createdAt }
            }
            state.imports[index].phase = .complete
            state.imports[index].progress = 1
            return []

        case let .cancelImport(id):
            guard let index = state.imports.firstIndex(where: { $0.id == id }) else {
                throw EngineError.importNotFound(id)
            }
            state.imports[index].phase = .cancelled
            state.imports[index].detail = nil
            return [.cancelImport(jobID: id)]

        case let .replaceDisplays(displays):
            let assignments = Dictionary(uniqueKeysWithValues: state.displays.map { ($0.id, $0.assignedItemID) })
            state.displays = displays.map { display in
                var display = display
                if display.assignedItemID == nil {
                    display.assignedItemID = assignments[display.id] ?? nil
                }
                return display
            }
            return []

        case let .apply(itemID, displayIDs):
            guard let item = state.items.first(where: { $0.id == itemID }) else {
                throw EngineError.itemNotFound(itemID)
            }
            let knownDisplays = Set(state.displays.map(\.id))
            if let missingDisplay = displayIDs.first(where: { !knownDisplays.contains($0) }) {
                throw EngineError.displayNotFound(missingDisplay)
            }
            for index in state.displays.indices where displayIDs.contains(state.displays[index].id) {
                state.displays[index].assignedItemID = itemID
            }
            return [.render(item: item, displayIDs: displayIDs)]

        case let .setPaused(isPaused):
            state.isPausedByUser = isPaused
            return [.setPlaybackPaused(isPaused)]

        case let .rename(itemID, proposedName):
            let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count <= 120 else { throw EngineError.invalidName }
            guard let index = state.items.firstIndex(where: { $0.id == itemID }) else {
                throw EngineError.itemNotFound(itemID)
            }
            state.items[index].name = name
            return []

        case let .remove(itemID):
            guard state.items.contains(where: { $0.id == itemID }) else {
                throw EngineError.itemNotFound(itemID)
            }
            state.items.removeAll { $0.id == itemID }
            for index in state.displays.indices where state.displays[index].assignedItemID == itemID {
                state.displays[index].assignedItemID = nil
            }
            return [.stopRendering(itemID: itemID), .removeArtifacts(itemID: itemID)]

        case let .setPreferences(preferences):
            let launchAtLoginChanged = state.preferences.launchAtLogin != preferences.launchAtLogin
            state.preferences = preferences
            return launchAtLoginChanged ? [.updateLaunchAtLogin(preferences.launchAtLogin)] : []

        case let .setResourceUsage(resourceUsage):
            state.resourceUsage = resourceUsage
            return []
        }
    }

    private func remember(_ transaction: EngineTransaction, for key: UUID) {
        completedTransactions[key] = transaction
        completionOrder.append(key)
        if completionOrder.count > maximumRememberedTransactions {
            let expired = completionOrder.removeFirst()
            completedTransactions.removeValue(forKey: expired)
        }
    }
}
