import Foundation
import Observation

@MainActor
public protocol AnonymousCreatorBlockStoring {
    func load() throws -> Set<String>
    func save(_ ids: Set<String>) throws
}

/// Foreground preferences only. Account data is never written to this key.
@MainActor
public final class UserDefaultsAnonymousCreatorBlocks: AnonymousCreatorBlockStoring {
    private let defaults: UserDefaults
    private let key = "creator-blocks.anonymous.v1"
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public func load() throws -> Set<String> {
        guard let stored = defaults.object(forKey: key) else { return [] }
        guard let values = stored as? [String], values.count <= 10_000,
              Set(values).count == values.count, values.allSatisfy(validCreatorBlockID) else { throw CreatorBlockingError.invalidResponse }
        return Set(values)
    }
    public func save(_ ids: Set<String>) throws {
        guard ids.count <= 10_000, ids.allSatisfy(validCreatorBlockID) else { throw CreatorBlockingError.limitReached }
        defaults.set(ids.sorted(), forKey: key)
        guard try load() == ids else { throw CreatorBlockingError.unavailable }
    }
}

@MainActor @Observable
public final class CreatorBlockingModel {
    public struct Snapshot: Sendable, Equatable {
        public let subjectID: String?
        public let epoch: UInt64
        public let blockedCreatorIDs: Set<String>
    }
    public private(set) var subjectID: String?
    public private(set) var generation: UInt64 = 0
    public private(set) var blockedCreatorIDs: Set<String> = []
    public private(set) var rows: [CreatorBlockRow] = []
    public private(set) var hiddenInteractions: [CreatorHiddenInteraction] = []
    public private(set) var hiddenNextCursor: String?
    public private(set) var isReady = false
    public private(set) var isWorking = false
    public private(set) var failureMessage: String?
    @ObservationIgnored public var onInvalidation: (@MainActor () -> Void)?
    private let gateway: (any CreatorBlockingGateway)?
    private let anonymousStore: any AnonymousCreatorBlockStoring
    private var epoch: UInt64 = 0
    private var subjectEpoch: UInt64 = 0
    private var refreshTask: (id: UUID, task: Task<[CreatorBlockPage], Error>, waiters: Int)?
    private var latestRefreshID: UUID?
    private var pending: (subject: String, creator: String, desired: Bool, revision: UInt64, key: String)?
    private var hiddenKeys: [String: String] = [:]

    public init(gateway: (any CreatorBlockingGateway)?, anonymousStore: any AnonymousCreatorBlockStoring) {
        self.gateway = gateway; self.anonymousStore = anonymousStore
    }

    public func updateSubject(_ subjectID: String?) {
        guard subjectID != self.subjectID else { return }
        refreshTask?.task.cancel(); refreshTask = nil
        subjectEpoch &+= 1; epoch &+= 1; self.subjectID = subjectID
        generation = 0; blockedCreatorIDs = []; rows = []; hiddenInteractions = []; hiddenNextCursor = nil
        isReady = false; isWorking = false; failureMessage = nil; pending = nil; hiddenKeys = [:]
        onInvalidation?()
    }

    public func refresh() async throws -> Snapshot {
        let expectedSubject = subjectID; let expectedSubjectEpoch = subjectEpoch
        isReady = false
        var operationID: UUID?
        do {
            guard let subject = expectedSubject else {
                let ids = try anonymousStore.load()
                guard ids.count <= 10_000, ids.allSatisfy(validCreatorBlockID) else { throw CreatorBlockingError.invalidResponse }
                apply(ids: ids, rows: [], generation: 0)
                isReady = true; failureMessage = nil
                return snapshot()
            }
            guard validCreatorBlockID(subject), let gateway else { throw CreatorBlockingError.unavailable }
            let request: (id: UUID, task: Task<[CreatorBlockPage], Error>, waiters: Int)
            if let existing = refreshTask { request = existing; refreshTask?.waiters += 1 }
            else {
                request = (UUID(), Task { try await Self.readAll(gateway: gateway, subject: subject) }, 1)
                latestRefreshID = request.id
                refreshTask = request
            }
            operationID = request.id
            defer {
                if refreshTask?.id == request.id {
                    refreshTask?.waiters -= 1
                    if refreshTask?.waiters == 0 { refreshTask = nil }
                }
            }
            let pages = try await request.task.value
            try Task.checkCancellation()
            guard subjectID == expectedSubject, subjectEpoch == expectedSubjectEpoch, refreshTask?.id == request.id else { throw CancellationError() }
            // Every coalesced waiter validates the same subject and request before presentation.
            let newRows = pages.flatMap(\.items)
            apply(ids: Set(newRows.map(\.creatorID)), rows: newRows, generation: pages[0].generation)
            isReady = true; failureMessage = nil
            return snapshot()
        } catch {
            guard subjectID == expectedSubject, subjectEpoch == expectedSubjectEpoch else { throw CancellationError() }
            if let operationID, operationID != latestRefreshID { throw CancellationError() }
            isReady = false
            if !(error is CancellationError) { failureMessage = "Creator preferences couldn’t be refreshed. Try again to load the catalog." }
            throw error
        }
    }

    private static func readAll(gateway: any CreatorBlockingGateway, subject: String) async throws -> [CreatorBlockPage] {
        var pages: [CreatorBlockPage] = []; var cursor: String?; var cursors: Set<String> = []; var ids: Set<String> = []
        repeat {
            let page = try await gateway.creatorBlocks(cursor: cursor, selectedCreatorID: nil)
            try Task.checkCancellation()
            guard page.subjectID == subject, pages.first.map({ $0.generation == page.generation }) ?? true,
                  page.items.allSatisfy(\.active), page.items.allSatisfy({ ids.insert($0.creatorID).inserted }),
                  ids.count <= 10_000, pages.count < 101 else { throw CreatorBlockingError.invalidResponse }
            pages.append(page); cursor = page.nextCursor
            if let cursor { guard cursors.insert(cursor).inserted, !page.items.isEmpty else { throw CreatorBlockingError.invalidResponse } }
        } while cursor != nil
        return pages
    }

    public func validate(_ value: Snapshot) throws {
        guard isReady, value.subjectID == subjectID, value.epoch == epoch else { throw CancellationError() }
    }
    /// An unrelated catalog read may already be refreshing the same preferences.
    /// Join that bounded operation before admitting metadata; do not abandon a
    /// valid load merely because the unchanged snapshot is still being checked.
    public func validateAfterPendingRefresh(_ value: Snapshot) async throws {
        if refreshTask != nil { _ = try await refresh() }
        try Task.checkCancellation()
        try validate(value)
    }

    public func allows(creatorID: String, in value: Snapshot) throws -> Bool {
        try validate(value)
        return !value.blockedCreatorIDs.contains(creatorID)
    }
    private func snapshot() -> Snapshot { Snapshot(subjectID: subjectID, epoch: epoch, blockedCreatorIDs: blockedCreatorIDs) }
    private func apply(ids: Set<String>, rows: [CreatorBlockRow], generation: UInt64) {
        let changed = ids != blockedCreatorIDs || self.generation != generation
        blockedCreatorIDs = ids; self.rows = rows; self.generation = generation
        if changed { epoch &+= 1; hiddenInteractions = []; hiddenNextCursor = nil; hiddenKeys = [:]; onInvalidation?() }
    }

    public func setBlocked(creatorID: String, desired: Bool) async throws {
        guard validCreatorBlockID(creatorID), creatorID != subjectID, !isWorking else { throw CreatorBlockingError.invalidResponse }
        let expectedSubject = subjectID; let expectedSubjectEpoch = subjectEpoch
        isWorking = true; failureMessage = nil
        defer { if subjectEpoch == expectedSubjectEpoch { isWorking = false } }
        do {
            _ = try await refresh()
            guard expectedSubject == subjectID, expectedSubjectEpoch == subjectEpoch else { throw CancellationError() }
            guard let subject = subjectID else {
                var ids = try anonymousStore.load()
                if desired {
                    guard ids.contains(creatorID) || ids.count < 10_000 else { throw CreatorBlockingError.limitReached }
                    ids.insert(creatorID)
                } else { ids.remove(creatorID) }
                try anonymousStore.save(ids); apply(ids: ids, rows: [], generation: 0); isReady = true; return
            }
            guard let gateway else { throw CreatorBlockingError.unavailable }
            if pending?.subject != subject || pending?.creator != creatorID || pending?.desired != desired {
                let page = try await gateway.creatorBlocks(cursor: nil, selectedCreatorID: creatorID)
                try Task.checkCancellation()
                guard expectedSubjectEpoch == subjectEpoch, subjectID == subject, page.subjectID == subject,
                      page.items.count <= 1, page.items.allSatisfy({ $0.creatorID == creatorID }), page.nextCursor == nil else { throw CancellationError() }
                pending = (subject, creatorID, desired, page.items.first?.revision ?? 0, UUID().uuidString.lowercased())
            }
            guard let command = pending else { throw CreatorBlockingError.invalidResponse }
            let result = try await gateway.setCreatorBlock(creatorID: creatorID, desired: desired, expectedRevision: command.revision, idempotencyKey: command.key)
            try Task.checkCancellation()
            guard expectedSubjectEpoch == subjectEpoch, subjectID == subject else { throw CancellationError() }
            guard result.subjectID == subject, result.creatorID == creatorID, result.desired == desired,
                  result.revision >= command.revision, result.revision - command.revision <= 1 else { throw CreatorBlockingError.invalidResponse }
            pending = nil
            refreshTask?.task.cancel(); refreshTask = nil
            _ = try await refresh()
        } catch {
            guard expectedSubject == subjectID, expectedSubjectEpoch == subjectEpoch else { throw CancellationError() }
            isReady = false; epoch &+= 1; onInvalidation?()
            if error as? CreatorBlockingError == .revisionChanged { pending = nil }
            if error as? CreatorBlockingError == .limitReached { failureMessage = "You can block up to 10,000 creators. Unblock one to add another." }
            else if !(error is CancellationError) { failureMessage = "Your creator preference couldn’t be saved. Try again." }
            throw error
        }
    }

    public func loadHiddenInteractions(more: Bool = false) async throws {
        let value = try await refresh()
        guard let subject = subjectID, let gateway else { hiddenInteractions = []; return }
        let page = try await gateway.hiddenCreatorInteractions(cursor: more ? hiddenNextCursor : nil)
        try validate(value)
        guard page.subjectID == subject, page.generation == generation else { throw CreatorBlockingError.invalidResponse }
        hiddenInteractions = page.items; hiddenNextCursor = page.nextCursor
    }

    public func removeHiddenInteraction(_ item: CreatorHiddenInteraction) async throws {
        let value = try await refresh()
        guard let gateway, subjectID != nil, hiddenInteractions.contains(item), !isWorking else { throw CreatorBlockingError.unavailable }
        let expectedSubjectEpoch = subjectEpoch
        isWorking = true
        defer { if expectedSubjectEpoch == subjectEpoch { isWorking = false } }
        let key = hiddenKeys[item.id] ?? UUID().uuidString.lowercased(); hiddenKeys[item.id] = key
        try await gateway.removeHiddenCreatorInteraction(item, idempotencyKey: key)
        try validate(value)
        hiddenKeys[item.id] = nil
        hiddenInteractions.removeAll { $0.id == item.id }
    }
}
