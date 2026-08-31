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
    case setPlaybackStatus(EnginePlaybackStatus)
    case nextWallpaper
    case stopWallpaper
    case rename(itemID: UUID, name: String)
    case remove(itemID: UUID)
    case restore(itemID: UUID)
    case purgeTrashed(itemID: UUID)
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
    case scheduleTrashPurge(itemID: UUID)
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
        let transaction = EngineTransaction(snapshot: state, effects: [.persist] + effects)
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
            let previous = Dictionary(
                state.displays.map { ($0.id, $0) },
                uniquingKeysWith: { _, newest in newest }
            )
            let incoming = Dictionary(
                displays.map { ($0.id, $0) },
                uniquingKeysWith: { _, newest in newest }
            )
            var reconciled = incoming.values.map { display in
                var display = display
                if display.assignedItemID == nil {
                    display.assignedItemID = previous[display.id]?.assignedItemID
                }
                return display
            }
            reconciled.append(contentsOf: previous.values.compactMap { oldDisplay in
                guard incoming[oldDisplay.id] == nil else { return nil }
                var offline = oldDisplay
                offline.isMain = false
                offline.isOnline = false
                return offline
            })
            state.displays = reconciled.sorted { $0.id < $1.id }
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
            state.playbackStatus = isPaused ? .paused : (state.displays.contains { $0.assignedItemID != nil } ? .preparing : .idle)
            return [.setPlaybackPaused(isPaused)]

        case let .setPlaybackStatus(status):
            state.playbackStatus = status
            return []

        case .nextWallpaper:
            guard !state.items.isEmpty else { return [] }
            let displayIDs = state.displays.filter(\.isOnline).map(\.id)
            let activeItemID = state.displays.compactMap(\.assignedItemID).first
            let currentIndex = activeItemID.flatMap { id in state.items.firstIndex(where: { $0.id == id }) }
            let nextIndex = currentIndex.map { state.items.index(after: $0) } ?? state.items.startIndex
            let wrappedIndex = nextIndex == state.items.endIndex ? state.items.startIndex : nextIndex
            let item = state.items[wrappedIndex]
            for index in state.displays.indices where state.displays[index].isOnline {
                state.displays[index].assignedItemID = item.id
            }
            return [.render(item: item, displayIDs: displayIDs)]

        case .stopWallpaper:
            let assignedIDs = Set(state.displays.compactMap(\.assignedItemID))
            for index in state.displays.indices {
                state.displays[index].assignedItemID = nil
            }
            state.playbackStatus = .idle
            return assignedIDs.map { .stopRendering(itemID: $0) }

        case let .rename(itemID, proposedName):
            let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count <= 120 else { throw EngineError.invalidName }
            guard let index = state.items.firstIndex(where: { $0.id == itemID }) else {
                throw EngineError.itemNotFound(itemID)
            }
            state.items[index].name = name
            return []

        case let .remove(itemID):
            guard let item = state.items.first(where: { $0.id == itemID }) else {
                throw EngineError.itemNotFound(itemID)
            }
            state.items.removeAll { $0.id == itemID }
            state.trashedItems.removeAll { $0.id == itemID }
            state.trashedItems.append(item)
            for index in state.displays.indices where state.displays[index].assignedItemID == itemID {
                state.displays[index].assignedItemID = nil
            }
            return [.stopRendering(itemID: itemID), .scheduleTrashPurge(itemID: itemID)]

        case let .restore(itemID):
            guard let item = state.trashedItems.first(where: { $0.id == itemID }) else {
                throw EngineError.itemNotFound(itemID)
            }
            state.trashedItems.removeAll { $0.id == itemID }
            state.items.append(item)
            state.items.sort { $0.createdAt > $1.createdAt }
            return []

        case let .purgeTrashed(itemID):
            guard state.trashedItems.contains(where: { $0.id == itemID }) else { return [] }
            state.trashedItems.removeAll { $0.id == itemID }
            return [.removeArtifacts(itemID: itemID)]

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
