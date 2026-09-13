import Foundation

public enum CreatorBlockingError: Error, Equatable, Sendable {
    case invalidResponse, unavailable, limitReached, blocked, revisionChanged
}

private let maximumRevision: UInt64 = 9_007_199_254_740_991
func validCreatorBlockID(_ value: String) -> Bool {
    UUID(uuidString: value)?.uuidString.lowercased() == value
}
private func validCursor(_ value: String?) -> Bool {
    value.map { !$0.isEmpty && $0.utf8.count <= 1024 && $0.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=").contains($0) } } ?? true
}

public struct CreatorBlockRow: Decodable, Sendable, Hashable, Identifiable {
    public var id: String { creatorID }
    public let creatorID: String
    public let active: Bool
    public let revision: UInt64
    public let displayName: String?
    public let handle: String?
    public init(creatorID: String, active: Bool, revision: UInt64, displayName: String?, handle: String?) throws {
        guard validCreatorBlockID(creatorID), (1...maximumRevision).contains(revision),
              displayName.map({ !$0.isEmpty && $0.count <= 120 && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }) ?? true,
              handle.map({ $0.range(of: "^[a-z0-9][a-z0-9_]{2,31}$", options: .regularExpression) != nil }) ?? true
        else { throw CreatorBlockingError.invalidResponse }
        self.creatorID = creatorID; self.active = active; self.revision = revision
        self.displayName = displayName; self.handle = handle
    }
    enum CodingKeys: String, CodingKey { case creatorID = "creator_id", active, revision, displayName = "display_name", handle }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(creatorID: c.decode(String.self, forKey: .creatorID), active: c.decode(Bool.self, forKey: .active),
                      revision: c.decode(UInt64.self, forKey: .revision), displayName: c.decodeIfPresent(String.self, forKey: .displayName),
                      handle: c.decodeIfPresent(String.self, forKey: .handle))
    }
}

public struct CreatorBlockPage: Decodable, Sendable, Equatable {
    public let subjectID: String
    public let generation: UInt64
    public let items: [CreatorBlockRow]
    public let nextCursor: String?
    public init(subjectID: String, generation: UInt64, items: [CreatorBlockRow], nextCursor: String?) throws {
        guard validCreatorBlockID(subjectID), generation <= maximumRevision, items.count <= 100,
              Set(items.map(\.creatorID)).count == items.count, !items.contains(where: { $0.creatorID == subjectID }), validCursor(nextCursor)
        else { throw CreatorBlockingError.invalidResponse }
        self.subjectID = subjectID; self.generation = generation; self.items = items; self.nextCursor = nextCursor
    }
    enum CodingKeys: String, CodingKey { case subjectID = "subject_id", generation, items, nextCursor = "next_cursor" }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(subjectID: c.decode(String.self, forKey: .subjectID), generation: c.decode(UInt64.self, forKey: .generation),
                      items: c.decode([CreatorBlockRow].self, forKey: .items), nextCursor: c.decodeIfPresent(String.self, forKey: .nextCursor))
    }
}

public struct CreatorBlockResult: Decodable, Sendable, Equatable {
    public let subjectID: String
    public let creatorID: String
    public let desired: Bool
    public let revision: UInt64
    public let generation: UInt64
    public init(subjectID: String, creatorID: String, desired: Bool, revision: UInt64, generation: UInt64) throws {
        guard validCreatorBlockID(subjectID), validCreatorBlockID(creatorID), subjectID != creatorID,
              revision <= maximumRevision, generation <= maximumRevision, !desired || revision > 0 else { throw CreatorBlockingError.invalidResponse }
        self.subjectID = subjectID; self.creatorID = creatorID; self.desired = desired; self.revision = revision; self.generation = generation
    }
    enum CodingKeys: String, CodingKey { case subjectID = "subject_id", creatorID = "creator_id", desired, revision, generation }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(subjectID: c.decode(String.self, forKey: .subjectID), creatorID: c.decode(String.self, forKey: .creatorID),
                      desired: c.decode(Bool.self, forKey: .desired), revision: c.decode(UInt64.self, forKey: .revision), generation: c.decode(UInt64.self, forKey: .generation))
    }
}

public struct CreatorHiddenInteraction: Decodable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Decodable, Sendable { case favorite, saved, follow }
    public var id: String { kind.rawValue + ":" + targetID }
    public let targetID: String
    public let kind: Kind
    public let active: Bool
    public let revision: UInt64
    public init(targetID: String, kind: Kind, active: Bool, revision: UInt64) throws {
        guard validCreatorBlockID(targetID), (1...maximumRevision).contains(revision), active else { throw CreatorBlockingError.invalidResponse }
        self.targetID = targetID; self.kind = kind; self.active = active; self.revision = revision
    }
    enum CodingKeys: String, CodingKey { case targetID = "target_id", kind, active, revision }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(targetID: c.decode(String.self, forKey: .targetID), kind: c.decode(Kind.self, forKey: .kind),
                      active: c.decode(Bool.self, forKey: .active), revision: c.decode(UInt64.self, forKey: .revision))
    }
}

public struct CreatorHiddenInteractionPage: Decodable, Sendable, Equatable {
    public let subjectID: String
    public let generation: UInt64
    public let items: [CreatorHiddenInteraction]
    public let nextCursor: String?
    public init(subjectID: String, generation: UInt64, items: [CreatorHiddenInteraction], nextCursor: String?) throws {
        guard validCreatorBlockID(subjectID), generation <= maximumRevision, items.count <= 100,
              Set(items.map(\.id)).count == items.count, validCursor(nextCursor) else { throw CreatorBlockingError.invalidResponse }
        self.subjectID = subjectID; self.generation = generation; self.items = items; self.nextCursor = nextCursor
    }
    enum CodingKeys: String, CodingKey { case subjectID = "subject_id", generation, items, nextCursor = "next_cursor" }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(subjectID: c.decode(String.self, forKey: .subjectID), generation: c.decode(UInt64.self, forKey: .generation),
                      items: c.decode([CreatorHiddenInteraction].self, forKey: .items), nextCursor: c.decodeIfPresent(String.self, forKey: .nextCursor))
    }
}

public protocol CreatorBlockingGateway: Sendable {
    func creatorBlocks(cursor: String?, selectedCreatorID: String?) async throws -> CreatorBlockPage
    func setCreatorBlock(creatorID: String, desired: Bool, expectedRevision: UInt64, idempotencyKey: String) async throws -> CreatorBlockResult
    func hiddenCreatorInteractions(cursor: String?) async throws -> CreatorHiddenInteractionPage
    func removeHiddenCreatorInteraction(_ value: CreatorHiddenInteraction, idempotencyKey: String) async throws
}

struct CreatorBlockListParameters: Encodable, Sendable {
    let cursor: String?
    let selectedCreatorID: String?
    enum CodingKeys: String, CodingKey { case cursor, limit, selectedCreatorID = "selected_creator_id" }
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(cursor, forKey: .cursor)
        try c.encode(selectedCreatorID == nil ? 100 : 1, forKey: .limit)
        try c.encode(selectedCreatorID, forKey: .selectedCreatorID)
    }
}
struct CreatorHiddenPageParameters: Encodable, Sendable {
    let cursor: String?
    enum CodingKeys: String, CodingKey { case cursor, limit }
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(cursor, forKey: .cursor); try c.encode(100, forKey: .limit)
    }
}
struct CreatorBlockMutationParameters: Encodable, Sendable {
    let creatorID: String
    let desired: Bool
    let expectedRevision: UInt64
    let idempotencyKey: String
    enum CodingKeys: String, CodingKey { case creatorID = "creator_id", desired, expectedRevision = "expected_revision", idempotencyKey = "idempotency_key" }
}
